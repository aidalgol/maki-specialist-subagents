-- Permission relay for specialist sub sessions.
--
-- A sub session cannot answer a permission prompt, so a gated call (mostly
-- `bash`) is denied outright. maki fires the `permission.prompt` slot
-- wherever a prompt would show, for subagent calls too, and `ctx:session_id()`
-- / `ctx:task_id()` say whose call it is. Where nobody can answer (a
-- background sub, `maki -p`) only the slot's default — the prompt — denies;
-- a layer's verdict stands. This module layers the slot and, when the caller
-- is one of this plugin's live specialist sessions, shows the user a real
-- prompt in the parent UI and relays the decision:
--
--   allow        the call runs, no model round trip
--   deny         the sub reads the guidance text and adapts
--
-- Nothing here bypasses a deny: deny rules and escalated (`ask`) calls never
-- reach the layer, YOLO-allowed calls never prompt, and non-specialist
-- callers pass through untouched. Relays are "allow once" (`y`) or "allow
-- for this specialist session" (`s`, an in-memory cache keyed on tool +
-- sorted scopes, cleared when the session closes); persistent approvals
-- stay in `.maki/permissions.toml`.
--
-- Cost: the layer sees the call, so it pays `session_read` + `session_write`
-- plus the tool's own capability (`run` for bash, `fs_write` for write/edit).
-- The plugin holds no `net`, so `webfetch`/`websearch` prompts skip the layer
-- and keep denying — a feature: no network authority is added.

local function req(dotted, sibling)
  local ok, mod = pcall(require, dotted)
  if ok and mod then
    return mod
  end
  return require("specialist_subagents." .. sibling)
end

local Config = req("specialist_subagents.config", "./config")

local M = {}

-- The host drops a layer still running after 60 s and leaves the call to the
-- prompt, which denies bare where nobody can answer. Answer just before that
-- so a timeout reaches the sub as a deny with guidance instead.
local RELAY_WINDOW_S = 55
local RECV_SLICE_MS = 500

M.GUIDANCE_DENY =
  "The user denied this call in the specialist permission relay. Do not retry "
  .. "the same call; adapt (different tool or command), or report what you "
  .. "could not run."
M.GUIDANCE_TIMEOUT =
  "The specialist permission relay timed out (no user answer). The call was "
  .. "denied. Drop it or use an alternative; recurring commands can be "
  .. "pre-allowed in .maki/permissions.toml."
M.GUIDANCE_OPEN_FAILED =
  "The specialist permission relay window could not be shown, so the call "
  .. "was denied. Recurring commands can be pre-allowed in "
  .. ".maki/permissions.toml."
M.GUIDANCE_CLOSED =
  "The specialist permission relay window was closed without an answer, so "
  .. "the call was denied."

-- Registry of live specialist sessions: session key -> { name, kind, cache }.
-- Keyed by whatever id the sub session exposes to `ctx:task_id()` /
-- `ctx:session_id()` inside its tool calls (see track_new).
local tracked = {}

-- ---------------------------------------------------------------------------
-- Pure helpers (unit-tested without the maki host)
-- ---------------------------------------------------------------------------

-- Stable signature of "this tool on exactly these scopes": the cache key for
-- "allow for this specialist session".
function M.scope_signature(req)
  local tool = "?"
  local scopes = {}
  if type(req) == "table" then
    if type(req.tool) == "string" and req.tool ~= "" then
      tool = req.tool
    end
    if type(req.scopes) == "table" then
      for _, s in ipairs(req.scopes) do
        if type(s) == "string" and s ~= "" then
          scopes[#scopes + 1] = s
        end
      end
    end
  end
  table.sort(scopes)
  return tool .. "|" .. table.concat(scopes, "\n")
end

-- The cached decision for a signature, or nil. Verdicts record no rules
-- host-side, so the cache is the only "allow for this session" memory.
function M.decision_for(cache, sig)
  if type(cache) == "table" and sig and cache[sig] then
    return { decision = "allow" }
  end
  return nil
end

function M.cache_store(cache, sig)
  if type(cache) == "table" and sig then
    cache[sig] = true
  end
end

local INPUT_FIELDS = { "command", "file_path", "path", "pattern", "url", "query" }

local function one_line(s, max)
  s = tostring(s):gsub("[%z\1-\31\n]+", " ")
  if #s > max then
    return s:sub(1, max - 1) .. "…"
  end
  return s
end

-- Short human-readable summary of what the tool would do.
function M.describe_input(req)
  local input = type(req) == "table" and req.input or nil
  if type(input) == "string" then
    return one_line(input, 160)
  end
  if type(input) ~= "table" then
    return ""
  end
  for _, f in ipairs(INPUT_FIELDS) do
    local v = input[f]
    if type(v) == "string" and v ~= "" then
      return one_line(v, 160)
    end
  end
  return ""
end

local function scopes_of(req)
  local out = {}
  if type(req) == "table" and type(req.scopes) == "table" then
    for _, s in ipairs(req.scopes) do
      if type(s) == "string" and s ~= "" then
        out[#out + 1] = s
      end
    end
  end
  return out
end

-- The prompt window body: specialist name, kind, tool, command/input, scopes.
-- Pure; rendered with maki.ui.buf by ask_user.
function M.prompt_spans(meta, req)
  meta = meta or {}
  local lines = {
    { { "specialist  ", { dim = true } }, { tostring(meta.name or "?") .. " (" .. tostring(meta.kind or "?") .. ")", { bold = true } } },
    { { "tool        ", { dim = true } }, { tostring(type(req) == "table" and req.tool or "?"), { bold = true } } },
  }
  local desc = M.describe_input(req)
  if desc ~= "" then
    lines[#lines + 1] = { { "input       ", { dim = true } }, { desc } }
  end
  local scopes = scopes_of(req)
  if #scopes > 0 then
    lines[#lines + 1] = { { "scopes      ", { dim = true } }, { table.concat(scopes, ", ") } }
  end
  return lines
end

-- Split a session display name ("spec-name:review") back into its parts.
-- Specialist names may contain ":"; the kind is the last segment.
function M.split_name(name)
  if type(name) ~= "string" then
    return nil
  end
  local spec, kind = name:match("^(.+):(review)$")
  if not spec then
    spec, kind = name:match("^(.+):(task)$")
  end
  if spec and spec ~= "" then
    return spec, kind
  end
  return nil
end

-- Plugin identities this plugin loads under. The host names config-dir
-- plugins "<dir>/init.lua" and pack installs by their package name. Exact
-- matches only: a substring check would let a foreign plugin whose name
-- merely contains "specialist" route its subagent prompts through this
-- relay. A same-config-dir plugin that also names its subs "<name>:review"
-- could still collide — accepted, the name convention is ours.
local OUR_PLUGINS = {
  ["project/init.lua"] = true,
  ["user/init.lua"] = true,
  ["specialist-subagents"] = true,
}

-- Does a maki.task.list entry describe a session this plugin opened?
function M.ours_entry(entry)
  if type(entry) ~= "table" or type(entry.id) ~= "string" or entry.id == "" then
    return false
  end
  if not OUR_PLUGINS[entry.plugin] then
    return false
  end
  return M.split_name(entry.name) ~= nil
end

-- ---------------------------------------------------------------------------
-- Registry
-- ---------------------------------------------------------------------------

function M.track(session_key, meta)
  if type(session_key) ~= "string" or session_key == "" or type(meta) ~= "table" then
    return false
  end
  tracked[session_key] = {
    name = tostring(meta.name or "?"),
    kind = tostring(meta.kind or "?"),
    cache = {},
  }
  return true
end

-- Idempotent; drops the session's relay cache with it.
function M.untrack(session_key)
  if session_key == nil then
    return false
  end
  if tracked[session_key] == nil then
    return false
  end
  tracked[session_key] = nil
  return true
end

function M.tracked(session_key)
  return tracked[session_key]
end

function M.tracked_count()
  local n = 0
  for _ in pairs(tracked) do
    n = n + 1
  end
  return n
end

-- Ids of the subagent tasks currently listed for the focused session
-- (empty when maki.task.list is unavailable, e.g. under `maki -p`).
--
-- maki.agent.list is WRONG here: it only lists sessions plugins opened
-- without a ctx (background sessions). Specialist sessions are opened with
-- the dispatch ctx, and those surface as tasks: maki.task.list entries carry
-- the session id as the task id, plus a plugin field — and that same id is
-- what ctx:task_id() reports inside the sub's tool calls.
function M.snapshot_ids(ctx)
  local ids = {}
  if type(maki) ~= "table" or type(maki.task) ~= "table" then
    return ids
  end
  local ok, tasks = pcall(function() return maki.task.list() end)
  if not ok or type(tasks) ~= "table" then
    return ids
  end
  for _, t in ipairs(tasks) do
    if type(t) == "table" and type(t.id) == "string" then
      ids[t.id] = true
    end
  end
  return ids
end

-- Register the session just opened by diffing maki.task.list against
-- `before`. Task entries carry the sub session's id and the opening plugin's
-- name, so the diff attributes the new task even when identically named
-- specialists are open concurrently. Returns the session key, or nil when
-- attribution failed (the relay then falls back to adopting the caller
-- lazily; when that fails too, prompts for the session keep denying as
-- before this feature existed).
function M.track_new(ctx, before, name, kind)
  if not Config.permission_relay then
    return nil
  end
  before = type(before) == "table" and before or {}
  if type(maki) ~= "table" or type(maki.task) ~= "table" then
    return nil
  end
  local ok, tasks = pcall(function() return maki.task.list() end)
  if not ok or type(tasks) ~= "table" then
    return nil
  end
  local want = tostring(name) .. ":" .. tostring(kind)
  for _, t in ipairs(tasks) do
    if type(t) == "table" and type(t.id) == "string" and t.id ~= ""
      and not before[t.id] and not tracked[t.id]
      and t.name == want and M.ours_entry(t) then
      M.track(t.id, { name = name, kind = kind })
      return t.id
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Caller identification and the relay layer
-- ---------------------------------------------------------------------------

local relay_logged = false

local function log_once(caller_id, session_id, via)
  if relay_logged then
    return
  end
  relay_logged = true
  pcall(function()
    maki.log.info(string.format(
      "specialist-subagents: permission relay engaged for caller %q via %s (session_id %q); "
        .. "if this call was not from a specialist, report it",
      tostring(caller_id), via, tostring(session_id)))
  end)
end

-- Fallback attribution: a subagent call whose id track_new never registered.
-- Verified against maki.task.list before relaying, so prompts from other
-- plugins' subagents pass through untouched.
function M.adopt(task_id)
  if type(task_id) ~= "string" or task_id == "" or task_id == "main" then
    return nil
  end
  if type(maki) ~= "table" or type(maki.task) ~= "table" then
    return nil
  end
  local ok, tasks = pcall(function() return maki.task.list() end)
  if not ok or type(tasks) ~= "table" then
    return nil
  end
  for _, t in ipairs(tasks) do
    if type(t) == "table" and t.id == task_id and M.ours_entry(t) then
      local name, kind = M.split_name(t.name)
      if name then
        M.track(task_id, { name = name, kind = kind })
        log_once(task_id, task_id, "adopt")
        return tracked[task_id]
      end
    end
  end
  return nil
end

-- Map the call's context to a tracked specialist session, or nil for calls
-- this plugin must not answer (main session, other plugins' subs).
-- Ids of the tasks currently listed for the focused session, or nil when
-- maki.task.list is unavailable. Used to re-verify that a tracked session is
-- still alive before relaying: a session attributed via the adopt() fallback
-- has no close-path untrack (dispatch only untracks its own track_new key),
-- so liveness is what keeps an adopted entry and its allow-for-session cache
-- from outliving the session. Task ids are not recycled, so a dead id can
-- never come back.
local function live_task_ids()
  if type(maki) ~= "table" or type(maki.task) ~= "table" then
    return nil
  end
  local ok, tasks = pcall(function() return maki.task.list() end)
  if not ok or type(tasks) ~= "table" then
    return nil
  end
  local live = {}
  for _, t in ipairs(tasks) do
    if type(t) == "table" and type(t.id) == "string" then
      live[t.id] = true
    end
  end
  return live
end

function M.identify(ctx)
  if type(ctx) ~= "table" and type(ctx) ~= "userdata" then
    return nil
  end
  local ok_t, task_id = pcall(function() return ctx:task_id() end)
  local ok_s, session_id = pcall(function() return ctx:session_id() end)
  task_id = ok_t and type(task_id) == "string" and task_id or nil
  session_id = ok_s and type(session_id) == "string" and session_id or nil

  -- Primary: the id track_new registered (the sub session's own id).
  local key, via
  if task_id and tracked[task_id] then
    key, via = task_id, "task_id"
  elseif session_id and tracked[session_id] then
    key, via = session_id, "session_id"
  end
  if key then
    local live = live_task_ids()
    if live and not live[key] then
      -- the session is gone (and was never untracked): drop it, cache and all
      M.untrack(key)
      return nil
    end
    log_once(key, session_id, via)
    return tracked[key]
  end
  -- Fallback: a subagent call we failed to register at open time.
  if task_id then
    return M.adopt(task_id)
  end
  return nil
end

-- The prompt window itself. Returns (decision | nil, guidance | nil): a
-- decision table on an answer, nil + guidance on timeout / close / failure.
-- Runs only inside maki (layer body); errors are caught by ask_user.
function M.prompt_window(entry, req, sig)
  local lines = M.prompt_spans(entry, req)
  lines[#lines + 1] = ""
  lines[#lines + 1] = {
    { "y", { bold = true } }, { " allow once    ", { dim = true } },
    { "s", { bold = true } }, { " allow for this specialist    ", { dim = true } },
    { "n", { bold = true } }, { " deny", { dim = true } },
  }

  local buf = maki.ui.buf()
  buf:lines(lines)

  local win, werr = maki.ui.open_win(buf, {
    title = "specialist permission",
    anchor = "input_caret",
    stack = true,
    focus = true,
    needs_input = true,
    footer = { { "y", "allow" }, { "s", "session" }, { "n", "deny" } },
  })
  if not win then
    return nil, M.GUIDANCE_OPEN_FAILED .. " (" .. tostring(werr) .. ")"
  end

  local deadline = os.time() + RELAY_WINDOW_S
  while true do
    if os.time() >= deadline then
      win:close()
      return nil, M.GUIDANCE_TIMEOUT
    end
    local ev = win:recv(RECV_SLICE_MS)
    if ev == nil then
      win:close()
      return nil, M.GUIDANCE_CLOSED
    end
    if ev.type == "close" then
      -- closed externally (channel may already be down; close is idempotent
      -- in effect here since we return immediately after)
      return nil, M.GUIDANCE_CLOSED
    end
    if ev.type == "key" then
      if ev.key == "y" then
        win:close()
        return { decision = "allow" }, nil
      elseif ev.key == "s" then
        win:close()
        M.cache_store(entry.cache, sig)
        return { decision = "allow" }, nil
      elseif ev.key == "n" or ev.key == "<Esc>" then
        win:close()
        return { decision = "deny", guidance = M.GUIDANCE_DENY }, nil
      end
      -- any other key: ignored, the window keeps waiting
    end
    -- resize / paste / timeout events: keep waiting
  end
end

function M.ask_user(entry, req, sig)
  local ok, decision, guidance = pcall(M.prompt_window, entry, req, sig)
  if not ok then
    return nil, M.GUIDANCE_OPEN_FAILED
  end
  return decision, guidance
end

-- The `permission.prompt` layer body.
function M.relay(prev, req, ctx)
  if not Config.permission_relay then
    return prev(req, ctx)
  end
  local entry = M.identify(ctx)
  if not entry then
    return prev(req, ctx)
  end
  local sig = M.scope_signature(req)
  local cached = M.decision_for(entry.cache, sig)
  if cached then
    return cached
  end
  local decision, guidance = M.ask_user(entry, req, sig)
  if not decision then
    return { decision = "deny", guidance = guidance or M.GUIDANCE_DENY }
  end
  return decision
end

-- Install the layer. Idempotent; a no-op without the maki host or when the
-- relay is disabled at install time (the layer also re-checks the config on
-- every call, so disabling after install still passes through).
local installed = false
function M.install()
  if installed then
    return true
  end
  if not Config.permission_relay then
    return false
  end
  if type(maki) ~= "table" or type(maki.api) ~= "table"
    or type(maki.api.set_slot) ~= "function" then
    return false
  end
  maki.api.set_slot("permission.prompt", function(prev, req, ctx)
    return M.relay(prev, req, ctx)
  end)
  installed = true
  return true
end

return M
