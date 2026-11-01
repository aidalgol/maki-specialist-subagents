-- Permission relay pure core: scope signatures, session cache, decision
-- mapping, prompt rendering, and caller attribution. The layer body itself
-- (UI prompt, slot install) needs the maki host and is covered by the live
-- verification checklist in the README.

local lu = require("luaunit")

local TestPermissions = {}
local Permissions = require("specialist_subagents.permissions")

function TestPermissions:test_scope_signature_tool_sorted_scopes_nil_safe()
  lu.assertEquals(Permissions.scope_signature(nil), "?|")
  lu.assertEquals(Permissions.scope_signature({ tool = "bash" }), "bash|")
  lu.assertEquals(
    Permissions.scope_signature({ tool = "edit", scopes = { "b/**", "a/**" } }),
    "edit|a/**\nb/**",
    "scopes sorted so order of appearance cannot split the cache")
  lu.assertEquals(
    Permissions.scope_signature({ tool = "edit", scopes = { "a/**", "b/**" } }),
    "edit|a/**\nb/**")
  lu.assertEquals(
    Permissions.scope_signature({ tool = "bash", scopes = { 42, "x", "" } }),
    "bash|x",
    "non-string and empty scopes ignored")
end

function TestPermissions:test_session_cache_store_decision_for_per_sig_isolation()
  local cache = {}
  lu.assertEquals(Permissions.decision_for(cache, "bash|"), nil, "cold cache")
  Permissions.cache_store(cache, "bash|")
  lu.assertEquals(Permissions.decision_for(cache, "bash|"), { decision = "allow" })
  lu.assertEquals(Permissions.decision_for(cache, "bash|/tmp/**"), nil, "other scopes unaffected")
  lu.assertEquals(Permissions.decision_for(nil, "bash|"), nil, "nil cache")
  Permissions.cache_store(nil, "bash|x") -- must not raise
end

function TestPermissions:test_guidance_strings_non_empty_deny_guidance_on_every_terminal_path()
  for name, g in pairs({
    deny = Permissions.GUIDANCE_DENY,
    timeout = Permissions.GUIDANCE_TIMEOUT,
    open_failed = Permissions.GUIDANCE_OPEN_FAILED,
    closed = Permissions.GUIDANCE_CLOSED,
  }) do
    lu.assertEquals(type(g), "string", name .. " guidance is a string")
    lu.assertEquals(#g > 0, true, name .. " guidance is non-empty")
  end
end

function TestPermissions:test_describe_input_first_known_field_flattened_truncated()
  lu.assertEquals(Permissions.describe_input({ tool = "bash", input = { command = "ruff check ." } }), "ruff check .")
  lu.assertEquals(Permissions.describe_input({ tool = "write", input = { file_path = "/x/y", content = "z" } }), "/x/y")
  lu.assertEquals(Permissions.describe_input({ tool = "bash", input = "raw string" }), "raw string")
  lu.assertEquals(Permissions.describe_input({ tool = "bash", input = { command = "a\nb\tc" } }), "a b c")
  lu.assertEquals(Permissions.describe_input({ tool = "bash", input = {} }), "")
  lu.assertEquals(Permissions.describe_input(nil), "")
  local long = string.rep("x", 300)
  local truncated = Permissions.describe_input({ tool = "bash", input = { command = long } })
  lu.assertEquals(#truncated <= 163, true, "long input truncated")
  lu.assertEquals(truncated:sub(-3), "\xe2\x80\xa6", "truncation marked with an ellipsis")
end

function TestPermissions:test_prompt_spans_specialist_kind_tool_input_scopes()
  local req = { tool = "bash", input = { command = "cargo clippy" }, scopes = { "src/**" } }
  local lines = Permissions.prompt_spans({ name = "rust-reviewer", kind = "review" }, req)
  lu.assertEquals(#lines, 4)
  local flat = {}
  for i, line in ipairs(lines) do
    local parts = {}
    for _, span in ipairs(line) do
      parts[#parts + 1] = span[1]
    end
    flat[i] = table.concat(parts, "")
  end
  lu.assertEquals(flat[1], "specialist  rust-reviewer (review)")
  lu.assertEquals(flat[2], "tool        bash")
  lu.assertEquals(flat[3], "input       cargo clippy")
  lu.assertEquals(flat[4], "scopes      src/**")
  -- no input and no scopes: those lines are omitted
  local bare = Permissions.prompt_spans({ name = "s", kind = "task" }, { tool = "grep" })
  lu.assertEquals(#bare, 2)
end

function TestPermissions:test_split_name_kind_is_the_last_segment_names_may_contain()
  lu.assertEquals(Permissions.split_name("rust-reviewer:review"), "rust-reviewer")
  local spec, kind = Permissions.split_name("a:b:task")
  lu.assertEquals(spec, "a:b")
  lu.assertEquals(kind, "task")
  lu.assertEquals(Permissions.split_name("no-kind"), nil)
  lu.assertEquals(Permissions.split_name(":review"), nil)
  lu.assertEquals(Permissions.split_name(nil), nil)
  lu.assertEquals(Permissions.split_name(42), nil)
end

function TestPermissions:test_ours_entry_id_and_exact_plugin_identity_required_name_must_parse()
  lu.assertEquals(Permissions.ours_entry({ id = "t1", plugin = "project/init.lua", name = "rust-reviewer:review" }), true)
  lu.assertEquals(Permissions.ours_entry({ id = "t1", plugin = "user/init.lua", name = "rust-reviewer:review" }), true)
  lu.assertEquals(Permissions.ours_entry({ id = "t1", plugin = "specialist-subagents", name = "rust-reviewer:review" }), true)
  lu.assertEquals(Permissions.ours_entry({ id = "t1", plugin = "not-specialist-subagents-x", name = "rust-reviewer:review" }), false,
    "substring plugin names refused")
  lu.assertEquals(Permissions.ours_entry({ id = "t1", plugin = "other-plugin", name = "rust-reviewer:review" }), false)
  lu.assertEquals(Permissions.ours_entry({ id = "t1", name = "rust-reviewer:review" }), false, "missing plugin field refused")
  lu.assertEquals(Permissions.ours_entry({ id = "t1", plugin = "project/init.lua", name = "chat-helper" }), false)
  lu.assertEquals(Permissions.ours_entry({ name = "rust-reviewer:review" }), false, "no id")
  lu.assertEquals(Permissions.ours_entry({ id = "", plugin = "project/init.lua", name = "rust-reviewer:review" }), false)
  lu.assertEquals(Permissions.ours_entry(nil), false)
end

function TestPermissions:test_track_untrack_registry_holds_meta_fresh_cache_idempotent_untrack()
  lu.assertEquals(Permissions.track("t1", { name = "rust-reviewer", kind = "review" }), true)
  local entry = Permissions.tracked("t1")
  lu.assertEquals(entry.name, "rust-reviewer")
  lu.assertEquals(entry.kind, "review")
  Permissions.cache_store(entry.cache, "bash|")
  lu.assertEquals(Permissions.decision_for(Permissions.tracked("t1").cache, "bash|"), { decision = "allow" })

  lu.assertEquals(Permissions.untrack("t1"), true)
  lu.assertEquals(Permissions.tracked("t1"), nil)
  lu.assertEquals(Permissions.untrack("t1"), false, "second untrack is a no-op")
  lu.assertEquals(Permissions.untrack(nil), false)

  lu.assertEquals(Permissions.track(nil, { name = "x", kind = "review" }), false, "bad key refused")
  lu.assertEquals(Permissions.track("", { name = "x", kind = "review" }), false)
  lu.assertEquals(Permissions.track("t2", nil), false, "bad meta refused")
  lu.assertEquals(Permissions.tracked_count(), 0)
end

function TestPermissions:test_identify_tracked_callers_map_to_their_entry_main_session_calls_pass()
  Permissions.track("sub-1", { name = "rust-reviewer", kind = "review" })
  local entry = Permissions.identify({
    task_id = function() return "sub-1" end,
    session_id = function() return "chat-7" end,
  })
  lu.assertEquals(entry ~= nil, true)
  lu.assertEquals(entry.name, "rust-reviewer")
  -- no subagent id (main session call): never identified
  lu.assertEquals(Permissions.identify({
    task_id = function() return nil end,
    session_id = function() return "chat-7" end,
  }), nil)
  -- untracked subagent id with no list to adopt from (no maki host here): pass
  lu.assertEquals(Permissions.identify({
    task_id = function() return "sub-unknown" end,
    session_id = function() return "chat-7" end,
  }), nil)
  lu.assertEquals(Permissions.identify(nil), nil)
  Permissions.untrack("sub-1")
end

function TestPermissions:test_relay_layer_shape_pass_through_contract_honoured()
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
    lu.assertEquals(passed, true, "disabled relay passes the call down")
    lu.assertEquals(out, { decision = "deny", guidance = "prompt" })
  end)
  Config.permission_relay = was
  if not ok then
    error(err)
  end
end

return TestPermissions
