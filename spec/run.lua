-- Runs the whole suite with LuaUnit. Requires Lua 5.x:
--
--   $ lua spec/run.lua
--
-- luau CLI's require-by-string refuses the `lua/specialist_subagents.lua`
-- entry file + `lua/specialist_subagents/` package dir combination (ambiguous
-- component), so the suite runs on plain Lua.

package.path = "./spec/?.lua;./lua/?.lua;./external/luaunit/?.lua;" .. package.path

local luaunit = require("luaunit")

luaunit.setVerbosity(luaunit.VERBOSITY_VERBOSE)
local runner = luaunit.LuaUnit.new()
runner:runSuiteByInstances({
  { "TestConfig", require("config_spec") },
  { "TestDispatch", require("dispatch_spec") },
  { "TestGit", require("git_spec") },
  { "TestLedger", require("ledger_spec") },
  { "TestPermissions", require("permissions_spec") },
  { "TestReport", require("report_spec") },
  { "TestSessionBuilder", require("session_builder_spec") },
  { "TestSpec", require("spec_spec") },
})
os.exit(runner.result.notSuccessCount == 0 and 0 or 1)
