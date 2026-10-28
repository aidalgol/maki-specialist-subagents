-- Ledger pure core: cache, LRU, join keys, iteration caps, claim overlap.

local H = require("helpers")
local Ledger = require("specialist_subagents.ledger")

H.case("scope_key: order-independent", function()
  H.eq(Ledger.scope_key({ "b.lua", "a.lua" }), Ledger.scope_key({ "a.lua", "b.lua" }))
  H.eq(Ledger.scope_key({}), Ledger.scope_key(nil))
end)

H.case("join_key: specialist, file-set, and fingerprint all matter", function()
  local base = Ledger.join_key("r", { "a" }, "fp1")
  H.eq(base, Ledger.join_key("r", { "a" }, "fp1"))
  H.truthy(base ~= Ledger.join_key("r", { "a" }, "fp2"))
  H.truthy(base ~= Ledger.join_key("other", { "a" }, "fp1"))
  H.truthy(base ~= Ledger.join_key("r", { "a", "b" }, "fp1"))
end)

H.case("record and lookup: fresh fingerprint hits, stale misses", function()
  local st = Ledger.new_state()
  Ledger.record(st, {
    specialist = "r", path = "a.lua", fingerprint = "fp1",
    verdict = "approve", findings = {}, summary = "ok", ts = 1,
  })
  local hit = Ledger.lookup(st, "r", "a.lua", "fp1")
  H.truthy(hit)
  H.eq(hit.verdict, "approve")
  H.eq(Ledger.lookup(st, "r", "a.lua", "fp2"), nil)
  H.eq(Ledger.lookup(st, "other", "a.lua", "fp1"), nil)
end)

H.case("record: unparsable reviews store verbatim and satisfy nothing", function()
  local st = Ledger.new_state()
  Ledger.record(st, {
    specialist = "r", path = "a.lua", fingerprint = "fp",
    verdict = nil, raw = "unparsable tail", ts = 1,
  })
  local hit = Ledger.lookup(st, "r", "a.lua", "fp")
  H.truthy(hit)
  H.eq(hit.verdict, nil)
  H.eq(hit.raw, "unparsable tail")
end)

H.case("LRU cap evicts the oldest entries", function()
  local st = Ledger.new_state()
  st.cap = 3
  for i = 1, 4 do
    Ledger.record(st, {
      specialist = "r", path = "p" .. i, fingerprint = "fp",
      verdict = "approve", ts = i,
    })
  end
  H.eq(Ledger.lookup(st, "r", "p1", "fp"), nil, "oldest evicted")
  H.truthy(Ledger.lookup(st, "r", "p4", "fp"))
  H.truthy(#st.order <= 3)
end)

H.case("lookup bumps recency", function()
  local st = Ledger.new_state()
  st.cap = 2
  for i = 1, 2 do
    Ledger.record(st, {
      specialist = "r", path = "p" .. i, fingerprint = "fp", verdict = "approve", ts = i,
    })
  end
  Ledger.lookup(st, "r", "p1", "fp") -- p1 becomes newest
  Ledger.record(st, { specialist = "r", path = "p3", fingerprint = "fp", verdict = "approve", ts = 9 })
  H.truthy(Ledger.lookup(st, "r", "p1", "fp"), "recently used p1 survives")
  H.eq(Ledger.lookup(st, "r", "p2", "fp"), nil, "p2 was oldest and evicted")
end)

H.case("in-flight registry put/get/pop", function()
  local st = Ledger.new_state()
  H.eq(Ledger.in_flight_get(st, "k"), nil)
  Ledger.in_flight_put(st, "k", { specialist = "r" })
  H.eq(Ledger.in_flight_get(st, "k").specialist, "r")
  local rec = Ledger.in_flight_pop(st, "k")
  H.eq(rec.specialist, "r")
  H.eq(Ledger.in_flight_get(st, "k"), nil)
end)

H.case("iteration counting with TTL", function()
  local it = {}
  local key = Ledger.iteration_key("main", "reviewer", { "a.lua" })
  H.eq(Ledger.count_iterations(it, key, 100, 3600), 0)
  Ledger.bump_iterations(it, key, 100)
  Ledger.bump_iterations(it, key, 101)
  H.eq(Ledger.count_iterations(it, key, 101, 3600), 2)
  H.eq(Ledger.count_iterations(it, Ledger.iteration_key("impl", "reviewer", { "a.lua" }), 101, 3600), 0,
    "other implementers count separately")
  H.eq(Ledger.count_iterations(it, key, 101 + 3601, 3600), 0, "expired entries reset")
end)

H.case("iteration key is scope-sensitive", function()
  local a = Ledger.iteration_key("main", "r", { "a.lua" })
  local b = Ledger.iteration_key("main", "r", { "b.lua" })
  H.truthy(a ~= b)
end)

H.case("claims_overlap: prefixes and suffixes", function()
  H.truthy(Ledger.claims_overlap("src/*.lua", "src/**"), "prefix subset overlaps")
  H.truthy(Ledger.claims_overlap("docs/**", "docs/guide.md"), "glob overlaps literal inside it")
  H.truthy(Ledger.claims_overlap("a.md", "a.md"), "identical literals overlap")
  H.truthy(Ledger.claims_overlap("**/*.scss", "styles/x.scss"))
  H.eq(Ledger.claims_overlap("src/*.lua", "src/*.rs"), false, "differing suffixes do not overlap")
  H.eq(Ledger.claims_overlap("src/*.lua", "lib/*.lua"), false, "differing prefixes do not overlap")
end)

H.case("find_claim_conflicts names the owner", function()
  local active = {
    { owner = "test-engineer", claims = { "spec/**" } },
    { owner = "other", claims = { "README.md" } },
  }
  local conflicts = Ledger.find_claim_conflicts(active, { "spec/new_test.lua", "lua/x.lua" })
  H.eq(#conflicts, 1)
  H.has(conflicts[1], "spec/**")
  H.has(conflicts[1], "test-engineer")
  H.eq(#Ledger.find_claim_conflicts(active, { "lua/x.lua" }), 0)
end)
