-- The review report tail is a machine contract: Report.parse_verdict /
-- parse_summary / parse_findings key on these exact markers, and an
-- unparsable tail satisfies no review gate. These cases pin the preamble's
-- instruction so the wording cannot drift away from the parser.

local H = require("helpers")
local SB = require("specialist_subagents.session_builder")

local function review_preamble()
  return SB.preamble({ name = "x", type = "review" }, "review", { chain = {}, depth = 0 })
end

H.case("review preamble: states the machine-readable tail the parser keys on", function()
  local p = review_preamble()
  H.truthy(p:find("VERDICT: approve", 1, true) ~= nil, "bare approve token shown")
  H.truthy(p:find("VERDICT: request-changes", 1, true) ~= nil, "bare request-changes token shown")
  H.truthy(p:find("bare token on its own last line", 1, true) ~= nil,
    "bare-token rule stated")
  H.truthy(p:find("SUMMARY:", 1, true) ~= nil, "SUMMARY marker instructed")
  H.truthy(p:find("FINDINGS:", 1, true) ~= nil, "FINDINGS marker instructed")
  H.truthy(p:find("satisfies no review gate", 1, true) ~= nil,
    "unparsable-tail consequence stated")
end)

H.case("task preamble: carries no verdict instruction", function()
  local p = SB.preamble({ name = "x", type = "implementation" }, "task", { chain = {}, depth = 0 })
  H.eq(p:find("VERDICT", 1, true), nil)
  H.eq(p:find("FINDINGS:", 1, true), nil)
end)
