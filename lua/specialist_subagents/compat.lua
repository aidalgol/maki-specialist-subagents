-- SPDX-FileCopyrightText: 2026 Aidan Gauland <aidalgol+git@fastmail.net>
--
-- SPDX-License-Identifier: MIT

-- Tolerant module loading, shared by every specialist_subagents module.
--
-- Inside maki, sibling modules load by dotted name
-- ("specialist_subagents.config"); under the luau CLI (spec/, `lua
-- spec/run.lua`), require-by-string is file-relative ("./config") and
-- refuses the dotted form. require() tries the dotted name first and falls
-- back to the sibling path verbatim -- never a composition of the two,
-- which can only ever be an unresolvable module name.
--
-- reqfn is injectable so specs can drive both paths without a real host.

local M = {}

function M.require(dotted, sibling, reqfn)
  reqfn = reqfn or require
  local ok, mod = pcall(reqfn, dotted)
  if ok and mod then
    return mod
  end
  return reqfn(sibling)
end

return M
