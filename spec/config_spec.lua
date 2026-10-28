-- Configuration knobs ship with documented defaults.

local H = require("helpers")
local Config = require("specialist_subagents.config")

H.case("defaults", function()
  H.eq(Config.max_active, 6)
  H.eq(Config.per_turn_budget, 16)
  H.eq(Config.review_max_depth, 2)
  H.eq(Config.impl_chain_max, 1)
  H.eq(Config.iteration_cap, 3)
  H.eq(Config.strict_claims, false)
  H.eq(Config.ledger_cap, 500)
end)

H.case("setup merges known keys of matching types and ignores the rest", function()
  Config.setup({ max_active = 2, strict_claims = true, bogus = 1, per_turn_budget = "many" })
  H.eq(Config.max_active, 2)
  H.eq(Config.strict_claims, true)
  H.eq(Config.per_turn_budget, 16, "wrong-typed values ignored")
  H.eq(Config.review_max_depth, 2)
  -- restore
  Config.setup({ max_active = 6, strict_claims = false })
end)
