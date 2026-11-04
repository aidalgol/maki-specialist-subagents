-- SPDX-FileCopyrightText: 2026 Aidan Gauland <aidalgol+git@fastmail.net>
--
-- SPDX-License-Identifier: MIT

-- Verdict/finding parsing and caller-facing report text.
--
-- Pure Lua: no maki global, loadable and testable outside the host.
-- Parsing is lenient on formatting (markdown bold, whitespace, case) and
-- strict on tokens: only `approve` and `request-changes` are stored as
-- gate-satisfying verdicts; anything else keeps the raw text and satisfies
-- nothing.

local M = {}

local KNOWN_VERDICTS = {
  approve = "approve",
  approved = "approve",
  ["request-changes"] = "request-changes",
  ["request changes"] = "request-changes",
  ["changes-requested"] = "request-changes",
  ["changes requested"] = "request-changes",
}

local function strip_markdown(s)
  s = s:gsub("[%*_`#]+", "")
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_blank(line)
  return line:match("^%s*$") ~= nil
end

-- True when the line opens the next report section and therefore ends the
-- current one: "VERDICT: ..." / "SUMMARY: ..." / "FINDINGS: ..." (markdown
-- bold allowed anywhere), the same words as headings where the colon is
-- optional ("### Verdict"), and any other ATX heading.
local function section_marker(line)
  if line:match("^%s*#+") then
    return true
  end
  if line:lower():find("verdict%s*:", 1, false)
    or line:lower():find("summary%s*:", 1, false)
    or line:lower():find("findings%s*:", 1, false) then
    return true
  end
  return line:match("^%s*#*%s*%**[Vv][Ee][Rr][Dd][Ii][Cc][Tt]%**%s*:?%s*$") ~= nil
    or line:match("^%s*#*%s*%**[Ff][Ii][Nn][Dd][Ii][Nn][Gg][Ss]%**%s*:?%s*$") ~= nil
    or line:match("^%s*#*%s*%**[Ss][Uu][Mm][Mm][Aa][Rr][Yy]%**%s*:?%s*$") ~= nil
end

-- The findings-block opener. Returns any item text found on the opener line
-- after the colon (possibly ""), or nil when the line is not an opener.
local function findings_header(line)
  return line:match("^%s*%**[Ff][Ii][Nn][Dd][Ii][Nn][Gg][Ss]%**%s*:%s*(.-)%s*$")
end

-- Heading-shaped opener ("### Findings", "**FINDINGS**"): the colon is
-- optional when the word is the entire heading.
local function findings_heading(line)
  if line:match("^%s*#*%s*%**[Ff][Ii][Nn][Dd][Ii][Nn][Gg][Ss]%**%s*:?%s*$") then
    return ""
  end
  return nil
end

-- One finding-shaped line: explicitly numbered ("1. x", "1) x", "- 2. x"),
-- a bullet ("- x", "* x", "+ x"), or bold-anchored ("**file:line** — text").
-- Returns the recorded number (explicit numbering only, else nil) and the
-- raw body, or nil, nil when the line is not finding-shaped.
local function finding_parts(line)
  local num, body = line:match("^%s*%-?%s*(%d+)[%.%)%s]+%s*(.+)$")
  if num then
    return tonumber(num), body
  end
  -- bold-anchored: "**file:line** — text" (optionally bullet-marked); the
  -- anchor stays: like a numbered item, the whole line is the finding, only
  -- markdown markers are stripped downstream
  if line:match("^%s*[-*+]?%s*%*%*[^%*]+%*%*%s*%S") then
    return nil, line
  end
  local bullet = line:match("^%s*[-*+]%s+(.-)%s*$")
  if bullet then
    return nil, bullet
  end
  return nil, nil
end

function M.parse_verdict(text)
  if type(text) ~= "string" then
    return nil
  end
  local verdict
  for line in text:gmatch("[^\r\n]+") do
    local value = line:match("^%s*%**[Vv][Ee][Rr][Dd][Ii][Cc][Tt]%**%s*:%s*(.-)%s*$")
    if value == nil then
      -- also match when the line has leading markdown or prose
      value = line:match("V%s*E%s*R%s*D%s*I%s*C%s*T%s*%*?%s*:%s*(%S+.-)%s*$")
    end
    if value then
      local token = strip_markdown(value):gsub("%.$", ""):gsub("%s+", " "):lower()
      if KNOWN_VERDICTS[token] then
        verdict = KNOWN_VERDICTS[token]
      else
        -- an explicit but unknown token is unparsable, not absent
        verdict = nil
        local first = token:match("^(%S+)")
        if first and KNOWN_VERDICTS[first] then
          verdict = KNOWN_VERDICTS[first]
        end
      end
    end
  end
  return verdict
end

function M.parse_summary(text)
  if type(text) ~= "string" then
    return nil
  end
  local lines = {}
  for line in text:gmatch("[^\r\n]+") do
    lines[#lines + 1] = line
  end
  for i, line in ipairs(lines) do
    local inline = line:match("%**[Ss][Uu][Mm][Mm][Aa][Rr][Yy]%**%s*:%s*(.-)%s*$")
    if inline then
      inline = strip_markdown(inline)
      if inline ~= "" then
        return inline
      end
      -- summary continues on following lines until the next section
      local buf = {}
      for j = i + 1, #lines do
        local nxt = lines[j]
        if is_blank(nxt) or section_marker(nxt) then
          break
        end
        buf[#buf + 1] = strip_markdown(nxt)
      end
      if #buf > 0 then
        return table.concat(buf, " ")
      end
    elseif line:match("^%s*#*%s*%**[Ss][Uu][Mm][Mm][Aa][Rr][Yy]%**%s*:?%s*$") then
      -- heading-form summary ("### Summary"); the text below it runs until
      -- the next section opener and never swallows it
      local buf = {}
      for j = i + 1, #lines do
        local nxt = lines[j]
        if is_blank(nxt) or section_marker(nxt) then
          break
        end
        buf[#buf + 1] = strip_markdown(nxt)
      end
      if #buf > 0 then
        return table.concat(buf, " ")
      end
    end
  end
  return nil
end

function M.parse_findings(text)
  local findings = {}
  if type(text) ~= "string" then
    return findings
  end
  local lines = {}
  for line in text:gmatch("[^\r\n]+") do
    lines[#lines + 1] = line
  end
  local in_block = false
  local at_blank = false
  local n = 0
  for _, line in ipairs(lines) do
    local rest = findings_header(line) or findings_heading(line)
    if rest then
      in_block = true
      at_blank = false
      -- a finding may share the opener line: "FINDINGS: 1. something"
      local num, body = finding_parts(strip_markdown(rest))
      if body then
        n = n + 1
        findings[#findings + 1] = { n = num or n, text = strip_markdown(body) }
      end
    elseif in_block then
      if is_blank(line) then
        -- soft separator: the block may resume if the next non-blank line is
        -- still finding-shaped, otherwise it closes
        at_blank = true
      else
        local num, body = finding_parts(line)
        if body then
          -- a finding that quotes a section word ("1. must end with
          -- VERDICT:") matches the item shapes first and must not close the
          -- block
          n = n + 1
          findings[#findings + 1] = { n = num or n, text = strip_markdown(body) }
          at_blank = false
        elseif section_marker(line) then
          in_block = false
        elseif at_blank then
          -- a non-blank line after a blank that is neither finding-shaped
          -- nor a marker closes the block
          in_block = false
        end
        -- without a preceding blank the block stays open: a prose line
        -- directly after a finding does not close it
      end
    end
  end
  return findings
end

-- Parse a review report. Unparsable tails degrade to raw text; this never
-- raises on model output.
function M.parse_review(text)
  local parsed = {
    verdict = M.parse_verdict(text),
    findings = M.parse_findings(text),
    summary = M.parse_summary(text),
    raw = text,
  }
  parsed.known = parsed.verdict ~= nil
  return parsed
end

-- ---------------------------------------------------------------------------
-- Report formatting
-- ---------------------------------------------------------------------------

local function fmt_tokens(r)
  if not r.tokens then
    return nil
  end
  local parts = {}
  if r.tokens.input then
    parts[#parts + 1] = string.format("%.1fk in", r.tokens.input / 1000)
  end
  if r.tokens.output then
    parts[#parts + 1] = string.format("%.1fk out", r.tokens.output / 1000)
  end
  if #parts == 0 then
    return nil
  end
  return table.concat(parts, " / ")
end

local function fmt_duration(ms)
  if not ms then
    return nil
  end
  if ms < 1000 then
    return string.format("%dms", ms)
  end
  return string.format("%.1fs", ms / 1000)
end

local function fmt_chain(chain)
  if not chain or #chain == 0 then
    return "main"
  end
  local names = { "main" }
  for _, hop in ipairs(chain) do
    names[#names + 1] = hop.name .. "(" .. (hop.kind or "?") .. ")"
  end
  return table.concat(names, " -> ")
end

local function target_flags(r)
  local flags = {}
  if r.cached then
    flags[#flags + 1] = "CACHED REVIEW"
  end
  if r.joined then
    flags[#flags + 1] = "JOINED IN-FLIGHT SESSION"
  end
  if r.forced then
    flags[#flags + 1] = "FORCED RE-RUN"
  end
  if #flags == 0 then
    return ""
  end
  return " [" .. table.concat(flags, ", ") .. "]"
end

local function target_header(r)
  local head = string.format("== %s (%s)", r.specialist, r.kind or "?")
  local state = r.status
  if r.status == "done" and r.kind == "review" then
    state = r.verdict or "unparsed verdict"
  end
  return string.format("%s -- %s%s", head, state, target_flags(r))
end

-- One target's caller-facing section.
function M.format_target(r)
  local out = { target_header(r) }
  if r.error then
    out[#out + 1] = "Error: " .. r.error
  end
  if r.scope_files and #r.scope_files > 0 then
    out[#out + 1] = "Files: " .. table.concat(r.scope_files, ", ")
  end
  if r.claims and #r.claims > 0 then
    out[#out + 1] = "Claims: " .. table.concat(r.claims, ", ")
  end
  if r.summary then
    out[#out + 1] = "Summary: " .. r.summary
  end
  if r.findings and #r.findings > 0 then
    out[#out + 1] = "Findings:"
    for _, f in ipairs(r.findings) do
      out[#out + 1] = string.format(" %d. %s", f.n, f.text)
    end
  elseif r.kind == "review" and r.status == "done"
    and (not r.verdict
      or (not r.summary and not next(r.findings or {}))) then
    out[#out + 1] = "Note: report tail was unparsable or only partially parsed; raw review text follows."
    out[#out + 1] = (r.raw or ""):gsub("%s+$", "")
  end
  out[#out + 1] = "Chain: " .. fmt_chain(r.chain)
  local cost_bits = {}
  local tk = fmt_tokens(r)
  if tk then
    cost_bits[#cost_bits + 1] = tk
  end
  local dur = fmt_duration(r.duration_ms)
  if dur then
    cost_bits[#cost_bits + 1] = dur
  end
  if #cost_bits > 0 then
    out[#out + 1] = "Cost: " .. table.concat(cost_bits, ", ")
  end
  for _, w in ipairs(r.warnings or {}) do
    out[#out + 1] = "Warning: " .. w
  end
  return table.concat(out, "\n")
end

-- Aggregated report over a fan-out. `results` is the ordered per-target list.
function M.format_aggregate(results)
  local ok_count, fail_count, cached_count = 0, 0, 0
  local tot_in, tot_out, tot_ms = 0, 0, 0
  local warnings = {}
  local seen_warnings = {}
  for _, r in ipairs(results) do
    if r.status == "done" then
      ok_count = ok_count + 1
      if r.cached or r.joined then
        cached_count = cached_count + 1
      end
      if r.tokens then
        tot_in = tot_in + (r.tokens.input or 0)
        tot_out = tot_out + (r.tokens.output or 0)
      end
      tot_ms = tot_ms + (r.duration_ms or 0)
    elseif r.status == "refused" or r.status == "failed" or r.status == "cancelled" then
      fail_count = fail_count + 1
    end
    for _, w in ipairs(r.warnings or {}) do
      if not seen_warnings[w] then
        seen_warnings[w] = true
        warnings[#warnings + 1] = w
      end
    end
  end
  local head = string.format("Specialist delegation: %d target(s), %d completed, %d not completed",
    #results, ok_count, fail_count)
  if cached_count > 0 then
    head = head .. string.format(", %d served from cache/join", cached_count)
  end
  local tot = fmt_tokens({ tokens = { input = tot_in, output = tot_out } })
  if tot then
    head = head .. " | total " .. tot .. ", " .. fmt_duration(tot_ms)
  end
  local out = { head, "" }
  for i, r in ipairs(results) do
    if i > 1 then
      out[#out + 1] = ""
    end
    out[#out + 1] = M.format_target(r)
  end
  if #warnings > 0 then
    out[#out + 1] = ""
    out[#out + 1] = "Warnings (" .. #warnings .. "):"
    for _, w in ipairs(warnings) do
      out[#out + 1] = " - " .. w
    end
  end
  return table.concat(out, "\n")
end

-- Review coverage audit: computed coverage table plus UNCOVERED list.
-- `coverage` is an ordered list of rows. A row either carries `reviewers`
-- (the per-path list of { specialist, verdict, cached } entries collected by
-- the coverage audit, newest first) or the legacy singular fields
-- { path, specialist, verdict, cached }.
-- `uncovered` is a list of { path, suggestion }.
function M.format_coverage(coverage, uncovered)
  local out = {}
  if coverage and #coverage > 0 then
    out[#out + 1] = "Review coverage:"
    for _, c in ipairs(coverage) do
      local specialists, verdicts = {}, {}
      if c.reviewers then
        for _, e in ipairs(c.reviewers) do
          specialists[#specialists + 1] = e.specialist or "-"
          local v = e.verdict or "unparsed"
          if e.cached then
            v = v .. " (CACHED)"
          end
          verdicts[#verdicts + 1] = v
        end
      else
        specialists[1] = c.specialist or "-"
        -- no reviewer for this path at all, not a review that failed to
        -- parse: match reviews_lookup's wording
        local v = c.verdict or "UNREVIEWED"
        if c.cached then
          v = v .. " (CACHED)"
        end
        verdicts[1] = v
      end
      out[#out + 1] = string.format(" %-46s %-24s %s",
        c.path, table.concat(specialists, ", "), table.concat(verdicts, ", "))
    end
  end
  if uncovered and #uncovered > 0 then
    out[#out + 1] = "UNCOVERED (changed files no dispatched scope covered):"
    for _, u in ipairs(uncovered) do
      local line = " " .. u.path
      if u.suggestion then
        line = line .. string.format("  [suggested: %s matches %s]", u.suggestion.specialist, u.suggestion.glob)
      end
      out[#out + 1] = line
    end
  end
  return table.concat(out, "\n")
end
-- Background dispatch receipt: returned by the tool call immediately, while
-- the fan-out runs in a spawned task. `refused` lists targets rejected by
-- the synchronous validation pass (they never opened a session).
function M.format_receipt(dispatch_id, targets, refused)
  local names = {}
  for _, t in ipairs(targets) do
    names[#names + 1] = tostring(t.specialist) .. "(" .. tostring(t.kind or "?") .. ")"
  end
  local out = {
    string.format("Background dispatch %s started: %d specialist(s): %s.",
      dispatch_id, #targets, table.concat(names, ", ")),
    "Results arrive as a message when the dispatch completes; do not re-dispatch "
      .. "(the review ledger dedups and joins identical reviews anyway).",
    "delegate { action = \"status\", dispatch = \"" .. dispatch_id .. "\" } checks progress; "
      .. "action = \"message\" / \"stop\" reach the running specialists.",
  }
  for _, r in ipairs(refused or {}) do
    out[#out + 1] = "Refused at validation: " .. r.specialist .. " -- " .. tostring(r.error)
  end
  return table.concat(out, "\n")
end

-- `action = "status"` over running dispatches (oldest first).
function M.format_status(entries, now_t)
  if not entries or #entries == 0 then
    return "No running specialist dispatches."
  end
  local out = { string.format("Running specialist dispatches: %d", #entries) }
  for _, e in ipairs(entries) do
    local elapsed = now_t and e.started_at and math.max(0, now_t - e.started_at) or nil
    local head = string.format(" %s (%s%s", e.id, e.background and "background, " or "",
      elapsed and (elapsed .. "s") or "elapsed ?")
    local parts = {}
    for _, t in ipairs(e.targets) do
      parts[#parts + 1] = string.format("%s(%s) %s", t.specialist, t.kind or "?", t.status or "?")
    end
    out[#out + 1] = head .. "): " .. table.concat(parts, ", ")
  end
  return table.concat(out, "\n")
end

-- `action = "message" | "stop"` result: per-specialist outcome rows.
-- A row: { dispatch, specialist, kind, ok, detail }.
function M.format_action_result(action, rows)
  local verb = action == "message" and "Message" or "Stop"
  local ok_n, fail_n = 0, 0
  local out = {}
  for _, r in ipairs(rows or {}) do
    if r.ok then
      ok_n = ok_n + 1
    else
      fail_n = fail_n + 1
    end
    out[#out + 1] = string.format(" - %s %s(%s): %s",
      r.dispatch, r.specialist, r.kind or "?", r.ok and tostring(r.detail)
        or "refused (" .. tostring(r.detail) .. ")")
  end
  local head = string.format("%s result: %d delivered, %d not delivered", verb, ok_n, fail_n)
  if #out == 0 then
    return head .. " (no matched specialist sessions)"
  end
  return head .. "\n" .. table.concat(out, "\n")
end

return M
