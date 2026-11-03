-- SPDX-FileCopyrightText: 2026 Aidan Gauland <aidalgol+git@fastmail.net>
--
-- SPDX-License-Identifier: MIT

-- The delegate pipeline, shared by the orchestrator tool and every nested
-- local delegate tool: resolve -> policy -> budgets -> claims -> review
-- dedup/join -> spawn -> report -> ledger.
--
-- Single-threaded coroutines keep the bookkeeping race-free; all disk writes
-- go through the ledger's atomic choke point.

-- Tolerant require: dotted in maki, file-relative under the luau CLI.
local function req(dotted, sibling)
  local ok, mod = pcall(require, dotted)
  if ok and mod then
    return mod
  end
  return require(sibling)
end

local Config = req("specialist_subagents.config", "./config")
local Git = req("specialist_subagents.git", "./git")
local Ledger = req("specialist_subagents.ledger", "./ledger")
local Report = req("specialist_subagents.report", "./report")
local Registry = req("specialist_subagents.registry", "./registry")
local SB = req("specialist_subagents.session_builder", "./session_builder")
local Permissions = req("specialist_subagents.permissions", "./permissions")

local M = {}

-- Plugin-lifetime state. maki runs plugin Lua in one VM with cooperative
-- coroutines, so plain tables are race-free for this bookkeeping.
local State = {
  ledgers = {},    -- cwd -> ledger state
  iterations = {}, -- iteration key -> { count, at }
  claims = {},     -- active task claims: { claims = {...}, owner = "..." }
  active = 0,      -- concurrent specialist sessions
  finished = {},   -- join key -> { result, at } for waiter handoff
  running = {},    -- dispatch id -> in-flight dispatch (see running_register)
  seq = 0,         -- dispatch id counter (sync d-<n>, background bg-<n>)
}

local MAX_FINISHED = 50

local function ledger_for(cwd)
  if not State.ledgers[cwd] then
    State.ledgers[cwd] = Ledger.load_state(cwd, Config.ledger_cap)
  end
  return State.ledgers[cwd]
end

local function now()
  return os.time()
end

local function warn_log(msg)
  pcall(function() maki.log.warn("specialist-subagents: " .. msg) end)
end

-- The parent chat session id, for the running-dispatch registry and the
-- background completion notify. Nil when the host does not expose one
-- (headless runs): background then refuses earlier, and action matching
-- falls back to an explicit `dispatch` id.
local function session_id_of(ctx)
  if type(ctx) ~= "table" and type(ctx) ~= "userdata" then
    return nil
  end
  local ok, sid = pcall(function() return ctx:session_id() end)
  return ok and type(sid) == "string" and sid or nil
end

-- ---------------------------------------------------------------------------
-- Input normalization
-- ---------------------------------------------------------------------------

local function normalize_scope(scope)
  scope = scope or {}
  local files = {}
  if type(scope.files) == "table" then
    for _, f in ipairs(scope.files) do
      if type(f) == "string" then
        files[#files + 1] = f
      end
    end
  end
  local basis = scope.basis
  if basis ~= "plan" and basis ~= "files" then
    basis = "changed"
  end
  return { files = files, basis = basis }
end

local function normalize_target(raw, defaults_from)
  if type(raw) ~= "table" or type(raw.specialist) ~= "string" then
    return nil, "each target needs a specialist name"
  end
  if type(raw.brief) ~= "string" or #raw.brief == 0 then
    return nil, "target " .. raw.specialist .. " needs a brief"
  end
  return {
    specialist = raw.specialist,
    brief = raw.brief,
    kind = (raw.kind == "review" or raw.kind == "task" or raw.kind == "consult")
      and raw.kind or nil,
    scope = normalize_scope(raw.scope),
    claims = (function()
      local c = {}
      if type(raw.claims) == "table" then
        for _, v in ipairs(raw.claims) do
          if type(v) == "string" then
            c[#c + 1] = v
          end
        end
      end
      return c
    end)(),
    force_review = raw.force_review == true,
    _defaults_from = defaults_from,
  }, nil
end

-- Accepts the scalar form and the `targets` list form.
function M.normalize_input(input)
  if type(input) ~= "table" then
    return nil, "delegate input must be a table"
  end
  if type(input.targets) == "table" then
    local targets = {}
    for i, raw in ipairs(input.targets) do
      local t, err = normalize_target(raw)
      if not t then
        return nil, "targets[" .. i .. "]: " .. err
      end
      targets[#targets + 1] = t
    end
    if #targets == 0 then
      return nil, "targets list is empty"
    end
    return targets, nil
  end
  local t, err = normalize_target(input)
  if not t then
    return nil, err
  end
  return { t }, nil
end

-- Validate a `background = true` request. Pure: `headless` (no task UI to
-- wake or notify, e.g. under `maki -p`) is computed by the caller. Returns
-- the rejection reason, or nil when background is allowed.
function M.background_error(invoker, allow_background, headless)
  if allow_background == false then
    return "background dispatches are disabled (allow_background = false)"
  end
  if invoker.name ~= "main" then
    return "background dispatches are main-only: a nested delegate's tool call "
      .. "must stay synchronous so its result reaches the specialist's own report"
  end
  if headless then
    return "background dispatches need the task UI (none here, e.g. under `maki -p`): "
      .. "there is no session to wake with the results. Dispatch synchronously."
  end
  return nil
end

-- Validate an `action` request. Pure. `status` is a read-only query and is
-- allowed from any invoker; `message`/`stop` act on live sessions and are
-- main-only, like task delegation.
function M.action_error(input, invoker)
  local action = type(input) == "table" and input.action or nil
  if action ~= "status" and action ~= "message" and action ~= "stop" then
    return "action must be \"status\", \"message\", or \"stop\""
  end
  if action ~= "status" and invoker.name ~= "main" then
    return "action = \"" .. action .. "\" is main-only"
  end
  if action == "message" and (type(input.text) ~= "string" or input.text == "") then
    return "action = \"message\" needs text"
  end
  for _, field in ipairs({ "specialist", "brief", "targets", "background" }) do
    if input[field] ~= nil then
      return "action = \"" .. action .. "\" does not dispatch: remove " .. field
        .. " (or drop action to dispatch)"
    end
  end
  if input.dispatch ~= nil and type(input.dispatch) ~= "string" then
    return "dispatch must be a dispatch id string"
  end
  return nil
end

-- Synchronous pre-validation for one background target: the refusals that
-- must come back as immediate tool errors, not in a later message. Pure
-- enough for unit tests given a cwd. `peek` is a throwaway budget counter
-- ({ used = n }); the real per-call budget is counted again inside the
-- spawned run, starting from the number of targets this pass refused, so a
-- target is never counted twice.
function M.validate_background_target(cwd, target, invoker, peek)
  local spec = Registry.get(cwd, target.specialist)
  if not spec then
    return "unknown specialist: " .. target.specialist
  end
  local _, perr = M.check_policy(target, spec, invoker)
  if perr then
    return perr
  end
  peek.used = peek.used + 1
  if peek.used > Config.per_turn_budget then
    return string.format("per-turn delegation budget exhausted (%d)", Config.per_turn_budget)
  end
  local kind = target.kind or (spec.type == "review" and "review" or "task")
  if kind == "task" and #target.claims > 0 and Config.strict_claims then
    local conflicts = Ledger.find_claim_conflicts(State.claims, target.claims)
    if #conflicts > 0 then
      return "strict_claims: " .. conflicts[1]
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Running-dispatch registry (action = status / message / stop)
-- ---------------------------------------------------------------------------

-- One in-flight dispatch: id "d-<n>" (synchronous) or "bg-<n>" (background).
-- Each target row carries the live session while its `sess:prompt` runs, so
-- `action = "message"` / `"stop"` can reach it; the row is detached the
-- moment the target reaches a terminal status. The whole entry is removed
-- when every target is done (or the dispatch is cancelled).
function M.running_register(id, parent_session, background, targets)
  -- Bound leaked entries: a dispatch cancelled without its on_cancel hook
  -- firing (the hook is pcall'd, the API may be absent) ages out after an
  -- hour instead of showing in `action = "status"` forever.
  local stale_before = now() - 3600
  for stale_id, e in pairs(State.running) do
    if (e.started_at or 0) < stale_before then
      State.running[stale_id] = nil
    end
  end
  local entry = {
    id = id,
    seq = tonumber(tostring(id):match("%d+$")) or 0,
    parent_session = parent_session,
    background = background == true,
    started_at = now(),
    targets = {},
  }
  for _, t in ipairs(targets or {}) do
    entry.targets[#entry.targets + 1] = {
      specialist = t.specialist,
      kind = t.kind,
      status = "running",
    }
  end
  State.running[id] = entry
  return entry
end

local function running_row(id, idx)
  local entry = State.running[id]
  return entry and entry.targets[idx] or nil
end

function M.running_attach(id, idx, sess)
  local row = running_row(id, idx)
  if row then
    row.sess = sess
  end
end

-- Terminal status for one target; detaches its session (a closed session
-- must not be messaged or stopped) and drops the entry once every target is
-- done. Idempotent.
function M.running_mark(id, idx, status)
  local entry = State.running[id]
  local row = running_row(id, idx)
  if not row then
    return
  end
  row.status = status
  row.sess = nil
  if entry then
    for _, t in ipairs(entry.targets) do
      if t.status == "running" then
        return
      end
    end
    State.running[id] = nil
  end
end

function M.running_pop(id)
  State.running[id] = nil
end

-- Dispatches visible to one action call: the named dispatch when given,
-- else every running dispatch opened from `parent_session`. Sorted oldest
-- first (by numeric sequence).
function M.match_dispatches(parent_session, dispatch_id)
  local out = {}
  if type(dispatch_id) == "string" then
    -- An explicit id still has to belong to the caller's session: one
    -- maki instance can run several chats, and message/stop must not
    -- reach another chat's specialists.
    local e = State.running[dispatch_id]
    if e and e.parent_session == parent_session then
      out[#out + 1] = e
    end
    return out
  end
  for _, e in pairs(State.running) do
    if e.parent_session == parent_session then
      out[#out + 1] = e
    end
  end
  table.sort(out, function(a, b)
    return (a.seq or 0) < (b.seq or 0)
  end)
  return out
end

local function next_dispatch_id(background)
  State.seq = State.seq + 1
  return (background and "bg-" or "d-") .. State.seq
end

-- ---------------------------------------------------------------------------
-- Policy engine
-- ---------------------------------------------------------------------------

local function task_hops(chain, exclude_name)
  local n = 0
  for _, hop in ipairs(chain or {}) do
    -- exclude the invoker's own hop: the chain includes self, and an
    -- implementer's own task dispatch must not block its own children
    if hop.kind == "task" and hop.name ~= exclude_name then
      n = n + 1
    end
  end
  return n
end

local function chain_names(chain)
  local set = {}
  for _, hop in ipairs(chain or {}) do
    set[hop.name] = true
  end
  return set
end

-- Validate one target against the invoker's policy. Returns (kind, error).
function M.check_policy(target, spec, invoker)
  local names = chain_names(invoker.chain)
  if names[target.specialist] then
    return nil, "delegation cycle: " .. target.specialist .. " is already in the invocation chain"
  end
  if invoker.name == target.specialist then
    return nil, "delegation cycle: " .. target.specialist .. " cannot delegate to itself"
  end

  local kind = target.kind or (spec.type == "review" and "review" or "task")
  local depth = #invoker.chain + 1

  if kind == "consult" then
    -- Consults are main-only in v1: nested delegate schemas never offer the
    -- kind, and check_policy refuses it from any non-main invoker. No depth
    -- cap is needed (consults cannot nest and build no delegate tool).
    if invoker.name ~= "main" then
      return nil, "consultations are main-only"
    end
    return kind, nil
  end

  if kind == "review" then
    if depth > Config.review_max_depth then
      return nil, string.format(
        "review depth %d exceeds review_max_depth %d", depth, Config.review_max_depth)
    end
  else
    -- task request: from main, or from an implementation specialist at
    -- impl-depth 0 whose delegate.tasks allowlist names the target.
    if task_hops(invoker.chain, invoker.name) > 0 then
      return nil, "task delegation is capped at one nested level (impl chain cap)"
    end
    if invoker.name ~= "main" then
      local allow = invoker.delegate and invoker.delegate.tasks or {}
      local ok = false
      for _, name in ipairs(allow) do
        if name == target.specialist then
          ok = true
        end
      end
      if not ok then
        return nil, target.specialist .. " is not in this specialist's delegate.tasks allowlist"
      end
    end
  end
  return kind, nil
end

-- ---------------------------------------------------------------------------
-- Scope snapshots and review dedup
-- ---------------------------------------------------------------------------

local function plan_snapshot(cwd)
  local ok, plan = pcall(function() return maki.plan.read({}) end)
  if not ok or type(plan) ~= "table" or not plan.ready or not plan.content then
    return nil, "no ready plan (basis = \"plan\" needs a written plan file)"
  end
  local rel = plan.path and Git.validate_relpath(plan.path) or "plan.md"
  return {
    base_oid = nil,
    git = false,
    plan = true,
    files = { { path = rel, fingerprint = Git.fnv1a(plan.content), untracked = true } },
    diff_text = plan.content,
  }, nil
end

-- Pure containment guard on a normalized absolute path (exported for tests,
-- like M._store_finished). Belt-and-braces on top of Git.validate_relpath
-- (which already rejects `..` and leading dashes): re-checks that the
-- lexically-normalized absolute path really sits inside the project root, so
-- absolute or symlinked-out paths cannot slip through. Returns the relpath,
-- nil when outside the root.
local function norm_abs(p)
  local s = p:gsub("\\", "/")
  local root_prefix = s:sub(1, 1) == "/" and "/" or ""
  local segs = {}
  for seg in s:gmatch("[^/]+") do
    if seg == ".." then
      segs[#segs] = nil
    elseif seg ~= "." then
      segs[#segs + 1] = seg
    end
  end
  return root_prefix .. table.concat(segs, "/")
end

function M._review_path_in_root(cwd, abs)
  if type(cwd) ~= "string" or type(abs) ~= "string" then
    return nil
  end
  if abs:sub(1, 1) ~= "/" then
    return nil, "path must be absolute"
  end
  local root = norm_abs(cwd)
  local norm = norm_abs(abs)
  local prefix = root .. "/"
  if root == "" or norm:sub(1, #prefix) ~= prefix then
    return nil
  end
  local rel = norm:sub(#prefix + 1)
  if rel == "" then
    return nil
  end
  return rel
end

-- Snapshot for basis = "files": explicit model-supplied paths/globs resolved
-- against the working tree via maki.fs.glob (gitignore-respecting), not a
-- filter over the git-changed set. Every path is containment-checked and the
-- set is capped at Config.review_files_cap before any fs use.
local function files_snapshot(cwd, scope)
  if not scope.files or #scope.files == 0 then
    return nil, "basis = \"files\" needs scope.files"
  end
  local warnings = {}
  local seen = {}
  local files = {}
  for _, pattern in ipairs(scope.files) do
    local ok_glob, globbed = pcall(function()
      return maki.fs.glob(tostring(pattern), { path = cwd, gitignore = true })
    end)
    if not ok_glob or type(globbed) ~= "table" or #globbed == 0 then
      warnings[#warnings + 1] = string.format(
        "scope.files pattern %q matched nothing", tostring(pattern))
    else
      for _, raw in ipairs(globbed) do
        local rel = Git.validate_relpath(raw)
        local abs = raw
        if rel and not abs:find("^/") then
          abs = maki.fs.normalize(maki.fs.joinpath(cwd, raw))
        end
        local in_root = rel and M._review_path_in_root(cwd, abs)
        if not rel or not in_root then
          warnings[#warnings + 1] = "refused out-of-root path: " .. tostring(raw)
          warn_log("files-basis scope refused path " .. tostring(raw))
        elseif not seen[in_root] then
          seen[in_root] = true
          files[#files + 1] = { path = in_root, abs = abs }
        end
      end
    end
  end
  if #files == 0 then
    return nil, "no files matched scope.files"
  end
  if #files > Config.review_files_cap then
    local excluded = #files - Config.review_files_cap
    for i = #files, Config.review_files_cap + 1, -1 do
      files[i] = nil
    end
    local msg = string.format(
      "file cap (%d) reached; %d file(s) not included",
      Config.review_files_cap, excluded)
    warn_log(msg)
    warnings[#warnings + 1] = msg
  end

  -- fingerprints hash on-disk content; diff text mirrors changed_snapshot's
  -- fallback caps (per-file 20000, total 60000) with `--- path ---` headers
  local diff_parts = {}
  local total = 0
  local kept = {}
  for _, f in ipairs(files) do
    local ok_read, content = pcall(function() return maki.fs.read(f.abs) end)
    if not ok_read or type(content) ~= "string" then
      warnings[#warnings + 1] = "unreadable file skipped: " .. f.path
    else
      local diff = content:sub(1, 20000)
      if #content > 20000 then
        diff = diff .. "\n... (truncated)"
      end
      total = total + #diff
      if total <= 60000 then
        diff_parts[#diff_parts + 1] = "--- " .. f.path .. " ---\n" .. diff
      end
      kept[#kept + 1] = { path = f.path, fingerprint = Git.fnv1a(content), untracked = true }
    end
  end
  local diff_text = table.concat(diff_parts, "\n")
  if total > 60000 then
    diff_text = diff_text .. "\n... (diff truncated at 60000 bytes)"
  end
  return {
    base_oid = nil,
    git = false,
    files = kept,
    diff_text = diff_text,
    warnings = warnings,
  }, nil
end

local function changed_snapshot(cwd, scope)
  if scope.basis == "plan" then
    return plan_snapshot(cwd)
  end
  if scope.basis == "files" then
    return files_snapshot(cwd, scope)
  end
  local snap = Git.changed_snapshot(cwd, nil)
  local diff_parts = {}
  local total = 0
  for _, f in ipairs(snap.files) do
    local diff
    if snap.git and snap.base_oid and not f.untracked then
      diff = Git.file_diff(cwd, f.path)
    else
      local abs = maki.fs.normalize(maki.fs.joinpath(cwd, f.path))
      local content = maki.fs.read(abs)
      diff = content and content:sub(1, 8000) or "(unreadable)"
    end
    diff = diff or ""
    if #diff > 20000 then
      diff = diff:sub(1, 20000) .. "\n... (truncated)"
    end
    total = total + #diff
    if total <= 60000 then
      diff_parts[#diff_parts + 1] = "--- " .. f.path .. " ---\n" .. diff
    end
  end
  snap.diff_text = table.concat(diff_parts, "\n")
  if total > 60000 then
    snap.diff_text = snap.diff_text .. "\n... (diff truncated at 60000 bytes)"
  end
  return snap, nil
end

-- Per-file review outcomes (fresh, cached, or joined) for one target.
-- Returns files = { { path, fingerprint, cached_entry? } }.
local function resolve_review_files(state, target, spec, snap, force_review)
  local scoped
  if target.scope.basis == "files" then
    -- files-basis snapshots are already resolved to the explicit path set by
    -- maki.fs.glob; re-filtering through this plugin's glob matcher would
    -- only risk a semantic mismatch
    scoped = {}
    for _, f in ipairs(snap.files) do
      scoped[#scoped + 1] = f.path
    end
  else
    scoped = Git.filter_by_globs(
      (function()
        local paths = {}
        for _, f in ipairs(snap.files) do
          paths[#paths + 1] = f.path
        end
        return paths
      end)(),
      target.scope.files)
  end
  local by_path = {}
  for _, f in ipairs(snap.files) do
    by_path[f.path] = f
  end
  local out, cached = {}, {}
  for _, path in ipairs(scoped) do
    local f = by_path[path]
    if f then
      local entry = nil
      if not force_review then
        entry = Ledger.lookup(state, spec.name, path, f.fingerprint)
        if entry and not entry.verdict then
          -- an unparsable review satisfies nothing, the cache included:
          -- combined_verdict defaults to approve, so a verdict-less cached
          -- entry would approve unchanged files without any review
          entry = nil
        end
      end
      out[#out + 1] = { path = path, fingerprint = f.fingerprint, cached = entry }
      if entry then
        cached[#cached + 1] = entry
      end
    end
  end
  return out, cached
end

local function combined_verdict(entries)
  local verdict = "approve"
  local findings = {}
  local n = 0
  local summary = {}
  for _, e in ipairs(entries) do
    if e.verdict == "request-changes" then
      verdict = "request-changes"
    end
    for _, f in ipairs(e.findings or {}) do
      n = n + 1
      findings[#findings + 1] = { n = n, text = "[" .. e.path .. "] " .. f.text }
    end
    if e.summary then
      summary[#summary + 1] = "[" .. e.path .. "] " .. e.summary
    end
  end
  return verdict, findings, (#summary > 0 and table.concat(summary, "; ") or nil)
end

local function set_in_flight(state, key, spec, files, fingerprint)
  local rec = {
    specialist = spec.name,
    files = files,
    fingerprint = fingerprint,
    started_at = now(),
  }
  Ledger.in_flight_put(state, key, rec)
  return rec
end

-- Wait for an identical in-flight review to finish. Returns (result, joined)
-- or (nil, false) when the in-flight entry disappeared without a result.
-- Bounded: a wedged entry must not deadlock siblings.
local MAX_JOIN_WAIT_MS = 150000
local function join_in_flight(state, key)
  local waited = 0
  while waited < MAX_JOIN_WAIT_MS do
    local rec = Ledger.in_flight_get(state, key)
    if rec and rec.result then
      return rec.result, true
    end
    if not rec then
      -- purged: check the recent-finished handoff, else give up
      local fin = State.finished[key]
      if fin and now() - fin.at <= 120 then
        return fin.result, true
      end
      return nil, false
    end
    maki.async.sleep(250)
    waited = waited + 250
  end
  return nil, false
end

-- Recent-finished handoff for waiters that missed the in-flight window.
-- Lives on the plugin-lifetime State, never on the per-project ledger state
-- (which has no finished table).
local function store_finished(key, result)
  State.finished[key] = { result = result, at = now() }
  -- bound the table
  local keys = {}
  for k in pairs(State.finished) do
    keys[#keys + 1] = k
  end
  if #keys > MAX_FINISHED then
    table.sort(keys, function(a, b)
      return (State.finished[a].at or 0) < (State.finished[b].at or 0)
    end)
    for i = 1, #keys - MAX_FINISHED do
      State.finished[keys[i]] = nil
    end
  end
end

-- ---------------------------------------------------------------------------
-- Per-target pipeline
-- ---------------------------------------------------------------------------

local function record_ledger(state, spec, files, parsed, cwd)
  local ts = now()
  for _, f in ipairs(files) do
    Ledger.record(state, {
      specialist = spec.name,
      path = f.path,
      fingerprint = f.fingerprint,
      verdict = parsed.verdict, -- nil when unparsable: satisfies nothing
      findings = parsed.findings,
      summary = parsed.summary,
      raw = parsed.raw and parsed.raw:sub(1, 4000) or nil,
      ts = ts,
    }, Config.ledger_cap)
  end
  local _, perr = Ledger.persist(state, cwd)
  if perr then
    -- the review already happened; losing its ledger entries silently would
    -- only surface later as surprise re-reviews
    warn_log("ledger persist failed: " .. tostring(perr))
  end
end

-- Partial cache hit: keep the cached verdicts' contribution to the warning
-- (and to coverage, via the cached entries the caller keeps), but do NOT
-- replay cached findings into the result. Findings are changeset-level free
-- text stored on every per-file ledger entry, so a cached finding's subject
-- may well be the one file that changed — a partial hit cannot prove
-- otherwise. Only a full-cache hit (every file's content unchanged since the
-- review, checked above) makes replay sound.
local function apply_partial_cache(result, files, cached_entries)
  local cv = combined_verdict(cached_entries)
  result.warnings[#result.warnings + 1] = string.format(
    "%d of %d file(s) returned cached verdicts (%s)", #cached_entries, #files, cv)
end

local function Spec_cap(spec)
  return spec.max_iterations or Config.iteration_cap
end

local function drop_claim(owner)
  for i = #State.claims, 1, -1 do
    if State.claims[i].owner == owner then
      table.remove(State.claims, i)
    end
  end
end

-- Review-type targets a nested delegate tool may call, plus the allowlisted
-- task targets. The generated description enumerates exactly these.
local function nested_allowed_targets(cwd, spec)
  local catalog = Registry.catalog(cwd)
  local allowed = {}
  if spec.delegate and spec.delegate.reviews then
    for name, s in pairs(catalog) do
      if s.type == "review" then
        allowed[#allowed + 1] = {
          name = name, kind = "review", default_kind = "review",
          description = s.description,
        }
      end
    end
  end
  for _, name in ipairs((spec.delegate and spec.delegate.tasks) or {}) do
    local s = catalog[name]
    if s then
      allowed[#allowed + 1] = {
        name = name, kind = "task", default_kind = "task",
        description = s.description,
      }
    end
  end
  table.sort(allowed, function(a, b)
    if a.name ~= b.name then
      return a.name < b.name
    end
    return a.kind < b.kind
  end)
  return allowed
end

local function run_target(ctx, target, invoker, call)
  local cwd = call.cwd
  local result = {
    specialist = target.specialist,
    kind = target.kind,
    brief = target.brief,
    chain = invoker.chain,
    warnings = {},
    scope_files = {},
    claims = target.claims,
    status = "failed",
  }

  local spec = Registry.get(cwd, target.specialist)
  if not spec then
    result.status = "refused"
    result.error = "unknown specialist: " .. target.specialist
    return result
  end
  result.kind = target.kind or (spec.type == "review" and "review" or "task")

  local kind, perr = M.check_policy(target, spec, invoker)
  if not kind then
    result.status = "refused"
    result.error = perr
    return result
  end
  result.kind = kind

  -- per-call budget: every target counts
  call.used = call.used + 1
  if call.used > Config.per_turn_budget then
    result.status = "refused"
    result.error = string.format(
      "per-turn delegation budget exhausted (%d)", Config.per_turn_budget)
    return result
  end

  -- concurrency cap
  if State.active >= Config.max_active then
    result.status = "refused"
    result.error = string.format(
      "concurrent specialist session cap reached (%d)", Config.max_active)
    return result
  end

  -- iteration cap (fix<->re-review ping-pong guard)
  if kind == "review" then
    local it_key = Ledger.iteration_key(invoker.name, spec.name, target.scope.files)
    local count = Ledger.count_iterations(State.iterations, it_key, now(), Config.iteration_ttl)
    local cap = Spec_cap(spec)
    if count >= cap then
      result.status = "refused"
      result.error = string.format(
        "iteration cap reached: %s has reviewed this scope %d time(s) (cap %d) without scope-changing resolution",
        spec.name, count, cap)
      return result
    end
  end

  -- snapshot + review dedup (consults have no review contract: no snapshot,
  -- no ledger, no fingerprints)
  local snap, snap_err
  if kind ~= "consult" then
    snap, snap_err = changed_snapshot(cwd, target.scope)
    if not snap then
      result.status = "refused"
      result.error = snap_err
      return result
    end
    for _, w in ipairs(snap.warnings or {}) do
      result.warnings[#result.warnings + 1] = w
    end
  end
  local state = ledger_for(cwd)
  local files = {}
  local cached_entries = {}
  if kind == "review" then
    local scoped_files, cached = resolve_review_files(state, target, spec, snap, target.force_review)
    files, cached_entries = scoped_files, cached
    for _, f in ipairs(files) do
      result.scope_files[#result.scope_files + 1] = f.path
    end
    if #files == 0 then
      result.status = "done"
      result.verdict = "approve"
      result.summary = "nothing to review: no changed files matched the scope"
      return result
    end
    if #cached_entries == #files then
      -- all files have fresh entries -> done, no session
      local verdict, findings, summary = combined_verdict(cached_entries)
      result.status = "done"
      result.cached = true
      result.verdict = verdict
      result.findings = findings
      result.summary = (summary or "") .. " [CACHED REVIEW: every file in scope already has a fresh entry; force_review = true re-runs]"
      result.tokens = { input = 0, output = 0 }
      return result
    end
    -- partial cache: review only the unresolved subset, attach cached verdicts
    if #cached_entries > 0 then
      apply_partial_cache(result, files, cached_entries)
    end

    -- in-flight join per (specialist, file-set, fingerprint)
    local fingerprints = {}
    for _, f in ipairs(files) do
      fingerprints[#fingerprints + 1] = f.fingerprint
    end
    local jkey = Ledger.join_key(spec.name, result.scope_files, Git.fnv1a(table.concat(fingerprints, "\0")))
    local existing = Ledger.in_flight_get(state, jkey)
    if existing and not existing.result then
      local jres, joined = join_in_flight(state, jkey)
      if jres and joined then
        -- the same parsed result, without mutating the original caller's copy
        local copy = {}
        for k, v in pairs(jres) do
          copy[k] = v
        end
        copy.joined = true
        copy.cached = nil
        return copy
      end
      -- in-flight vanished without a result (error/Esc purge): run fresh
    end
    set_in_flight(state, jkey, spec, result.scope_files, Git.fnv1a(table.concat(fingerprints, "\0")))
    result._join_key = jkey
  end

  -- claims: task requests record glob claims and check active siblings
  if kind == "task" and #target.claims > 0 then
    local conflicts = Ledger.find_claim_conflicts(State.claims, target.claims)
    for _, c in ipairs(conflicts) do
      if Config.strict_claims then
        result.status = "refused"
        result.error = "strict_claims: " .. c
        return result
      end
      result.warnings[#result.warnings + 1] = c
    end
    State.claims[#State.claims + 1] = { claims = target.claims, owner = target.specialist }
    result._claim_registered = true
  end

  -- spawn
  local invocation = {
    chain = invoker.chain,
    depth = #invoker.chain + 1,
    brief = target.brief,
  }
  local local_tools
  if kind == "task" and spec.delegate and (spec.delegate.reviews or #spec.delegate.tasks > 0) then
    local allowed = nested_allowed_targets(cwd, spec)
    local child_invoker = {
      name = spec.name,
      chain = (function()
        local c = {}
        for _, hop in ipairs(invoker.chain) do
          c[#c + 1] = hop
        end
        c[#c + 1] = { name = spec.name, kind = kind }
        return c
      end)(),
      delegate = spec.delegate,
    }
    local_tools = SB.build_local_delegate(ctx, child_invoker, allowed, function(input, inner_invoker)
      return M.handle(ctx, input, inner_invoker or child_invoker)
    end)
  end

  -- hold the concurrency slot across open + prompt; released on every path
  State.active = State.active + 1
  -- Snapshot the chat's subagent tasks before opening, so the new session
  -- can be attributed for the permission relay. Exact when differently named
  -- specialists open concurrently; two sessions with the SAME name + kind
  -- opening between one snapshot and the next can pick up each other's id
  -- (same meta either way, and adopt()/identify re-verify against the live
  -- task list before any relay).
  local listed_before = Permissions.snapshot_ids(ctx)
  local sess, oerr = SB.open_session(ctx, spec, kind, invocation, cwd, local_tools)
  if not sess then
    State.active = math.max(0, State.active - 1)
    result.status = "failed"
    result.error = "session open failed: " .. tostring(oerr)
    if result._join_key then
      Ledger.in_flight_pop(state, result._join_key)
    end
    if result._claim_registered then
      drop_claim(target.specialist)
    end
    return result
  end

  -- Attribute the live session so its permission prompts can be relayed to
  -- the user; untracked on every close path below.
  local session_key = Permissions.track_new(ctx, listed_before, spec.name, kind)

  -- Publish the live session on the dispatch's registry row so a
  -- `delegate { action = "message" | "stop" }` call can reach it while
  -- `sess:prompt` below is blocked on it. Detached by running_mark on every
  -- terminal status.
  if target._dispatch then
    M.running_attach(target._dispatch.id, target._dispatch.idx, sess)
  end

  -- brief: self-contained task + identity + (reviews) changed files + diff
  local brief = table.concat({
    string.format("Task from %s (%s dispatch):", invoker.name, kind),
    target.brief,
  }, "\n\n")
  if kind == "review" then
    local paths = {}
    for _, f in ipairs(result.scope_files) do
      paths[#paths + 1] = "- " .. f
    end
    brief = brief .. "\n\nFiles in review scope:\n" .. table.concat(paths, "\n")
    if snap.diff_text and #snap.diff_text > 0 then
      brief = brief .. "\n\nCurrent diff:\n" .. snap.diff_text
    end
  end

  -- prompt: close on every path; the slot is held for the session lifetime
  local res, prompt_err
  do
    local ok_run, r_or_err, e2 = pcall(function()
      return sess:prompt(brief)
    end)
    if not ok_run then
      prompt_err = tostring(r_or_err)
    else
      res, prompt_err = r_or_err, e2
    end
    pcall(function() sess:close() end)
    Permissions.untrack(session_key)
    State.active = math.max(0, State.active - 1)
  end

  if result._claim_registered then
    drop_claim(target.specialist)
    result._claim_registered = nil
  end

  if not res then
    result.status = (prompt_err == "cancelled" or prompt_err == "stopped by user") and "cancelled" or "failed"
    result.error = "prompt failed: " .. tostring(prompt_err)
    if result._join_key then
      Ledger.in_flight_pop(state, result._join_key)
    end
    return result
  end

  result.tokens = { input = res.input_tokens, output = res.output_tokens }
  result.duration_ms = res.duration_ms

  if kind == "review" then
    local parsed = Report.parse_review(res.text)
    result.status = "done"
    result.verdict = parsed.verdict
    result.findings = result.findings or {}
    for _, f in ipairs(parsed.findings) do
      result.findings[#result.findings + 1] = f
    end
    result.summary = parsed.summary
    result.raw = res.text
    if result._join_key then
      local rec = Ledger.in_flight_get(state, result._join_key)
      if rec then
        rec.result = result
      end
      store_finished(result._join_key, result)
      Ledger.in_flight_pop(state, result._join_key)
    end
    record_ledger(state, spec, files, parsed, cwd)
  elseif kind == "consult" then
    -- no ledger, no fingerprints, no iteration bump: the answer is the
    -- deliverable and comes back as the report
    result.status = "done"
    result.summary = res.text and res.text:sub(1, Config.consult_summary_cap) or nil
    result.raw = res.text
  else
    result.status = "done"
    result.summary = res.text and res.text:sub(1, 2000) or nil
    result.raw = res.text
  end

  if kind == "review" then
    local it_key = Ledger.iteration_key(invoker.name, spec.name, target.scope.files)
    Ledger.bump_iterations(State.iterations, it_key, now())
  end

  return result
end

-- ---------------------------------------------------------------------------
-- Coverage audit (review-kind reports)
-- ---------------------------------------------------------------------------

local function coverage_audit(cwd, snap, results)
  -- One path can be covered by several specialists in a single fan-out;
  -- collect them per path instead of last-writer-wins. Iterating in reverse
  -- puts later-dispatched targets first, the nearest thing to "newest first"
  -- the aggregate result list has (the ts-ordered view is reviews_lookup).
  local covered = {}
  for i = #results, 1, -1 do
    local r = results[i]
    if r.kind == "review" and r.status == "done" then
      for _, p in ipairs(r.scope_files) do
        local list = covered[p]
        if not list then
          list = {}
          covered[p] = list
        end
        list[#list + 1] = { specialist = r.specialist, verdict = r.verdict, cached = r.cached }
      end
    end
  end
  local catalog = Registry.catalog(cwd)
  local rows, uncovered = {}, {}
  local seen = {}
  for _, f in ipairs(snap.files) do
    if not seen[f.path] then
      seen[f.path] = true
      local c = covered[f.path]
      rows[#rows + 1] = {
        path = f.path,
        reviewers = c, -- nil when uncovered: a path is uncovered only when no specialist covered it
      }
      if not c then
        uncovered[#uncovered + 1] = {
          path = f.path,
          suggestion = Git.suggest_for_path(catalog, f.path),
        }
      end
    end
  end
  return rows, uncovered
end

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

-- Shared post-gather tail: compact per-target results into input order,
-- format the aggregate, and run the review coverage audit. The synchronous
-- and background completion paths both call this so they cannot drift.
-- Returns (text, ordered).
local function aggregate_text(cwd, targets, results)
  -- compact results into input order
  local ordered = {}
  for i in ipairs(targets) do
    ordered[i] = results[i] or {
      specialist = targets[i].specialist, kind = targets[i].kind,
      status = "failed", error = "target produced no result", warnings = {},
    }
  end

  local text = Report.format_aggregate(ordered)

  -- review coverage audit on any fan-out containing review targets
  local has_review = false
  for _, r in ipairs(ordered) do
    if r.kind == "review" then
      has_review = true
    end
  end
  if has_review then
    local plan_scope, files_scope = nil, nil
    for _, t in ipairs(targets) do
      if t.scope.basis == "plan" then
        plan_scope = t.scope
      elseif t.scope.basis == "files" then
        files_scope = t.scope
      end
    end
    local snap
    if plan_scope then
      snap = plan_snapshot(cwd)
    elseif files_scope then
      snap = files_snapshot(cwd, files_scope)
    else
      snap = changed_snapshot(cwd, { files = {}, basis = "changed" })
    end
    if snap then
      local rows, uncovered = coverage_audit(cwd, snap, ordered)
      local cov = Report.format_coverage(rows, uncovered)
      if cov and #cov > 0 then
        text = text .. "\n\n" .. cov
      end
    end
  end

  return text, ordered
end

-- `action = "status" | "message" | "stop"`: query or reach the specialists
-- of in-flight dispatches. Main-only for message/stop (action_error).
function M.handle_action(ctx, input, invoker)
  local aerr = M.action_error(input, invoker)
  if aerr then
    return "error: " .. aerr, true
  end
  local parent_session = session_id_of(ctx)
  local entries = M.match_dispatches(parent_session, input.dispatch)
  if #entries == 0 then
    local which = type(input.dispatch) == "string" and input.dispatch or "from this session"
    return "No running specialist dispatches " .. which .. ".", false
  end
  local action = input.action
  if action == "status" then
    return Report.format_status(entries, now()), false
  end

  local rows = {}
  for _, e in ipairs(entries) do
    for idx, tgt in ipairs(e.targets) do
      local row = { dispatch = e.id, specialist = tgt.specialist, kind = tgt.kind }
      if not tgt.sess then
        row.ok = false
        row.detail = "no live session (not started yet, or already finished)"
      elseif action == "message" then
        local ok_call, sent, serr = pcall(tgt.sess.send, tgt.sess, input.text)
        row.ok = ok_call and sent == true
        row.detail = row.ok and "queued" or tostring(serr or "send failed")
      else -- stop
        local ok_call = pcall(tgt.sess.close, tgt.sess)
        row.ok = ok_call
        row.detail = ok_call and "closing (its prompt returns as cancelled)" or "close failed"
        if ok_call then
          tgt.status = "stopping"
        end
      end
      rows[#rows + 1] = row
    end
  end
  return Report.format_action_result(action, rows), false
end

-- `background = true`: validate synchronously (violations come back as
-- immediate tool errors), then move the fan-out plus the aggregation into a
-- single maki.async.spawn and return a receipt. The spawned task delivers
-- the aggregate report via maki.session.notify (wake = true).
function M.handle_background(ctx, targets, invoker, cwd)
  local parent_session = session_id_of(ctx)
  -- Headless: no session id to wake with the results (e.g. under `maki -p`),
  -- or no task UI at all. Checked here, not just via maki.task.list, so an
  -- empty task list can never route results into a notify that cannot land.
  local headless = parent_session == nil
  if not headless and type(maki) == "table" and type(maki.task) == "table" then
    local ok, tasks = pcall(function() return maki.task.list() end)
    headless = not (ok and type(tasks) == "table")
  end
  local berr = M.background_error(invoker, Config.allow_background, headless)
  if berr then
    return "error: " .. berr, true
  end

  -- synchronous validation pass; refusals never reach the spawned run
  local peek = { used = 0 }
  local pending = {}
  local refused = {}
  for _, target in ipairs(targets) do
    local verr = M.validate_background_target(cwd, target, invoker, peek)
    if verr then
      refused[#refused + 1] = {
        specialist = target.specialist, kind = target.kind,
        status = "refused", error = verr, warnings = {},
      }
    else
      pending[#pending + 1] = target
    end
  end
  if #pending == 0 then
    local text = Report.format_aggregate(refused)
    return "error: no dispatchable targets in the background request\n" .. text, true
  end

  local disp_id = next_dispatch_id(true)
  -- Only dispatchable targets get registry rows: a validation-refused
  -- target never opens a session, and a stuck "running" row would misstate
  -- both `action = "status"` and the completion count.
  M.running_register(disp_id, parent_session, true, pending)
  for idx, target in ipairs(pending) do
    target._dispatch = { id = disp_id, idx = idx }
  end

  -- The spawned run starts its real budget count from the number of targets
  -- the validation pass refused, so every target counts exactly once across
  -- both passes (validate_background_target documents the deal).
  local run_call = { cwd = cwd, used = #refused }
  local spawned_ok = pcall(function()
    maki.async.spawn(function()
      -- Cancellation (plugin unload, stopped task) must not leave the
      -- registry entry behind: the aggregate would never be delivered, and
      -- `action = "status"` would list this dispatch forever.
      pcall(function()
        maki.async.on_cancel(function()
          M.running_pop(disp_id)
          warn_log("background dispatch " .. disp_id .. " cancelled; its results were lost")
        end)
      end)
      local ok, task_err = pcall(function()
        local sem = maki.async.semaphore(Config.max_active)
        local results = {}
        local fns = {}
        for idx, target in ipairs(pending) do
          fns[#fns + 1] = function()
            local permit = sem:acquire()
            local ok_t, res = pcall(run_target, ctx, target, invoker, run_call)
            permit:release()
            if not ok_t then
              res = {
                specialist = tostring(target.specialist),
                kind = target.kind,
                status = "failed",
                error = "pipeline error: " .. tostring(res),
                warnings = {},
              }
              warn_log("pipeline error for " .. tostring(target.specialist) .. ": " .. tostring(res.error))
            end
            M.running_mark(disp_id, idx, res and res.status or "failed")
            results[idx] = res
          end
        end
        maki.async.gather(fns)

        -- Aggregate over the dispatchable targets only; synchronous
        -- refusals are appended below, they never ran a session.
        local text = aggregate_text(cwd, pending, results)
        if #refused > 0 then
          local ref = Report.format_aggregate(refused)
          text = text .. "\n\nRefused at validation (no session opened):\n" .. ref
        end

        local done = 0
        for _, r in ipairs(results) do
          if r and r.status == "done" then
            done = done + 1
          end
        end
        local _, nerr = maki.session.notify(text, {
          session = parent_session,
          wake = true,
          display = "specialist-subagents: " .. disp_id .. " finished ("
            .. done .. "/" .. #pending .. " completed)",
        })
        if nerr then
          -- the session may have closed mid-run: one retry, then the report
          -- is lost (warn at error level so it is findable in the log)
          maki.async.sleep(1000)
          local _, nerr2 = maki.session.notify(text, {
            session = parent_session,
            wake = true,
            display = "specialist-subagents: " .. disp_id .. " finished",
          })
          if nerr2 then
            pcall(function()
              maki.log.error("specialist-subagents: background dispatch " .. disp_id
                .. " completed but its aggregate report could not be delivered ("
                .. tostring(nerr2) .. "); verdicts are in the review ledger")
            end)
          end
        end
      end)
      M.running_pop(disp_id)
      if not ok then
        warn_log("background dispatch " .. disp_id .. " failed: " .. tostring(task_err))
      end
    end)
  end)
  if not spawned_ok then
    M.running_pop(disp_id)
    return "error: could not start the background dispatch task; dispatch synchronously", true
  end

  return Report.format_receipt(disp_id, targets, refused), false
end

-- Shared pipeline for the registered tool and nested local tools.
-- Returns (llm_output_string, is_error).
function M.handle(ctx, input, invoker)
  invoker = invoker or { name = "main", chain = {} }
  if type(input) == "table" and input.action ~= nil then
    return M.handle_action(ctx, input, invoker)
  end

  local targets, err = M.normalize_input(input)
  if not targets then
    return "error: " .. err, true
  end

  local cwd = maki.uv.cwd()
  -- Unreachable while the load-time check runs first; defense in depth
  -- against any future rescan path.
  local _, _, discovery_errors = Registry.catalog(cwd)
  if #discovery_errors > 0 then
    maki.log.error("specialist-subagents: broken specialist definitions:\n  - "
      .. table.concat(discovery_errors, "\n  - "))
    return "error: broken specialist definitions:\n  - "
      .. table.concat(discovery_errors, "\n  - "), true
  end

  if input.background == true then
    return M.handle_background(ctx, targets, invoker, cwd)
  end

  local call = { cwd = cwd, used = 0 }
  local results = {}

  -- the dispatch is addressable by `action` calls while it runs
  local disp_id = next_dispatch_id(false)
  M.running_register(disp_id, session_id_of(ctx), false, targets)
  for i, target in ipairs(targets) do
    target._dispatch = { id = disp_id, idx = i }
  end
  pcall(function()
    maki.async.on_cancel(function() M.running_pop(disp_id) end)
  end)

  -- fan-out across targets, bounded by max_active.
  --
  -- NOT maki.async.join: join runs every worker through maki.async.run,
  -- whose tasks are stopped after 60 seconds. Each specialist killed there
  -- never fires join's completion callback, so the dispatch hangs forever —
  -- every review longer than a minute died mid-stream and wedged the tool
  -- call (observed live: async.run: task failed x3 at +59.9s). gather runs
  -- the fns as children of this call (cancelled with it, no time cap); the
  -- semaphore keeps the concurrency bound.
  local sem = maki.async.semaphore(Config.max_active)
  local fns = {}
  for i, target in ipairs(targets) do
    fns[#fns + 1] = function()
      local permit = sem:acquire()
      local ok, res = pcall(run_target, ctx, target, invoker, call)
      permit:release()
      if not ok then
        res = {
          specialist = tostring(target.specialist),
          kind = target.kind,
          status = "failed",
          error = "pipeline error: " .. tostring(res),
          warnings = {},
        }
        warn_log("pipeline error for " .. tostring(target.specialist) .. ": " .. tostring(res.error))
      end
      M.running_mark(disp_id, i, res and res.status or "failed")
      results[i] = res
    end
  end
  maki.async.gather(fns)

  local text = aggregate_text(cwd, targets, results)
  M.running_pop(disp_id)

  local any_done = false
  for i in ipairs(targets) do
    local r = results[i]
    if r and r.status == "done" then
      any_done = true
    end
  end
  return text, not any_done and #targets > 0 and true or false
end

-- ---------------------------------------------------------------------------
-- specialist_reviews: read-only coverage query over the ledger
-- ---------------------------------------------------------------------------

function M.reviews_lookup(ctx, input)
  local cwd = maki.uv.cwd()
  local state = ledger_for(cwd)
  local basis = input.basis or "changed"
  local paths = {}
  if basis == "plan" then
    local snap = plan_snapshot(cwd)
    if not snap then
      return "error: " .. tostring(snap), true
    end
    for _, f in ipairs(snap.files) do
      paths[#paths + 1] = f.path
    end
  elseif basis == "files" then
    local snap, ferr = files_snapshot(cwd, {
      files = type(input.files) == "table" and input.files or {},
      basis = "files",
    })
    if not snap then
      return "error: " .. tostring(ferr), true
    end
    for _, f in ipairs(snap.files) do
      paths[#paths + 1] = f.path
    end
  else
    local snap = Git.changed_snapshot(cwd, nil)
    local all = {}
    for _, f in ipairs(snap.files) do
      all[#all + 1] = f.path
    end
    paths = Git.filter_by_globs(all, type(input.files) == "table" and input.files or nil)
  end
  if #paths == 0 then
    return "No changed files match. Nothing to report."
  end
  local out = { "Review coverage per file (from the persisted ledger):" }
  local covered = 0
  for _, path in ipairs(paths) do
    -- All specialists that covered the path, newest first: one row per
    -- (path, specialist), so a second specialist's coverage is not shadowed
    -- by a newer entry from the first. Repeat reviews by the same specialist
    -- keep only that specialist's newest entry.
    local newest_per_specialist = {}
    for _, key in ipairs(state.order) do
      local e = state.entries[key]
      if e and e.path == path then
        local cur = newest_per_specialist[e.specialist]
        if not cur or (e.ts or 0) > (cur.ts or 0) then
          newest_per_specialist[e.specialist] = e
        end
      end
    end
    local hits = {}
    for _, e in pairs(newest_per_specialist) do
      hits[#hits + 1] = e
    end
    if #hits > 0 then
      covered = covered + 1
      table.sort(hits, function(a, b)
        return (a.ts or 0) > (b.ts or 0)
      end)
      for _, e in ipairs(hits) do
        local age = e.ts and (os.time() - e.ts) or "?"
        out[#out + 1] = string.format(" %-46s %-24s %-16s (%ds ago)",
          path, e.specialist, e.verdict or "unparsed", age)
      end
    else
      out[#out + 1] = string.format(" %-46s %-24s %s", path, "-", "UNREVIEWED")
    end
  end
  out[#out + 1] = string.format("%d of %d file(s) have ledger coverage.", covered, #paths)
  return table.concat(out, "\n")
end

M._state = State -- exposed for /specialists and tests
M._store_finished = store_finished -- exposed for tests (finished-handoff wiring)
M._resolve_review_files = resolve_review_files -- exposed for tests (cache-miss rule)
M._record_ledger = record_ledger -- exposed for tests (persist-failure warning)
M._combined_verdict = combined_verdict -- exposed for tests (full-cache findings replay)
M._apply_partial_cache = apply_partial_cache -- exposed for tests (partial-hit findings suppression)
M._coverage_audit = coverage_audit -- exposed for tests (multi-specialist coverage)

return M
