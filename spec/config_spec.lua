-- SPDX-FileCopyrightText: 2026 Aidan Gauland <aidalgol+git@fastmail.net>
--
-- SPDX-License-Identifier: MIT

-- Configuration knobs ship with documented defaults.

local lu = require("luaunit")

local TestConfig = {}
local Config = require("specialist_subagents.config")

function TestConfig:test_defaults()
  lu.assertEquals(Config.max_active, 6)
  lu.assertEquals(Config.per_turn_budget, 16)
  lu.assertEquals(Config.review_max_depth, 2)
  lu.assertEquals(Config.impl_chain_max, 1)
  lu.assertEquals(Config.iteration_cap, 3)
  lu.assertEquals(Config.strict_claims, false)
  lu.assertEquals(Config.ledger_cap, 500)
  lu.assertEquals(Config.permission_relay, true)
end

function TestConfig:test_setup_merges_known_keys_of_matching_types_and_ignores_the_rest()
  Config.setup({ max_active = 2, strict_claims = true, bogus = 1, per_turn_budget = "many" })
  lu.assertEquals(Config.max_active, 2)
  lu.assertEquals(Config.strict_claims, true)
  lu.assertEquals(Config.per_turn_budget, 16, "wrong-typed values ignored")
  lu.assertEquals(Config.review_max_depth, 2)
  -- restore
  Config.setup({ max_active = 6, strict_claims = false })
end

return TestConfig
