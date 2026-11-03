-- SPDX-FileCopyrightText: 2026 Aidan Gauland <aidalgol+git@fastmail.net>
--
-- SPDX-License-Identifier: MIT

-- Verdict/finding parsing and report formatting.

local lu = require("luaunit")

local TestReport = {}
local Report = require("specialist_subagents.report")

function TestReport:test_verdict_plain_approve()
  lu.assertEquals(Report.parse_verdict("notes\nVERDICT: approve"), "approve")
end

function TestReport:test_verdict_request_changes_with_markdown_decoration()
  lu.assertEquals(Report.parse_verdict("**VERDICT:** `request-changes`."), "request-changes")
end

function TestReport:test_verdict_request_changes_with_a_space()
  lu.assertEquals(Report.parse_verdict("verdict: Request Changes"), "request-changes")
end

function TestReport:test_verdict_unknown_token_is_unparsable()
  lu.assertEquals(Report.parse_verdict("VERDICT: maybe"), nil)
  lu.assertEquals(Report.parse_verdict("VERDICT: approved-ish"), nil)
end

function TestReport:test_verdict_absent_is_nil()
  lu.assertEquals(Report.parse_verdict("looks fine to me"), nil)
end

function TestReport:test_verdict_last_mention_wins()
  lu.assertEquals(Report.parse_verdict("VERDICT: request-changes\n...\nVERDICT: approve"), "approve")
end

function TestReport:test_verdict_non_string_input_never_raises()
  lu.assertEquals(Report.parse_verdict(nil), nil)
  lu.assertEquals(Report.parse_verdict(42), nil)
end

function TestReport:test_findings_numbered_block()
  local f = Report.parse_findings("FINDINGS:\n1. first\n2. second")
  lu.assertEquals(#f, 2)
  lu.assertEquals(f[1], { n = 1, text = "first" })
  lu.assertEquals(f[2], { n = 2, text = "second" })
end

function TestReport:test_findings_parenthesized_and_dashed_numbers()
  local f = Report.parse_findings("Findings:\n1) alpha\n- 2. beta")
  lu.assertEquals(#f, 2)
  lu.assertEquals(f[1].text, "alpha")
  lu.assertEquals(f[2].text, "beta")
end

function TestReport:test_findings_inline_with_the_header()
  local f = Report.parse_findings("FINDINGS: 1. only one")
  lu.assertEquals(#f, 1)
  lu.assertEquals(f[1].text, "only one")
end

function TestReport:test_findings_block_ends_at_verdict_and_blank_lines()
  local f = Report.parse_findings("FINDINGS:\n1. one\n\nVERDICT: approve")
  lu.assertEquals(#f, 1)
end

function TestReport:test_findings_none()
  lu.assertEquals(#Report.parse_findings("FINDINGS:\nVERDICT: approve"), 0)
  lu.assertEquals(#Report.parse_findings("no findings here"), 0)
end

function TestReport:test_summary_inline()
  lu.assertEquals(Report.parse_summary("SUMMARY: all good\nVERDICT: approve"), "all good")
end

function TestReport:test_summary_continues_across_lines_until_a_blank()
  lu.assertEquals(Report.parse_summary("Summary:\nfirst part\nsecond part\n\nFINDINGS:"), "first part second part")
end

function TestReport:test_summary_markdown_stripped()
  lu.assertEquals(Report.parse_summary("**SUMMARY:** **bold** claim"), "bold claim")
end

function TestReport:test_summary_absent()
  lu.assertEquals(Report.parse_summary("nothing"), nil)
end

function TestReport:test_parse_review_full_tail()
  local p = Report.parse_review(table.concat({
    "## Review",
    "The change looks mostly fine.",
    "",
    "SUMMARY: one issue with the guard",
    "FINDINGS:",
    "1. missing error check on read",
    "2. session not closed on error path",
    "VERDICT: request-changes",
  }, "\n"))
  lu.assertEquals(p.known, true)
  lu.assertEquals(p.verdict, "request-changes")
  lu.assertEquals(#p.findings, 2)
  lu.assertEquals(p.summary, "one issue with the guard")
end

function TestReport:test_parse_review_garbage_degrades_to_raw()
  local p = Report.parse_review("this model ignored the contract entirely")
  lu.assertEquals(p.known, false)
  lu.assertEquals(p.verdict, nil)
  lu.assertEquals(p.raw, "this model ignored the contract entirely")
end

function TestReport:test_format_target_review_section_carries_verdict_and_flags()
  local text = Report.format_target({
    specialist = "scss-reviewer", kind = "review", status = "done",
    verdict = "approve", cached = true,
    scope_files = { "a.scss" }, chain = {}, warnings = {},
    tokens = { input = 1200, output = 300 }, duration_ms = 45000,
  })
  lu.assertStrContains(text, "scss-reviewer (review) -- approve [CACHED REVIEW]")
  lu.assertStrContains(text, "Files: a.scss")
  lu.assertStrContains(text, "1.2k in / 0.3k out")
  lu.assertStrContains(text, "Chain: main")
end

function TestReport:test_format_target_unparsable_review_surfaces_raw_text()
  local text = Report.format_target({
    specialist = "r", kind = "review", status = "done",
    scope_files = {}, chain = {}, warnings = {}, raw = "no tail at all",
  })
  lu.assertStrContains(text, "unparsed verdict")
  lu.assertStrContains(text, "no tail at all")
end

function TestReport:test_format_aggregate_counts_totals_warning_dedup()
  local text = Report.format_aggregate({
    { specialist = "a", kind = "review", status = "done", verdict = "approve",
      tokens = { input = 100, output = 50 }, duration_ms = 1000, warnings = { "w1" } },
    { specialist = "b", kind = "review", status = "done", verdict = "request-changes",
      tokens = { input = 200, output = 100 }, duration_ms = 2500, warnings = { "w1", "w2" } },
    { specialist = "c", kind = "task", status = "refused", error = "nope", warnings = {} },
  })
  lu.assertStrContains(text, "3 target(s), 2 completed, 1 not completed")
  lu.assertStrContains(text, "0.3k in / 0.1k out")
  lu.assertStrContains(text, "Warnings (2):")
  lu.assertStrContains(text, "w2")
end

function TestReport:test_format_coverage_table_and_uncovered_suggestions()
  local text = Report.format_coverage({
    { path = "a.scss", specialist = "scss-reviewer", verdict = "approve", cached = true },
  }, {
    { path = "src/x.lua", suggestion = { specialist = "lua-code-reviewer", glob = "lua/**/*.lua" } },
  })
  lu.assertStrContains(text, "Review coverage:")
  lu.assertStrContains(text, "a.scss")
  lu.assertStrContains(text, "approve (CACHED)")
  lu.assertStrContains(text, "UNCOVERED")
  lu.assertStrContains(text, "src/x.lua")
  lu.assertStrContains(text, "suggested: lua-code-reviewer")
end

function TestReport:test_format_coverage_empty_input_is_empty()
  lu.assertEquals(Report.format_coverage(nil, nil), "")
end

-- Two specialists covering one file render on one row, comma-joined, with
-- each verdict carrying its own (CACHED) suffix. A single-specialist row is
-- unchanged from the legacy format.
function TestReport:test_format_coverage_renders_multi_specialist_rows()
  local text = Report.format_coverage({
    { path = "a.lua", reviewers = {
      { specialist = "new-reviewer", verdict = "request-changes" },
      { specialist = "old-reviewer", verdict = "approve", cached = true },
    } },
    { path = "b.lua", reviewers = {
      { specialist = "solo-reviewer", verdict = "approve" },
    } },
  }, nil)
  lu.assertStrContains(text, "new-reviewer, old-reviewer")
  lu.assertStrContains(text, "request-changes, approve (CACHED)")
  lu.assertStrContains(text, "solo-reviewer")
  lu.assertStrContains(text, "b.lua")
  -- no format change for the single-specialist case
  lu.assertTrue(text:find("solo%-reviewer%s+approve\n") ~= nil
    or text:find("solo%-reviewer%s+approve$") ~= nil
    or text:find("solo%-reviewer%s+approve") ~= nil)
end

function TestReport:test_format_aggregate_consult_result_renders_without_review_machinery()
  local long = string.rep("advice ", 800) -- well past any line length, under the 4000 cap
  local text = Report.format_aggregate({
    { specialist = "technical-writer", kind = "consult", status = "done",
      summary = long:sub(1, 4000), raw = long, chain = {}, warnings = {},
      tokens = { input = 900, output = 700 }, duration_ms = 12000 },
  })
  lu.assertStrContains(text, "1 target(s), 1 completed, 0 not completed")
  lu.assertStrContains(text, "technical-writer (consult) -- done")
  lu.assertStrContains(text, "Summary: advice")
  lu.assertEquals(text:find("VERDICT", 1, true), nil, "no review machinery")
  lu.assertEquals(text:find("UNCOVERED", 1, true), nil, "no coverage audit for consults")
end

-- ---------------------------------------------------------------------------
-- Background receipts, status, and action results (plan: refined-casual-grouse)
-- ---------------------------------------------------------------------------

function TestReport:test_format_receipt_lists_specialists_and_do_not_redispatch()
  local text = Report.format_receipt("bg-3", {
    { specialist = "lua-code-reviewer", kind = "review" },
    { specialist = "security-engineer", kind = "review" },
  }, {})
  lu.assertStrContains(text, "bg-3")
  lu.assertStrContains(text, "lua-code-reviewer(review)")
  lu.assertStrContains(text, "security-engineer(review)")
  lu.assertStrContains(text, "do not re-dispatch")
  lu.assertStrContains(text, "arrive as a message")
end

function TestReport:test_format_receipt_lists_validation_refusals()
  local text = Report.format_receipt("bg-9", {
    { specialist = "a", kind = "review" },
  }, { { specialist = "b", status = "refused", error = "unknown specialist: b" } })
  lu.assertStrContains(text, "Refused at validation: b -- unknown specialist: b")
  lu.assertStrContains(text, "1 specialist(s)")
end

function TestReport:test_format_status_empty_and_populated()
  lu.assertEquals(Report.format_status(nil), "No running specialist dispatches.")
  lu.assertEquals(Report.format_status({}), "No running specialist dispatches.")
  local text = Report.format_status({
    {
      id = "bg-2", background = true, started_at = 100,
      targets = {
        { specialist = "r1", kind = "review", status = "running" },
        { specialist = "t1", kind = "task", status = "stopping" },
      },
    },
    {
      id = "d-1", background = false, started_at = 90,
      targets = { { specialist = "r0", kind = "review", status = "running" } },
    },
  }, 150)
  lu.assertStrContains(text, "Running specialist dispatches: 2")
  lu.assertStrContains(text, "bg-2 (background, 50s): r1(review) running, t1(task) stopping")
  lu.assertStrContains(text, "d-1 (60s): r0(review) running")
end

function TestReport:test_format_action_result_counts_delivered_and_refused()
  local text = Report.format_action_result("message", {
    { dispatch = "bg-1", specialist = "r1", kind = "review", ok = true, detail = "queued" },
    { dispatch = "bg-1", specialist = "r2", kind = "review", ok = false,
      detail = "no live session (not started yet, or already finished)" },
  })
  lu.assertStrContains(text, "Message result: 1 delivered, 1 not delivered")
  lu.assertStrContains(text, "bg-1 r1(review): queued")
  lu.assertStrContains(text, "bg-1 r2(review): refused (no live session")
  -- empty match set stays a single informative line
  text = Report.format_action_result("stop", {})
  lu.assertStrContains(text, "Stop result: 0 delivered, 0 not delivered")
  lu.assertStrContains(text, "no matched specialist sessions")
end

return TestReport
