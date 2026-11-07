-- SPDX-FileCopyrightText: 2026 Aidan Gauland <aidalgol+git@fastmail.net>
--
-- SPDX-License-Identifier: MIT

-- /specialists command view: catalog, live invocations, recent coverage.

local M = {}

local function fmt_age(secs)
  if not secs then
    return "?"
  end
  if secs < 60 then
    return secs .. "s"
  elseif secs < 3600 then
    return string.format("%.0fm", secs / 60)
  end
  return string.format("%.1fh", secs / 3600)
end

function M.render(buf, cwd, dispatch_state)
  local Registry = require("specialist_subagents.registry")
  local catalog, warnings, errors = Registry.catalog(cwd)

  buf:line({ { "Specialists", { bold = true } } })
  buf:line({ { string.format("project: %s", cwd), { dim = true } } })
  buf:line("")

  local names = {}
  for name in pairs(catalog) do
    names[#names + 1] = name
  end
  table.sort(names)
  if #names == 0 then
    buf:line({ { "No specialists found.", { bold = true } } })
    buf:line({ { string.format("looked in %s and ~/.config/maki", cwd .. "/.maki"), { dim = true } } })
  end
  for _, name in ipairs(names) do
    local s = catalog[name]
    local bits = { { s.name, { bold = true } }, { " (" .. s.type .. ") ", { dim = true } }, { s.description, { dim = true } } }
    if s.source then
      bits[#bits + 1] = { "  [" .. s.source.root .. "]", { dim = true } }
    end
    buf:line(bits)
    local extra = {}
    if s.review.files and #s.review.files > 0 then
      extra[#extra + 1] = "files: " .. table.concat(s.review.files, ", ")
    end
    if s.delegate then
      local d = {}
      if s.delegate.reviews then
        d[#d + 1] = "reviews"
      end
      if #d > 0 then
        extra[#extra + 1] = "delegates: " .. table.concat(d, " ")
      end
    end
    if s.skills and #s.skills > 0 then
      extra[#extra + 1] = "skills: " .. table.concat(s.skills, ", ")
    end
    if #extra > 0 then
      buf:line({ { "    " .. table.concat(extra, " | "), { dim = true } } })
    end
  end

  -- live invocations
  buf:line("")
  buf:line({ { "Live invocations", { bold = true } } })
  local st = (dispatch_state and dispatch_state._state) or {}
  local live = 0
  for _ in pairs(st.in_flight or {}) do
    live = live + 1
  end
  if live == 0 then
    buf:line({ { "  none", { dim = true } } })
  else
    for key, rec in pairs(st.in_flight or {}) do
      buf:line({ { string.format("  %s since %ds", tostring(rec.specialist or key), os.time() - (rec.started_at or os.time())), { dim = true } } })
    end
    buf:line({ { string.format("  active sessions: %d", st.active or 0), { dim = true } } })
  end

  -- recent review coverage from the ledger
  buf:line("")
  buf:line({ { "Recent review coverage", { bold = true } } })
  local ledger = st.ledgers and st.ledgers[cwd]
  if not ledger or #ledger.order == 0 then
    buf:line({ { "  no reviews recorded yet", { dim = true } } })
  else
    local rows = {}
    for i = #ledger.order, math.max(1, #ledger.order - 11), -1 do
      local e = ledger.entries[ledger.order[i]]
      if e then
        rows[#rows + 1] = string.format("  %-44s %-22s %-16s %s ago",
          e.path, e.specialist, e.verdict or "unparsed", fmt_age(e.ts and os.time() - e.ts))
      end
    end
    for _, row in ipairs(rows) do
      buf:line(row)
    end
  end

  if errors and #errors > 0 then
    buf:line("")
    buf:line({ { "Definition errors", { bold = true } } })
    for _, e in ipairs(errors) do
      buf:line({ { "  " .. e, { dim = true } } })
    end
  end

  if warnings and #warnings > 0 then
    buf:line("")
    buf:line({ { "Discovery warnings", { bold = true } } })
    for _, w in ipairs(warnings) do
      buf:line({ { "  " .. w, { dim = true } } })
    end
  end
end

function M.win_opts()
  return {
    title = "/specialists",
    width = "72%",
    height = "80%",
    border = "rounded",
    footer = { { "q", "close" } },
    keys = { "q", "<Esc>" },
    -- Claimed `keys` are only valid on unfocused windows: a focused window
    -- already receives every key, so open_win refuses `keys` without this.
    focus = false,
  }
end

function M.show()
  local cwd = maki.uv.cwd()
  local Dispatch = require("specialist_subagents.dispatch")
  local buf = maki.ui.buf()
  local ok, err = pcall(M.render, buf, cwd, Dispatch)
  if not ok then
    buf:line({ { "failed to render: " .. tostring(err), { bold = true } } })
  end
  local ok_win, win = pcall(maki.ui.open_win, buf, M.win_opts())
  if not ok_win then
    maki.log.error("specialist-subagents: /specialists failed to open its window: " .. tostring(win))
    return
  end
  if win then
    maki.async.spawn(function()
      while true do
        local ev = win:recv()
        if not ev then
          break
        end
        if ev.type == "key" and (ev.key == "q" or ev.key == "<Esc>") then
          win:close()
          break
        end
      end
    end)
  end
end

return M
