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
      -- summary continues on following lines until a blank line or marker
      local buf = {}
      for j = i + 1, #lines do
        local nxt = lines[j]
        if nxt:match("^%s*$")
          or nxt:lower():find("verdict%s*:", 1, false)
          or nxt:lower():find("findings%s*:", 1, false) then
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
  local n = 0
  for _, line in ipairs(lines) do
    local header = line:match("^%s*%**[Ff][Ii][Nn][Dd][Ii][Nn][Gg][Ss]%**%s*:%s*(.-)%s*$")
    if header then
      in_block = true
      -- a finding may share the header line: "FINDINGS: 1. something"
      local num, body = header:match("^(%d+)[%.%)%s]+%s*(.+)$")
      if num then
        n = n + 1
        findings[#findings + 1] = { n = tonumber(num) or n, text = strip_markdown(body) }
      end
    elseif in_block then
      if line:match("^%s*$") then
        in_block = false
      else
        local num, body = line:match("^%s*%-?%s*(%d+)[%.%)%s]+%s*(.+)$")
        if num then
          n = n + 1
          findings[#findings + 1] = { n = tonumber(num) or n, text = strip_markdown(body) }
        elseif line:lower():find("verdict%s*:", 1, false)
          or line:lower():find("summary%s*:", 1, false) then
          in_block = false
        end
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
  elseif r.kind == "review" and r.status == "done" and not r.verdict then
    out[#out + 1] = "Note: report tail was unparsable; raw review text follows."
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
-- `coverage` is an ordered list of { path, specialist, verdict, cached };
-- `uncovered` is a list of { path, suggestion }.
function M.format_coverage(coverage, uncovered)
  local out = {}
  if coverage and #coverage > 0 then
    out[#out + 1] = "Review coverage:"
    for _, c in ipairs(coverage) do
      local verdict = c.verdict or "unparsed"
      if c.cached then
        verdict = verdict .. " (CACHED)"
      end
      out[#out + 1] = string.format(" %-46s %-24s %s", c.path, c.specialist or "-", verdict)
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

return M
