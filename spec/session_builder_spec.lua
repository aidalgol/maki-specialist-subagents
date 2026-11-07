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

return TestSessionBuilder
