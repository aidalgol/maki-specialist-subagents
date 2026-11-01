-- Permission relay pure core: scope signatures, session cache, decision
-- mapping, prompt rendering, and caller attribution. The layer body itself
-- (UI prompt, slot install) needs the maki host and is covered by the live
-- verification checklist in the README.

local H = require("helpers")
local Permissions = require("specialist_subagents.permissions")

H.case("scope_signature: tool + sorted scopes, nil-safe", function()
  H.eq(Permissions.scope_signature(nil), "?|")
  H.eq(Permissions.scope_signature({ tool = "bash" }), "bash|")
  H.eq(
    Permissions.scope_signature({ tool = "edit", scopes = { "b/**", "a/**" } }),
    "edit|a/**\nb/**",
    "scopes sorted so order of appearance cannot split the cache")
  H.eq(
    Permissions.scope_signature({ tool = "edit", scopes = { "a/**", "b/**" } }),
    "edit|a/**\nb/**")
  H.eq(
    Permissions.scope_signature({ tool = "bash", scopes = { 42, "x", "" } }),
    "bash|x",
    "non-string and empty scopes ignored")
end)

H.case("session cache: store, decision_for, per-sig isolation", function()
  local cache = {}
  H.eq(Permissions.decision_for(cache, "bash|"), nil, "cold cache")
  Permissions.cache_store(cache, "bash|")
  H.eq(Permissions.decision_for(cache, "bash|"), { decision = "allow" })
  H.eq(Permissions.decision_for(cache, "bash|/tmp/**"), nil, "other scopes unaffected")
  H.eq(Permissions.decision_for(nil, "bash|"), nil, "nil cache")
  Permissions.cache_store(nil, "bash|x") -- must not raise
end)

H.case("guidance strings: non-empty deny guidance on every terminal path", function()
  for name, g in pairs({
    deny = Permissions.GUIDANCE_DENY,
    timeout = Permissions.GUIDANCE_TIMEOUT,
    open_failed = Permissions.GUIDANCE_OPEN_FAILED,
    closed = Permissions.GUIDANCE_CLOSED,
  }) do
    H.eq(type(g), "string", name .. " guidance is a string")
    H.eq(#g > 0, true, name .. " guidance is non-empty")
  end
end)

H.case("describe_input: first known field, flattened, truncated", function()
  H.eq(Permissions.describe_input({ tool = "bash", input = { command = "ruff check ." } }), "ruff check .")
  H.eq(Permissions.describe_input({ tool = "write", input = { file_path = "/x/y", content = "z" } }), "/x/y")
  H.eq(Permissions.describe_input({ tool = "bash", input = "raw string" }), "raw string")
  H.eq(Permissions.describe_input({ tool = "bash", input = { command = "a\nb\tc" } }), "a b c")
  H.eq(Permissions.describe_input({ tool = "bash", input = {} }), "")
  H.eq(Permissions.describe_input(nil), "")
  local long = string.rep("x", 300)
  local truncated = Permissions.describe_input({ tool = "bash", input = { command = long } })
  H.eq(#truncated <= 163, true, "long input truncated")
  H.eq(truncated:sub(-3), "\xe2\x80\xa6", "truncation marked with an ellipsis")
end)

H.case("prompt_spans: specialist, kind, tool, input, scopes", function()
  local req = { tool = "bash", input = { command = "cargo clippy" }, scopes = { "src/**" } }
  local lines = Permissions.prompt_spans({ name = "rust-reviewer", kind = "review" }, req)
  H.eq(#lines, 4)
  local flat = {}
  for i, line in ipairs(lines) do
    local parts = {}
    for _, span in ipairs(line) do
      parts[#parts + 1] = span[1]
    end
    flat[i] = table.concat(parts, "")
  end
  H.eq(flat[1], "specialist  rust-reviewer (review)")
  H.eq(flat[2], "tool        bash")
  H.eq(flat[3], "input       cargo clippy")
  H.eq(flat[4], "scopes      src/**")
  -- no input and no scopes: those lines are omitted
  local bare = Permissions.prompt_spans({ name = "s", kind = "task" }, { tool = "grep" })
  H.eq(#bare, 2)
end)

H.case("split_name: kind is the last segment, names may contain ':'", function()
  H.eq(Permissions.split_name("rust-reviewer:review"), "rust-reviewer")
  local spec, kind = Permissions.split_name("a:b:task")
  H.eq(spec, "a:b")
  H.eq(kind, "task")
  H.eq(Permissions.split_name("no-kind"), nil)
  H.eq(Permissions.split_name(":review"), nil)
  H.eq(Permissions.split_name(nil), nil)
  H.eq(Permissions.split_name(42), nil)
end)

H.case("ours_entry: id and exact plugin identity required, name must parse", function()
  H.eq(Permissions.ours_entry({ id = "t1", plugin = "project/init.lua", name = "rust-reviewer:review" }), true)
  H.eq(Permissions.ours_entry({ id = "t1", plugin = "user/init.lua", name = "rust-reviewer:review" }), true)
  H.eq(Permissions.ours_entry({ id = "t1", plugin = "specialist-subagents", name = "rust-reviewer:review" }), true)
  H.eq(Permissions.ours_entry({ id = "t1", plugin = "not-specialist-subagents-x", name = "rust-reviewer:review" }), false,
    "substring plugin names refused")
  H.eq(Permissions.ours_entry({ id = "t1", plugin = "other-plugin", name = "rust-reviewer:review" }), false)
  H.eq(Permissions.ours_entry({ id = "t1", name = "rust-reviewer:review" }), false, "missing plugin field refused")
  H.eq(Permissions.ours_entry({ id = "t1", plugin = "project/init.lua", name = "chat-helper" }), false)
  H.eq(Permissions.ours_entry({ name = "rust-reviewer:review" }), false, "no id")
  H.eq(Permissions.ours_entry({ id = "", plugin = "project/init.lua", name = "rust-reviewer:review" }), false)
  H.eq(Permissions.ours_entry(nil), false)
end)

H.case("track/untrack: registry holds meta + fresh cache, idempotent untrack", function()
  H.eq(Permissions.track("t1", { name = "rust-reviewer", kind = "review" }), true)
  local entry = Permissions.tracked("t1")
  H.eq(entry.name, "rust-reviewer")
  H.eq(entry.kind, "review")
  Permissions.cache_store(entry.cache, "bash|")
  H.eq(Permissions.decision_for(Permissions.tracked("t1").cache, "bash|"), { decision = "allow" })

  H.eq(Permissions.untrack("t1"), true)
  H.eq(Permissions.tracked("t1"), nil)
  H.eq(Permissions.untrack("t1"), false, "second untrack is a no-op")
  H.eq(Permissions.untrack(nil), false)

  H.eq(Permissions.track(nil, { name = "x", kind = "review" }), false, "bad key refused")
  H.eq(Permissions.track("", { name = "x", kind = "review" }), false)
  H.eq(Permissions.track("t2", nil), false, "bad meta refused")
  H.eq(Permissions.tracked_count(), 0)
end)

H.case("identify: tracked callers map to their entry; main-session calls pass", function()
  Permissions.track("sub-1", { name = "rust-reviewer", kind = "review" })
  local entry = Permissions.identify({
    task_id = function() return "sub-1" end,
    session_id = function() return "chat-7" end,
  })
  H.eq(entry ~= nil, true)
  H.eq(entry.name, "rust-reviewer")
  -- no subagent id (main session call): never identified
  H.eq(Permissions.identify({
    task_id = function() return nil end,
    session_id = function() return "chat-7" end,
  }), nil)
  -- untracked subagent id with no list to adopt from (no maki host here): pass
  H.eq(Permissions.identify({
    task_id = function() return "sub-unknown" end,
    session_id = function() return "chat-7" end,
  }), nil)
  H.eq(Permissions.identify(nil), nil)
  Permissions.untrack("sub-1")
end)

H.case("relay layer shape: pass-through contract honoured", function()
  -- The relay must hand non-specialist calls to prev untouched. Simulate with
  -- the config off, which forces the pass-through path without any ctx.
  -- The restore is guarded so a failing assert cannot leave the relay
  -- disabled for the rest of the suite.
  local Config = require("specialist_subagents.config")
  local was = Config.permission_relay
  local ok, err = pcall(function()
    Config.permission_relay = false
    local passed = false
    local out = Permissions.relay(function(rq, c)
      passed = true
      return { decision = "deny", guidance = "prompt" }
    end, { tool = "bash" }, nil)
    H.eq(passed, true, "disabled relay passes the call down")
    H.eq(out, { decision = "deny", guidance = "prompt" })
  end)
  Config.permission_relay = was
  if not ok then
    error(err)
  end
end)
