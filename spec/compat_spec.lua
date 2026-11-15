-- SPDX-FileCopyrightText: 2026 Aidan Gauland <aidalgol+git@fastmail.net>
--
-- SPDX-License-Identifier: MIT

-- Regression: the tolerant-require fallback must use the sibling path
-- verbatim (the old inline version composed the dotted name into an
-- unresolvable path). reqfn is injectable, so both branches are pinned
-- without picking a host.

local lu = require("luaunit")

local TestCompat = {}
local Compat = require("specialist_subagents.compat")

function TestCompat:test_sibling_fallback_uses_the_sibling_name_verbatim()
  local calls = {}
  local sentinel = { marker = "fallback-module" }
  local function reqfn(name)
    calls[#calls + 1] = name
    if name == "specialist_subagents.config" then
      error("luau CLI refuses dotted requires") -- simulates the real failure
    end
    return sentinel
  end
  local mod = Compat.require("specialist_subagents.config", "./config", reqfn)
  lu.assertEquals(#calls, 2, "the failed dotted attempt falls through to the sibling")
  lu.assertEquals(calls[1], "specialist_subagents.config")
  lu.assertEquals(calls[2], "./config", "the sibling name reaches reqfn verbatim")
  lu.assertEquals(mod, sentinel)
end

function TestCompat:test_dotted_success_never_touches_fallback()
  local calls = 0
  local sentinel = { marker = "dotted-module" }
  local function reqfn(name)
    if name ~= "specialist_subagents.compat" then
      error("unexpected require: " .. tostring(name))
    end
    calls = calls + 1
    return sentinel
  end
  local mod = Compat.require("specialist_subagents.compat", "./compat", reqfn)
  lu.assertEquals(mod, sentinel)
  lu.assertEquals(calls, 1, "the fallback path is never reached on dotted success")
end

return TestCompat
