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

function TestReport:test_verdict_prose_prefix_with_markdown_decoration()
  lu.assertEquals(Report.parse_verdict("Review verdict: **approve**"), "approve")
end

function TestReport:test_verdict_prose_prefix_lowercase()
  lu.assertEquals(Report.parse_verdict("review verdict: approve"), "approve")
end

function TestReport:test_verdict_capitalised_word_mid_line()
  lu.assertEquals(Report.parse_verdict("Final Verdict: request-changes"), "request-changes")
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

-- A finding that quotes a section word mid-text must not close the block:
-- the item shape wins over the marker match, so neither that finding nor
-- the ones after it are dropped.
function TestReport:test_findings_quoting_marker_words_do_not_close_block()
  local text = table.concat({
    "FINDINGS:",
    "1. The tail must end with VERDICT: approve",
    "2. second issue",
    "VERDICT: request-changes",
  }, "\n")
  local f = Report.parse_findings(text)
  lu.assertEquals(#f, 2)
  -- strip_markdown drops the markdown characters but keeps the colon
  lu.assertEquals(f[1], { n = 1, text = "The tail must end with VERDICT: approve" })
  lu.assertEquals(f[2], { n = 2, text = "second issue" })
  -- the last line is the real marker, so the verdict survives intact
  lu.assertEquals(Report.parse_review(text).verdict, "request-changes")
end

-- A bold-anchored finding quoting "FINDINGS:" mid-text is stored, not
-- mistaken for the block opener or a terminator.
function TestReport:test_findings_bold_anchor_quoting_marker_word_is_stored()
  local f = Report.parse_findings(table.concat({
    "### Findings",
    "**a:9** — must emit FINDINGS: before VERDICT:",
    "",
    "### Verdict",
    "VERDICT: approve",
  }, "\n"))
  lu.assertEquals(#f, 1)
  lu.assertStrContains(f[1].text, "a:9 — ")
  lu.assertStrContains(f[1].text, "must emit FINDINGS: before")
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

-- ---------------------------------------------------------------------------
-- Widened parsers: heading-form summaries, bullet and bold-anchored findings,
-- and the raw-dump / coverage wording that came with them.
-- ---------------------------------------------------------------------------

-- A verbatim tail of a live drift incident: a heading-shaped findings block,
-- bold-anchored findings separated by blank lines, and a heading-form verdict.
-- None of this parsed before the widening.
function TestReport:test_parse_review_bold_anchored_findings_fixture()
  local p = Report.parse_review(table.concat({
    "### Findings",
    "",
    [[**AGENTS.md:55-60** — The bullet point contains two separate ideas in a single sentence, violating the style guide's "one idea per sentence" rule. The clause "Cover it in `spec/*_spec.lua`" should be a separate sentence. The instruction for placing logic ends with a period after the parenthetical list.]],
    "",
    [[**AGENTS.md:73** — The path string `.maki/specialists/*.md` is missing inline code formatting. The surrounding code uses backticks for paths (e.g., `lua/specialist_subagents.lua` on line 42), but this path lacks the markdown code span markers around it.]],
    "",
    "### Verdict",
    "",
    "VERDICT: request-changes",
  }, "\n"))
  lu.assertEquals(p.known, true)
  lu.assertEquals(p.verdict, "request-changes")
  lu.assertEquals(p.summary, nil)
  lu.assertEquals(#p.findings, 2)
  -- unnumbered items get sequential numbers from an internal counter
  lu.assertEquals(p.findings[1].n, 1)
  lu.assertEquals(p.findings[2].n, 2)
  -- the bold anchor is kept in the stored text (whole line, stripped)
  local prefix1 = "AGENTS.md:55-60 — "
  lu.assertEquals(p.findings[1].text:sub(1, #prefix1), prefix1)
  lu.assertStrContains(p.findings[1].text, "one idea per sentence")
  -- strip_markdown mangles inline code slightly (`spec/*_spec.lua` ->
  -- `spec/spec.lua`), so assert against the stripped form
  lu.assertStrContains(p.findings[1].text,
    [[The clause "Cover it in spec/spec.lua" should be a separate sentence]])
  local prefix2 = "AGENTS.md:73 — "
  lu.assertEquals(p.findings[2].text:sub(1, #prefix2), prefix2)
  lu.assertStrContains(p.findings[2].text, "is missing inline code formatting")
  -- the "### Verdict" heading closed the block; it must not be a finding
  for _, f in ipairs(p.findings) do
    lu.assertEquals(f.text:find("Verdict", 1, true), nil)
  end
end

-- A "### Summary" heading collects the prose below it until a blank line or
-- any section marker; it never swallows the findings opener.
function TestReport:test_summary_heading_form_stops_before_findings_opener()
  lu.assertEquals(Report.parse_summary(table.concat({
    "### Summary",
    "One issue found.",
    "",
    "### Findings",
    "1. whatever",
  }, "\n")), "One issue found.")
  -- no blank line before the findings opener: it still terminates
  lu.assertEquals(Report.parse_summary(table.concat({
    "### Summary",
    "Two lines",
    "of summary text.",
    "### Findings",
    "1. x",
  }, "\n")), "Two lines of summary text.")
end

-- "**FINDINGS:**" opens the block too; bullet items carry no explicit number,
-- so the internal counter numbers them sequentially.
function TestReport:test_findings_bold_opener_with_bullets_numbers_sequentially()
  local f = Report.parse_findings(table.concat({
    "**FINDINGS:**",
    "",
    "- one issue",
    "",
    "- two issue",
  }, "\n"))
  lu.assertEquals(f, { { n = 1, text = "one issue" }, { n = 2, text = "two issue" } })
end

-- A blank line is only a soft separator: unnumbered prose after it is not
-- finding-shaped, so the block closes and the prose is dropped.
function TestReport:test_findings_prose_after_blank_is_not_a_finding()
  local f = Report.parse_findings(table.concat({
    "FINDINGS:",
    "1. one",
    "",
    "some closing prose",
  }, "\n"))
  lu.assertEquals(#f, 1)
  lu.assertEquals(f[1], { n = 1, text = "one" })
end

-- A "### Verdict" heading closes the findings block without a preceding
-- blank line, so the verdict heading is never slurped into a finding.
function TestReport:test_findings_verdict_heading_closes_without_blank()
  local f = Report.parse_findings(table.concat({
    "### Findings",
    "**a:1** — bad thing",
    "",
    "### Verdict",
    "VERDICT: request-changes",
  }, "\n"))
  lu.assertEquals(#f, 1)
  lu.assertEquals(f[1].n, 1)
  local prefix = "a:1 — "
  lu.assertEquals(f[1].text:sub(1, #prefix), prefix)
end

-- A parsed verdict with neither findings nor summary is only partially
-- parsed: the note says so and the raw tail follows.
function TestReport:test_format_target_partially_parsed_review_appends_raw_after_note()
  local text = Report.format_target({
    specialist = "r", kind = "review", status = "done",
    verdict = "request-changes", findings = {}, summary = nil,
    scope_files = {}, chain = {}, warnings = {}, raw = "some raw tail",
  })
  lu.assertStrContains(text,
    "Note: report tail was unparsable or only partially parsed; raw review text follows.")
  lu.assertStrContains(text, "some raw tail")
end

-- A verdict plus at least one finding is a fully parsed review: the raw
-- review text stays hidden.
function TestReport:test_format_target_verdict_with_findings_hides_raw()
  local text = Report.format_target({
    specialist = "r", kind = "review", status = "done",
    verdict = "approve", findings = { { n = 1, text = "x" } },
    summary = nil, scope_files = {}, chain = {}, warnings = {},
    raw = "SECRET RAW",
  })
  lu.assertStrContains(text, " 1. x")
  lu.assertEquals(text:find("SECRET RAW", 1, true), nil)
end

-- A verdict plus a summary also counts as parsed: no raw dump either.
function TestReport:test_format_target_verdict_with_summary_only_hides_raw()
  local text = Report.format_target({
    specialist = "r", kind = "review", status = "done",
    verdict = "approve", findings = {}, summary = "fine overall",
    scope_files = {}, chain = {}, warnings = {}, raw = "STILL SECRET",
  })
  lu.assertStrContains(text, "Summary: fine overall")
  lu.assertEquals(text:find("STILL SECRET", 1, true), nil)
end

-- A legacy row (no reviewers list) that never got a review renders
-- UNREVIEWED, matching reviews_lookup's wording; a reviewers-list entry
-- without a verdict is still just unparsed.
function TestReport:test_format_coverage_legacy_row_without_verdict_is_unreviewed()
  local text = Report.format_coverage({
    { path = "a.lua", specialist = "r", verdict = nil },
    { path = "b.lua", reviewers = { { specialist = "s", verdict = nil } } },
  }, nil)
  lu.assertStrContains(text, "a.lua")
  lu.assertStrContains(text, "UNREVIEWED")
  lu.assertStrContains(text, "b.lua")
  lu.assertStrContains(text, "unparsed")
end

return TestReport
