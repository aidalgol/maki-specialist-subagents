-- SPDX-FileCopyrightText: 2026 Aidan Gauland <aidalgol+git@fastmail.net>
--
-- SPDX-License-Identifier: MIT

-- agent.compact.before layer: defer an automatic compaction of the parent
-- chat session once while specialist dispatches from that session are still running.
--
-- maki fires the layer with { reason, context_size, usable,
-- request_instructions } before every compaction. Returning
-- { defer = text } for reason "auto" skips that compaction by one turn and
-- makes `text` the model's next message, so the model can record the
-- in-flight dispatch ids with tools before the summary replaces the
-- history. maki grants at most one defer between two compactions, and
-- ignores defer for "overflow" / "manual" / "requested" (an overflow cannot
-- be skipped anyway, and a requested compaction is deliberate), so this
-- module needs no rate limiting of its own.
--
-- The defer text is built from dispatch counts and ids only — never from
-- model output or user text — so there is no injection surface: a layer
-- cannot smuggle instructions into the save-turn prompt beyond what the
-- registry already contains.
--
-- Layers share the `defer` / `continue` / `instructions` strings; assigning
-- erases what another layer wrote. install()'s layer appends (and allows
-- for nil), per the hooks docs.
--
-- Cost: an agent.* layer needs `agent` + `session_read` + `session_write`,
-- all held (see plugin.toml).

-- Tolerant require: dotted in maki, file-relative under the luau CLI.
local ok_compat, Compat = pcall(require, "specialist_subagents.compat")
if not ok_compat or type(Compat) ~= "table" then
  Compat = require("./compat")
end

local Config = Compat.require("specialist_subagents.config", "./config")

local M = {}

-- Only our own dispatch id shapes pass: "d-<n>" (synchronous) and
-- "bg-<n>" (background). Anything else — a longer id, control characters,
-- a newline — is dropped, so a hostile or corrupted registry entry can
-- never reach the defer text.
local function safe_dispatch_id(id)
  if type(id) ~= "string" then
    return nil
  end
  if id:match("^d%-%d+$") or id:match("^bg%-%d+$") then
    return id
  end
  return nil
end

-- The defer decision. Returns the defer text, or nil when the compaction
-- must proceed untouched:
--   * reason ~= "auto": maki ignores defer for the other reasons anyway;
--   * running_count < 1: nothing of ours is in flight;
--   * every id failed the shape check (never expected; defensive).
function M.defer_decision(reason, running_count, dispatch_ids)
  if reason ~= "auto" then
    return nil
  end
  local n = math.floor(tonumber(running_count) or 0)
  if n < 1 then
    return nil
  end
  local safe = {}
  if type(dispatch_ids) == "table" then
    for _, id in ipairs(dispatch_ids) do
      local s = safe_dispatch_id(id)
      if s then
        safe[#safe + 1] = s
      end
      if #safe >= 16 then
        break
      end
    end
  end
  local which = #safe > 0 and table.concat(safe, ", ")
    or "dispatch ids unknown (registry entry aged out)"
  return string.format(
    "Automatic compaction deferred: %d specialist dispatch(es) still running (%s). "
      .. "Before doing anything else, record their ids and what each is waiting on "
      .. "so their reports can be matched after compaction. Compaction will resume "
      .. "after this turn.",
    n, which)
end

-- Install the layer. Idempotent; a no-op without the maki host or when
-- defer_compact is disabled at install time (the layer also re-checks the
-- config on every call, so disabling after install still passes through).
local installed = false
function M.install()
  if installed then
    return true
  end
  if not Config.defer_compact then
    return false
  end
  if type(maki) ~= "table" or type(maki.api) ~= "table"
    or type(maki.api.set_slot) ~= "function" then
    return false
  end

  local Dispatch = Compat.require("specialist_subagents.dispatch", "./dispatch")

  maki.api.set_slot("agent.compact.before", function(prev, value, ctx)
    if not Config.defer_compact then
      return prev(value, ctx)
    end
    -- ctx carries session_id as a field (agent slots, per the hooks docs);
    -- the field may instead be a method (the shape session_id_of handles
    -- elsewhere in this plugin) or ctx may be userdata with a method. All
    -- three resolve through pcall, so a mismatching ctx shape degrades to
    -- "no running dispatches" instead of raising into the host.
    local session_id
    if type(ctx) == "table" or type(ctx) == "userdata" then
      local v = ctx.session_id
      if type(v) == "function" then
        local ok, sid = pcall(v, ctx)
        session_id = ok and sid or nil
      else
        session_id = v
      end
    end
    local count, ids = Dispatch.running_for_session(session_id)
    local text = M.defer_decision(type(value) == "table" and value.reason or nil,
      count, ids)
    if text then
      value = type(value) == "table" and value or {}
      -- Append, never assign: another layer's defer/continue/instructions
      -- must survive ours. A prior layer's non-string defer is left alone
      -- (it would raise on concatenation); ours replaces it.
      value.defer = type(value.defer) == "string"
        and (value.defer .. "\n" .. text)
        or text
    end
    return prev(value, ctx)
  end)
  installed = true
  return true
end

return M
