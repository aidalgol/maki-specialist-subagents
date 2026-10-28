-- Verdict/finding parsing and report formatting.

local H = require("helpers")
local Report = require("specialist_subagents.report")

H.case("verdict: plain approve", function()
  H.eq(Report.parse_verdict("notes\nVERDICT: approve"), "approve")
end)

H.case("verdict: request-changes with markdown decoration", function()
  H.eq(Report.parse_verdict("**VERDICT:** `request-changes`."), "request-changes")
end)

H.case("verdict: request changes with a space", function()
  H.eq(Report.parse_verdict("verdict: Request Changes"), "request-changes")
end)

H.case("verdict: unknown token is unparsable", function()
  H.eq(Report.parse_verdict("VERDICT: maybe"), nil)
  H.eq(Report.parse_verdict("VERDICT: approved-ish"), nil)
end)

H.case("verdict: absent is nil", function()
  H.eq(Report.parse_verdict("looks fine to me"), nil)
end)

H.case("verdict: last mention wins", function()
  H.eq(Report.parse_verdict("VERDICT: request-changes\n...\nVERDICT: approve"), "approve")
end)

H.case("verdict: non-string input never raises", function()
  H.eq(Report.parse_verdict(nil), nil)
  H.eq(Report.parse_verdict(42), nil)
end)

H.case("findings: numbered block", function()
  local f = Report.parse_findings("FINDINGS:\n1. first\n2. second")
  H.eq(#f, 2)
  H.eq(f[1], { n = 1, text = "first" })
  H.eq(f[2], { n = 2, text = "second" })
end)

H.case("findings: parenthesized and dashed numbers", function()
  local f = Report.parse_findings("Findings:\n1) alpha\n- 2. beta")
  H.eq(#f, 2)
  H.eq(f[1].text, "alpha")
  H.eq(f[2].text, "beta")
end)

H.case("findings: inline with the header", function()
  local f = Report.parse_findings("FINDINGS: 1. only one")
  H.eq(#f, 1)
  H.eq(f[1].text, "only one")
end)

H.case("findings: block ends at VERDICT and blank lines", function()
  local f = Report.parse_findings("FINDINGS:\n1. one\n\nVERDICT: approve")
  H.eq(#f, 1)
end)

H.case("findings: none", function()
  H.eq(#Report.parse_findings("FINDINGS:\nVERDICT: approve"), 0)
  H.eq(#Report.parse_findings("no findings here"), 0)
end)

H.case("summary: inline", function()
  H.eq(Report.parse_summary("SUMMARY: all good\nVERDICT: approve"), "all good")
end)

H.case("summary: continues across lines until a blank", function()
  H.eq(Report.parse_summary("Summary:\nfirst part\nsecond part\n\nFINDINGS:"), "first part second part")
end)

H.case("summary: markdown stripped", function()
  H.eq(Report.parse_summary("**SUMMARY:** **bold** claim"), "bold claim")
end)

H.case("summary: absent", function()
  H.eq(Report.parse_summary("nothing"), nil)
end)

H.case("parse_review: full tail", function()
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
  H.eq(p.known, true)
  H.eq(p.verdict, "request-changes")
  H.eq(#p.findings, 2)
  H.eq(p.summary, "one issue with the guard")
end)

H.case("parse_review: garbage degrades to raw", function()
  local p = Report.parse_review("this model ignored the contract entirely")
  H.eq(p.known, false)
  H.eq(p.verdict, nil)
  H.eq(p.raw, "this model ignored the contract entirely")
end)

H.case("format_target: review section carries verdict and flags", function()
  local text = Report.format_target({
    specialist = "scss-reviewer", kind = "review", status = "done",
    verdict = "approve", cached = true,
    scope_files = { "a.scss" }, chain = {}, warnings = {},
    tokens = { input = 1200, output = 300 }, duration_ms = 45000,
  })
  H.has(text, "scss-reviewer (review) -- approve [CACHED REVIEW]")
  H.has(text, "Files: a.scss")
  H.has(text, "1.2k in / 0.3k out")
  H.has(text, "Chain: main")
end)

H.case("format_target: unparsable review surfaces raw text", function()
  local text = Report.format_target({
    specialist = "r", kind = "review", status = "done",
    scope_files = {}, chain = {}, warnings = {}, raw = "no tail at all",
  })
  H.has(text, "unparsed verdict")
  H.has(text, "no tail at all")
end)

H.case("format_aggregate: counts, totals, warning dedup", function()
  local text = Report.format_aggregate({
    { specialist = "a", kind = "review", status = "done", verdict = "approve",
      tokens = { input = 100, output = 50 }, duration_ms = 1000, warnings = { "w1" } },
    { specialist = "b", kind = "review", status = "done", verdict = "request-changes",
      tokens = { input = 200, output = 100 }, duration_ms = 2500, warnings = { "w1", "w2" } },
    { specialist = "c", kind = "task", status = "refused", error = "nope", warnings = {} },
  })
  H.has(text, "3 target(s), 2 completed, 1 not completed")
  H.has(text, "0.3k in / 0.1k out")
  H.has(text, "Warnings (2):")
  H.has(text, "w2")
end)

H.case("format_coverage: table and UNCOVERED suggestions", function()
  local text = Report.format_coverage({
    { path = "a.scss", specialist = "scss-reviewer", verdict = "approve", cached = true },
  }, {
    { path = "src/x.lua", suggestion = { specialist = "lua-code-reviewer", glob = "lua/**/*.lua" } },
  })
  H.has(text, "Review coverage:")
  H.has(text, "a.scss")
  H.has(text, "approve (CACHED)")
  H.has(text, "UNCOVERED")
  H.has(text, "src/x.lua")
  H.has(text, "suggested: lua-code-reviewer")
end)

H.case("format_coverage: empty input is empty", function()
  H.eq(Report.format_coverage(nil, nil), "")
end)
