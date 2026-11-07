-- SPDX-FileCopyrightText: 2026 Aidan Gauland <aidalgol+git@fastmail.net>
--
-- SPDX-License-Identifier: MIT

-- The review report tail is a machine contract: Report.parse_verdict /
-- parse_summary / parse_findings key on these exact markers, and an
-- unparsable tail satisfies no review gate. These cases pin the preamble's
-- instruction so the wording cannot drift away from the parser.

local lu = require("luaunit")

local TestSessionBuilder = {}
local SB = require("specialist_subagents.session_builder")

local function review_preamble()
  return SB.preamble({ name = "x", type = "review" }, "review", { chain = {}, depth = 0 })
end

function TestSessionBuilder:test_review_preamble_states_the_machine_readable_tail_the_parser_keys_on()
  local p = review_preamble()
  lu.assertTrue(p:find("VERDICT: approve", 1, true) ~= nil, "bare approve token shown")
  lu.assertTrue(p:find("VERDICT: request-changes", 1, true) ~= nil, "bare request-changes token shown")
  lu.assertTrue(p:find("bare token on its own last line", 1, true) ~= nil,
    "bare-token rule stated")
  lu.assertTrue(p:find("SUMMARY:", 1, true) ~= nil, "SUMMARY marker instructed")
  lu.assertTrue(p:find("FINDINGS:", 1, true) ~= nil, "FINDINGS marker instructed")
  lu.assertTrue(p:find("satisfies no review gate", 1, true) ~= nil,
    "unparsable-tail consequence stated")
end

function TestSessionBuilder:test_task_preamble_carries_no_verdict_instruction()
  local p = SB.preamble({ name = "x", type = "implementation" }, "task", { chain = {}, depth = 0 })
  lu.assertEquals(p:find("VERDICT", 1, true), nil)
  lu.assertEquals(p:find("FINDINGS:", 1, true), nil)
end

function TestSessionBuilder:test_consult_preamble_advisory_framing_no_review_contract()
  local p = SB.preamble({ name = "x", type = "implementation" }, "consult", { chain = {}, depth = 0 })
  lu.assertEquals(p:find("VERDICT", 1, true), nil)
  lu.assertEquals(p:find("FINDINGS:", 1, true), nil)
  lu.assertTrue(p:find("consultation", 1, true) ~= nil, "mentions consultation")
  lu.assertTrue(p:find("not reviewing a diff", 1, true) ~= nil, "advisory role stated")
  -- review invocations keep their contract
  lu.assertTrue(review_preamble():find("VERDICT", 1, true) ~= nil)
end

-- The nested delegate tool translates the schema's keyed form
-- ({ ["<target-name>"] = { brief = ... } }) into the scalar form the dispatch
-- pipeline normalizes, and only for targets this invoker is allowed to call;
-- anything else reaches run_dispatch untouched and is refused there.
function TestSessionBuilder:test_local_delegate_keyed_input_translates_to_scalar_dispatch()
  local captured
  local tool = SB.build_local_delegate(
    nil, -- ctx is unused by the local delegate; the translation is pure
    { name = "test-engineer", chain = {} },
    { { name = "scss-reviewer", description = "d" } },
    function(input, invoker)
      captured = { input = input, invoker = invoker }
      return { llm_output = "dispatched" }
    end)
  local res = tool.delegate.handler({ ["scss-reviewer"] = { brief = "review my work" } })
  lu.assertEquals(res.llm_output, "dispatched")
  lu.assertEquals(captured.input.specialist, "scss-reviewer")
  lu.assertEquals(captured.input.brief, "review my work")
  lu.assertEquals(captured.input.targets, nil)
  lu.assertEquals(captured.invoker.name, "test-engineer")
end

function TestSessionBuilder:test_local_delegate_keyed_input_for_unallowed_target_passes_through_untouched()
  local captured
  local tool = SB.build_local_delegate(
    nil,
    { name = "test-engineer", chain = {} },
    { { name = "scss-reviewer", description = "d" } },
    function(input)
      captured = input
      return { llm_output = "error: refused", is_error = true }
    end)
  local keyed = { ["rogue-specialist"] = { brief = "sneak past the schema" } }
  local res = tool.delegate.handler(keyed)
  lu.assertEquals(res.is_error, true)
  lu.assertEquals(captured, keyed, "input reaches run_dispatch unchanged")
  lu.assertEquals(captured.specialist, nil,
    "a key outside allowed_targets is never translated into a specialist dispatch")
  lu.assertEquals(captured.targets, nil)
end

-- The capability-less-tool fix: select_tool_defs, parse_capability_less, and
-- reduce_defs_on_error are pure, so the exclusion classes and the retry
-- ladder are pinned without a live maki.
local FAKE_DEFS = {}
for _, name in ipairs({
  "read", "index", "grep", "glob", "list", "bash", "webfetch", "websearch",
  "skill", "todo_write", "memory", "view_image", "task_stop", "task_message",
  "batch", "code_execution", "task", "question", "delegate", "specialist_reviews",
}) do
  FAKE_DEFS[#FAKE_DEFS + 1] = { name = name }
end

local function names(defs)
  local out = {}
  for _, def in ipairs(defs) do
    out[#out + 1] = def.name
  end
  table.sort(out)
  return out
end

local CAPABILITY_LESS = "session open failed: tool 'skill' declares no capability, "
  .. "so a session of your own takes every permission"

function TestSessionBuilder:test_select_tool_defs_implementation_excludes_never_set()
  local got = names(SB.select_tool_defs(FAKE_DEFS, {}, "task"))
  lu.assertEquals(got, { "bash", "glob", "grep", "index", "list", "read",
    "webfetch", "websearch" })
end

function TestSessionBuilder:test_select_tool_defs_review_and_consult_use_review_defaults()
  local expected = { "bash", "glob", "grep", "index", "list", "read", "webfetch", "websearch" }
  lu.assertEquals(names(SB.select_tool_defs(FAKE_DEFS, {}, "review")), expected)
  lu.assertEquals(names(SB.select_tool_defs(FAKE_DEFS, {}, "consult")), expected)
end

function TestSessionBuilder:test_select_tool_defs_spec_tools_only_replaces_defaults()
  local got = SB.select_tool_defs(FAKE_DEFS, { tools = { only = { "read", "grep" } } }, "task")
  lu.assertEquals(names(got), { "grep", "read" })
end

function TestSessionBuilder:test_select_tool_defs_spec_tools_except_removes_names()
  local got = SB.select_tool_defs(FAKE_DEFS, { tools = { except = { "bash" } } }, "review")
  lu.assertEquals(names(got), { "glob", "grep", "index", "list", "read", "webfetch", "websearch" })
end

function TestSessionBuilder:test_select_tool_defs_clamps_unknown_names()
  local got = SB.select_tool_defs(FAKE_DEFS,
    { tools = { only = { "read", "nonexistent" } } }, "task")
  lu.assertEquals(names(got), { "read" }, "unknown names are clamped out")
end

function TestSessionBuilder:test_parse_capability_less_extracts_name_from_host_error()
  lu.assertEquals(SB.parse_capability_less(CAPABILITY_LESS), "skill")
  lu.assertEquals(SB.parse_capability_less("tool 'memory' declares no capability, period"),
    "memory", "lenient about surrounding text")
end

function TestSessionBuilder:test_parse_capability_less_returns_nil_for_other_errors()
  lu.assertEquals(SB.parse_capability_less("session open failed: some other reason"), nil)
  lu.assertEquals(SB.parse_capability_less(nil), nil)
  lu.assertEquals(SB.parse_capability_less(42), nil)
end

function TestSessionBuilder:test_reduce_defs_on_error_drops_the_named_tool()
  local err = "session open failed: tool 'memory' declares no capability, so ..."
  local reduced, dropped = SB.reduce_defs_on_error(FAKE_DEFS, err)
  lu.assertEquals(dropped, "memory")
  lu.assertEquals(#reduced, #FAKE_DEFS - 1)
  for _, def in ipairs(reduced) do
    lu.assertNotEquals(def.name, "memory", "exactly the named tool is dropped")
  end
end

function TestSessionBuilder:test_reduce_defs_on_error_falls_back_to_over_cost()
  -- error names a tool we do not hold: drop the first remaining OVER_COST member
  local err = "tool 'env' declares no capability, but 'env' is not in the toolset"
  local reduced, dropped = SB.reduce_defs_on_error(FAKE_DEFS, err)
  lu.assertEquals(dropped, "batch")
  lu.assertEquals(#reduced, #FAKE_DEFS - 1)
  -- ... and one per call until the over-cost set is gone
  local _, dropped2 = SB.reduce_defs_on_error(reduced, err)
  lu.assertEquals(dropped2, "code_execution")
  local _, dropped3 = SB.reduce_defs_on_error(reduced, "no tool name here")
  lu.assertEquals(dropped3, "code_execution", "falls back when the error names nothing")
end

function TestSessionBuilder:test_reduce_defs_on_error_exhausts_cleanly()
  local minimal = { { name = "read" }, { name = "bash" } }
  local reduced, dropped = SB.reduce_defs_on_error(
    minimal, "tool 'skill' declares no capability")
  lu.assertEquals(reduced, nil, "nothing droppable: ladder exhausted")
  lu.assertEquals(dropped, nil)
end

return TestSessionBuilder
