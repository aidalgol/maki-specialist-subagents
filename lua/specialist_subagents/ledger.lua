-- SPDX-FileCopyrightText: 2026 Aidan Gauland <aidalgol+git@fastmail.net>
--
-- SPDX-License-Identifier: MIT

-- Review ledger: in-flight registry, persisted content-addressed cache,
-- join keys, and fix<->re-review iteration bookkeeping.
--
-- The pure core (everything above the maki section) is unit-tested without
-- the host. Persistence goes through one choke point that validates the
-- target subtree (`state_dir()/specialists/<hash(project cwd)>/`) and writes
-- with maki.fs.atomic_write.

local M = {}

-- Tolerant require: dotted in maki, file-relative under the luau CLI.
local function req(dotted, sibling)
  local ok, mod = pcall(require, dotted)
  if ok and mod then
    return mod
  end
  return require(sibling)
end

local Git = req("specialist_subagents.git", "./git")
local fnv1a = Git.fnv1a

-- ---------------------------------------------------------------------------
-- Pure core
-- ---------------------------------------------------------------------------

function M.scope_key(files)
  local sorted = {}
  for _, f in ipairs(files or {}) do
    sorted[#sorted + 1] = f
  end
  table.sort(sorted, function(a, b) return a < b end)
  return table.concat(sorted, "\0")
end

-- Join key for an in-flight review: (specialist, file-set, fingerprint).
function M.join_key(specialist, files, fingerprint)
  return table.concat({ specialist, M.scope_key(files), fingerprint or "" }, "\0")
end

function M.entry_key(specialist, path, fingerprint)
  return table.concat({ specialist, path, fingerprint }, "\0")
end

function M.new_state()
  return {
    in_flight = {}, -- join_key -> { specialist, files, fingerprint, result }
    entries = {},   -- entry_key -> ledger entry
    order = {},     -- LRU order of entry keys
    cap = 500,
  }
end

function M.in_flight_get(state, key)
  return state.in_flight[key]
end

function M.in_flight_put(state, key, rec)
  state.in_flight[key] = rec
end

function M.in_flight_pop(state, key)
  local rec = state.in_flight[key]
  state.in_flight[key] = nil
  return rec
end

-- Look up a fresh cache entry for one file. Bumps LRU on hit.
function M.lookup(state, specialist, path, fingerprint)
  local key = M.entry_key(specialist, path, fingerprint)
  local entry = state.entries[key]
  if not entry then
    return nil
  end
  for i, k in ipairs(state.order) do
    if k == key then
      table.remove(state.order, i)
      break
    end
  end
  state.order[#state.order + 1] = key
  return entry
end

-- Record a review outcome for one file. Only parsed, known verdicts are
-- gate-satisfying; unparsable reviews are stored verbatim with verdict=nil.
function M.record(state, entry, cap)
  local key = M.entry_key(entry.specialist, entry.path, entry.fingerprint)
  if state.entries[key] == nil then
    state.order[#state.order + 1] = key
  end
  state.entries[key] = entry
  local limit = cap or state.cap
  while #state.order > limit do
    local oldest = table.remove(state.order, 1)
    state.entries[oldest] = nil
  end
  return key
end

-- Per-(implementer, reviewer, scope) iteration bookkeeping, shared across
-- turns for the plugin's lifetime with TTL expiry: this is what blocks an
-- infinite fix<->re-review ping-pong even though each round changes the
-- fingerprint.
function M.iteration_key(implementer, reviewer, scope)
  return table.concat({ implementer or "main", reviewer, M.scope_key(scope) }, "\0")
end

function M.count_iterations(it, key, now, ttl)
  local rec = it[key]
  if not rec then
    return 0
  end
  if ttl and now and now - rec.at > ttl then
    it[key] = nil
    return 0
  end
  return rec.count
end

function M.bump_iterations(it, key, now)
  local rec = it[key]
  if not rec then
    rec = { count = 0, at = now or 0 }
    it[key] = rec
  end
  rec.count = rec.count + 1
  rec.at = now or 0
  return rec.count
end

-- Claims: glob overlap detection for path claims. Over-approximates on
-- purpose (warn-by-default), but compares literal prefix and suffix around
-- wildcards so `src/*.lua` and `src/*.rs` do not collide.
local function claim_parts(pattern)
  local p = tostring(pattern)
  local wildcard = p:find("[%*%?%[]")
  local prefix, suffix
  if wildcard then
    prefix = p:sub(1, wildcard - 1)
    local tail = p:sub(wildcard):gsub("%*", ""):gsub("%?", ""):gsub("%[.-%]", "")
    suffix = tail
  else
    prefix = p
    suffix = ""
  end
  return prefix, suffix
end

function M.claims_overlap(a, b)
  local pa, sa = claim_parts(a)
  local pb, sb = claim_parts(b)
  local prefix_ok = pa:sub(1, #pb) == pb or pb:sub(1, #pa) == pa
  local suffix_ok = #sa == 0 or #sb == 0 or sa:sub(-#sb) == sb or sb:sub(-#sa) == sa
  return prefix_ok and suffix_ok
end

-- Find active sibling claims intersecting `claims`; `active` is a list of
-- { claims = {...}, owner = "..." }.
function M.find_claim_conflicts(active, claims)
  local conflicts = {}
  for _, sibling in ipairs(active or {}) do
    for _, mine in ipairs(claims or {}) do
      for _, theirs in ipairs(sibling.claims or {}) do
        if M.claims_overlap(mine, theirs) then
          conflicts[#conflicts + 1] = string.format(
            "path claim %q overlaps %q already claimed by %s", mine, theirs,
            sibling.owner or "another task")
        end
      end
    end
  end
  return conflicts
end

-- ---------------------------------------------------------------------------
-- maki-backed persistence (never called from the pure core)
-- ---------------------------------------------------------------------------

local function state_root(project_cwd)
  local base = maki.env.state_dir()
  if not base then
    return nil, "state_dir unavailable"
  end
  local dir = maki.fs.joinpath(base, "specialists", fnv1a(project_cwd or ""))
  return dir
end

-- fs_write choke point: every write goes through here and is confined to
-- state_dir()/specialists/<hash(project cwd)>/ledger.json.
local function load_persisted(project_cwd)
  local dir, err = state_root(project_cwd)
  if not dir then
    return nil, err
  end
  local ok, text = pcall(function()
    return maki.fs.read(maki.fs.joinpath(dir, "ledger.json"))
  end)
  if not ok or not text or text == "" then
    return nil
  end
  local data = maki.json.decode(text)
  if type(data) ~= "table" or type(data.entries) ~= "table" then
    return nil
  end
  return data
end

-- fs_write choke point: validates the subtree and uses atomic_write.
local function persist(state, project_cwd)
  local dir, err = state_root(project_cwd)
  if not dir then
    return nil, err
  end
  if not dir:find(maki.fs.normalize(maki.env.state_dir()), 1, true) then
    return nil, "refusing to write outside the state dir"
  end
  local ok, mk_err = pcall(function() maki.fs.mkdir(dir, { parents = true }) end)
  if not ok then
    maki.log.debug("specialist-subagents: mkdir ignored: " .. tostring(mk_err))
  end
  local entries = {}
  for _, key in ipairs(state.order) do
    local e = state.entries[key]
    if e then
      entries[#entries + 1] = {
        specialist = e.specialist, path = e.path, fingerprint = e.fingerprint,
        verdict = e.verdict, findings = e.findings, summary = e.summary,
        raw = e.raw, ts = e.ts,
      }
    end
  end
  local encoded, enc_err = maki.json.encode({ version = 1, entries = entries })
  if not encoded then
    return nil, enc_err
  end
  local _, werr = maki.fs.atomic_write(maki.fs.joinpath(dir, "ledger.json"), encoded)
  if werr then
    return nil, werr
  end
  return true
end

-- Build the runtime state for one project: fresh tables plus whatever the
-- persisted ledger holds. Called lazily by dispatch.
function M.load_state(project_cwd, cap)
  local state = M.new_state()
  state.cap = cap or state.cap
  local data = load_persisted(project_cwd)
  if data then
    for _, e in ipairs(data.entries or {}) do
      if type(e) == "table" and type(e.path) == "string" then
        M.record(state, e, cap)
      end
    end
  end
  return state
end

M.persist = persist

return M
