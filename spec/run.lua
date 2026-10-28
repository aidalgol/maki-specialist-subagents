-- Runs the whole suite. Requires Lua 5.x (or the maki host's Luau with a
-- module loader that resolves dotted names):
--
--   cd <repo root> && lua spec/run.lua
--
-- luau CLI's require-by-string refuses the `lua/specialist_subagents.lua`
-- entry file + `lua/specialist_subagents/` package dir combination (ambiguous
-- component), so the suite runs on plain Lua or inside maki instead.

package.path = "./spec/?.lua;./lua/?.lua;" .. package.path

local H = require("helpers")

require("report_spec")
require("spec_spec")
require("ledger_spec")
require("git_spec")
require("dispatch_spec")
require("config_spec")

H.report()
