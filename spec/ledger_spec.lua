-- SPDX-FileCopyrightText: 2026 Aidan Gauland <aidalgol+git@fastmail.net>
--
-- SPDX-License-Identifier: MIT

-- Ledger pure core: cache, LRU, join keys, iteration caps, claim overlap.

local lu = require("luaunit")

local TestLedger = {}
local Ledger = require("specialist_subagents.ledger")

function TestLedger:test_scope_key_order_independent()
  lu.assertEquals(Ledger.scope_key({ "b.lua", "a.lua" }), Ledger.scope_key({ "a.lua", "b.lua" }))
  lu.assertEquals(Ledger.scope_key({}), Ledger.scope_key(nil))
end

function TestLedger:test_join_key_specialist_file_set_and_fingerprint_all_matter()
  local base = Ledger.join_key("r", { "a" }, "fp1")
  lu.assertEquals(base, Ledger.join_key("r", { "a" }, "fp1"))
  lu.assertTrue(base ~= Ledger.join_key("r", { "a" }, "fp2"))
  lu.assertTrue(base ~= Ledger.join_key("other", { "a" }, "fp1"))
  lu.assertTrue(base ~= Ledger.join_key("r", { "a", "b" }, "fp1"))
end

function TestLedger:test_record_and_lookup_fresh_fingerprint_hits_stale_misses()
  local st = Ledger.new_state()
  Ledger.record(st, {
    specialist = "r", path = "a.lua", fingerprint = "fp1",
    verdict = "approve", findings = {}, summary = "ok", ts = 1,
  })
  local hit = Ledger.lookup(st, "r", "a.lua", "fp1")
  lu.assertTrue(hit ~= nil)
  lu.assertEquals(hit.verdict, "approve")
  lu.assertEquals(Ledger.lookup(st, "r", "a.lua", "fp2"), nil)
  lu.assertEquals(Ledger.lookup(st, "other", "a.lua", "fp1"), nil)
end

function TestLedger:test_record_unparsable_reviews_store_verbatim_and_satisfy_nothing()
  local st = Ledger.new_state()
  Ledger.record(st, {
    specialist = "r", path = "a.lua", fingerprint = "fp",
    verdict = nil, raw = "unparsable tail", ts = 1,
  })
  local hit = Ledger.lookup(st, "r", "a.lua", "fp")
  lu.assertTrue(hit ~= nil)
  lu.assertEquals(hit.verdict, nil)
  lu.assertEquals(hit.raw, "unparsable tail")
end

function TestLedger:test_lru_cap_evicts_the_oldest_entries()
  local st = Ledger.new_state()
  st.cap = 3
  for i = 1, 4 do
    Ledger.record(st, {
      specialist = "r", path = "p" .. i, fingerprint = "fp",
      verdict = "approve", ts = i,
    })
  end
  lu.assertEquals(Ledger.lookup(st, "r", "p1", "fp"), nil, "oldest evicted")
  lu.assertTrue(Ledger.lookup(st, "r", "p4", "fp") ~= nil)
  lu.assertTrue(#st.order <= 3)
end

function TestLedger:test_lookup_bumps_recency()
  local st = Ledger.new_state()
  st.cap = 2
  for i = 1, 2 do
    Ledger.record(st, {
      specialist = "r", path = "p" .. i, fingerprint = "fp", verdict = "approve", ts = i,
    })
  end
  Ledger.lookup(st, "r", "p1", "fp") -- p1 becomes newest
  Ledger.record(st, { specialist = "r", path = "p3", fingerprint = "fp", verdict = "approve", ts = 9 })
  lu.assertTrue(Ledger.lookup(st, "r", "p1", "fp") ~= nil, "recently used p1 survives")
  lu.assertEquals(Ledger.lookup(st, "r", "p2", "fp"), nil, "p2 was oldest and evicted")
end

function TestLedger:test_in_flight_registry_put_get_pop()
  local st = Ledger.new_state()
  lu.assertEquals(Ledger.in_flight_get(st, "k"), nil)
  Ledger.in_flight_put(st, "k", { specialist = "r" })
  lu.assertEquals(Ledger.in_flight_get(st, "k").specialist, "r")
  local rec = Ledger.in_flight_pop(st, "k")
  lu.assertEquals(rec.specialist, "r")
  lu.assertEquals(Ledger.in_flight_get(st, "k"), nil)
end

function TestLedger:test_iteration_counting_with_ttl()
  local it = {}
  local key = Ledger.iteration_key("main", "reviewer", { "a.lua" })
  lu.assertEquals(Ledger.count_iterations(it, key, 100, 3600), 0)
  Ledger.bump_iterations(it, key, 100)
  Ledger.bump_iterations(it, key, 101)
  lu.assertEquals(Ledger.count_iterations(it, key, 101, 3600), 2)
  lu.assertEquals(Ledger.count_iterations(it, Ledger.iteration_key("impl", "reviewer", { "a.lua" }), 101, 3600), 0,
    "other implementers count separately")
  lu.assertEquals(Ledger.count_iterations(it, key, 101 + 3601, 3600), 0, "expired entries reset")
end

function TestLedger:test_iteration_key_is_scope_sensitive()
  local a = Ledger.iteration_key("main", "r", { "a.lua" })
  local b = Ledger.iteration_key("main", "r", { "b.lua" })
  lu.assertTrue(a ~= b)
end

function TestLedger:test_claims_overlap_prefixes_and_suffixes()
  lu.assertTrue(Ledger.claims_overlap("src/*.lua", "src/**"), "prefix subset overlaps")
  lu.assertTrue(Ledger.claims_overlap("docs/**", "docs/guide.md"), "glob overlaps literal inside it")
  lu.assertTrue(Ledger.claims_overlap("a.md", "a.md"), "identical literals overlap")
  lu.assertTrue(Ledger.claims_overlap("**/*.scss", "styles/x.scss"))
  lu.assertEquals(Ledger.claims_overlap("src/*.lua", "src/*.rs"), false, "differing suffixes do not overlap")
  lu.assertEquals(Ledger.claims_overlap("src/*.lua", "lib/*.lua"), false, "differing prefixes do not overlap")
end

function TestLedger:test_find_claim_conflicts_names_the_owner()
  local active = {
    { owner = "test-engineer", claims = { "spec/**" } },
    { owner = "other", claims = { "README.md" } },
  }
  local conflicts = Ledger.find_claim_conflicts(active, { "spec/new_test.lua", "lua/x.lua" })
  lu.assertEquals(#conflicts, 1)
  lu.assertStrContains(conflicts[1], "spec/**")
  lu.assertStrContains(conflicts[1], "test-engineer")
  lu.assertEquals(#Ledger.find_claim_conflicts(active, { "lua/x.lua" }), 0)
end

return TestLedger
