-- SPDX-FileCopyrightText: 2026 Aidan Gauland <aidalgol+git@fastmail.net>
--
-- SPDX-License-Identifier: MIT

-- Ledger pure core: cache, LRU, join keys, iteration caps, claim overlap.

local lu = require("luaunit")

local TestLedger = {}
local Ledger = require("specialist_subagents.ledger")

-- ---------------------------------------------------------------------------
-- maki stub for the load_state seam
--
-- The persistence layer talks to the global `maki` at call time, so the tests
-- below set _G.maki to a minimal stub and clear it afterwards. The JSON
-- decoder emulates maki 0.7.0 semantics: JSON null decodes to a truthy
-- sentinel (maki.NIL) unless the caller passes
-- { luanil = { object = true, array = true } }.
-- ---------------------------------------------------------------------------

local NIL_SENTINEL = setmetatable({}, { __tostring = function() return "maki.NIL" end })
local JSON_NULL = setmetatable({}, { __tostring = function() return "<json null>" end })

local function stub_json_decode(text, opts)
  local luanil = (opts and opts.luanil) or {}
  local pos = 1

  local function fail(what)
    error(string.format("stub_json_decode: %s at byte %d", what, pos), 0)
  end

  local function skip_ws()
    local s = text:find("[^ \t\r\n]", pos)
    pos = s or (#text + 1)
  end

  local parse_value

  local function parse_string()
    pos = pos + 1 -- opening quote
    local out = {}
    while true do
      local c = text:sub(pos, pos)
      if c == "" then
        fail("unterminated string")
      elseif c == '"' then
        pos = pos + 1
        return table.concat(out)
      elseif c == "\\" then
        out[#out + 1] = text:sub(pos + 1, pos + 1)
        pos = pos + 2
      else
        out[#out + 1] = c
        pos = pos + 1
      end
    end
  end

  -- JSON null -> nil when the matching luanil flag is set, maki.NIL otherwise.
  -- Each flag applies to its own context, and a top-level null is always the
  -- sentinel (real maki only honours the flags for members/elements).
  local function coerce(v, ctx)
    if v ~= JSON_NULL then
      return v
    end
    if ctx and luanil[ctx] then
      return nil
    end
    return NIL_SENTINEL
  end

  local function parse_object()
    pos = pos + 1 -- {
    local obj = {}
    skip_ws()
    if text:sub(pos, pos) == "}" then
      pos = pos + 1
      return obj
    end
    while true do
      skip_ws()
      if text:sub(pos, pos) ~= '"' then
        fail("expected object key")
      end
      local key = parse_string()
      skip_ws()
      if text:sub(pos, pos) ~= ":" then
        fail("expected ':'")
      end
      pos = pos + 1
      local v = coerce(parse_value(), "object")
      if v ~= nil then
        obj[key] = v
      end -- luanil.object: null keys stay absent
      skip_ws()
      local c = text:sub(pos, pos)
      if c == "," then
        pos = pos + 1
      elseif c == "}" then
        pos = pos + 1
        return obj
      else
        fail("expected ',' or '}'")
      end
    end
  end

  local function parse_array()
    pos = pos + 1 -- [
    local arr = {}
    skip_ws()
    if text:sub(pos, pos) == "]" then
      pos = pos + 1
      return arr
    end
    while true do
      local v = coerce(parse_value(), "array")
      if v ~= nil then
        arr[#arr + 1] = v
      end -- luanil.array: null elements leave a hole
      skip_ws()
      local c = text:sub(pos, pos)
      if c == "," then
        pos = pos + 1
      elseif c == "]" then
        pos = pos + 1
        return arr
      else
        fail("expected ',' or ']'")
      end
    end
  end

  parse_value = function()
    skip_ws()
    if text:sub(pos, pos) == "{" then
      return parse_object()
    end
    if text:sub(pos, pos) == "[" then
      return parse_array()
    end
    if text:sub(pos, pos) == '"' then
      return parse_string()
    end
    if text:sub(pos, pos + 3) == "null" then
      pos = pos + 4
      return JSON_NULL
    end
    if text:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    end
    if text:sub(pos, pos + 4) == "false" then
      pos = pos + 5
      return false
    end
    local num = text:match("^%-?%d+%.?%d*[eE]?[+-]?%d*", pos)
    if num and num ~= "" then
      pos = pos + #num
      return tonumber(num)
    end
    fail("unexpected character")
  end

  local v = parse_value()
  skip_ws()
  if pos <= #text then
    fail("trailing garbage")
  end
  return v
end

local function stub_maki(text)
  return {
    env = { state_dir = function() return "/fake/state" end },
    fs = {
      joinpath = function(...) return table.concat({ ... }, "/") end,
      read = function() return text end,
    },
    json = { decode = stub_json_decode },
  }
end

-- Minimal encoder for the persist-side round trip: enough for the flat
-- ledger entry tables persist() writes (nil fields are skipped, matching
-- how maki.json.encode drops absent keys).
local function stub_json_encode(v)
  if type(v) == "string" then
    return '"' .. v:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
  end
  if type(v) == "number" or type(v) == "boolean" then
    return tostring(v)
  end
  if type(v) == "table" then
    local parts = {}
    if #v > 0 then
      for _, item in ipairs(v) do
        parts[#parts + 1] = stub_json_encode(item)
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
      if v[k] ~= nil then
        parts[#parts + 1] = stub_json_encode(k) .. ":" .. stub_json_encode(v[k])
      end
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end

local LEDGER_WITH_NULLS = [[
{
  "version": 1,
  "entries": [
    {
      "specialist": "lua-code-reviewer",
      "path": "a.lua",
      "fingerprint": "fp1",
      "verdict": null,
      "summary": null,
      "findings": ["hole", null],
      "ts": 7
    }
  ]
}
]]

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
  local ctx = Ledger.context_key({ { path = "a.lua", fingerprint = "fp1" } })
  Ledger.record(st, {
    specialist = "r", path = "a.lua", fingerprint = "fp1", context = ctx,
    verdict = "approve", findings = {}, summary = "ok", ts = 1,
  })
  local hit = Ledger.lookup(st, "r", "a.lua", "fp1", ctx)
  lu.assertTrue(hit ~= nil)
  lu.assertEquals(hit.verdict, "approve")
  lu.assertEquals(Ledger.lookup(st, "r", "a.lua", "fp2", ctx), nil)
  lu.assertEquals(Ledger.lookup(st, "other", "a.lua", "fp1", ctx), nil)
  lu.assertEquals(Ledger.lookup(st, "r", "a.lua", "fp1", "different-context"), nil,
    "a context mismatch is a miss")
  lu.assertEquals(Ledger.lookup(st, "r", "a.lua", "fp1", nil), nil,
    "a context-less (legacy-mode) lookup never hits")
end

function TestLedger:test_record_unparsable_reviews_store_verbatim_and_satisfy_nothing()
  local st = Ledger.new_state()
  local ctx = Ledger.context_key({ { path = "a.lua", fingerprint = "fp" } })
  Ledger.record(st, {
    specialist = "r", path = "a.lua", fingerprint = "fp", context = ctx,
    verdict = nil, raw = "unparsable tail", ts = 1,
  })
  local hit = Ledger.lookup(st, "r", "a.lua", "fp", ctx)
  lu.assertTrue(hit ~= nil)
  lu.assertEquals(hit.verdict, nil)
  lu.assertEquals(hit.raw, "unparsable tail")
end

function TestLedger:test_lru_cap_evicts_the_oldest_entries()
  local st = Ledger.new_state()
  st.cap = 3
  local ctx = "ctx"
  for i = 1, 4 do
    Ledger.record(st, {
      specialist = "r", path = "p" .. i, fingerprint = "fp", context = ctx,
      verdict = "approve", ts = i,
    })
  end
  lu.assertEquals(Ledger.lookup(st, "r", "p1", "fp", ctx), nil, "oldest evicted")
  lu.assertTrue(Ledger.lookup(st, "r", "p4", "fp", ctx) ~= nil)
  lu.assertTrue(#st.order <= 3)
end

function TestLedger:test_lookup_bumps_recency()
  local st = Ledger.new_state()
  st.cap = 2
  local ctx = "ctx"
  for i = 1, 2 do
    Ledger.record(st, {
      specialist = "r", path = "p" .. i, fingerprint = "fp", context = ctx,
      verdict = "approve", ts = i,
    })
  end
  Ledger.lookup(st, "r", "p1", "fp", ctx) -- p1 becomes newest
  Ledger.record(st, {
    specialist = "r", path = "p3", fingerprint = "fp", context = ctx,
    verdict = "approve", ts = 9,
  })
  lu.assertTrue(Ledger.lookup(st, "r", "p1", "fp", ctx) ~= nil, "recently used p1 survives")
  lu.assertEquals(Ledger.lookup(st, "r", "p2", "fp", ctx), nil, "p2 was oldest and evicted")
end

-- context_key: order-independent over the row list, sensitive to any path
-- or fingerprint change, and total on nil/empty input (empty-scope reviews
-- are refused upstream, but the pure core must stay total).
function TestLedger:test_context_key_order_independent_and_scope_sensitive()
  local ab = {
    { path = "a.lua", fingerprint = "fp1" },
    { path = "b.lua", fingerprint = "fp2" },
  }
  local ba = {
    { path = "b.lua", fingerprint = "fp2" },
    { path = "a.lua", fingerprint = "fp1" },
  }
  lu.assertEquals(Ledger.context_key(ab), Ledger.context_key(ba), "row order does not matter")
  lu.assertEquals(Ledger.context_key(nil), Ledger.context_key({}), "nil and empty are both total")
  lu.assertTrue(Ledger.context_key(ab) ~= Ledger.context_key({
    { path = "a.lua", fingerprint = "fp1" }, { path = "b.lua", fingerprint = "changed" },
  }), "a sibling fingerprint change changes the context")
  lu.assertTrue(Ledger.context_key(ab) ~= Ledger.context_key({
    { path = "a.lua", fingerprint = "fp1" }, { path = "c.lua", fingerprint = "fp2" },
  }), "a path change changes the context")
  lu.assertTrue(Ledger.context_key(ab) ~= Ledger.context_key({
    { path = "a.lua", fingerprint = "fp1" },
  }), "removing a scope member changes the context")
end

-- A hit requires the file's own fingerprint AND the review context: a
-- sibling change (with the file unchanged) and the file's own change both
-- miss, even though the entry itself is intact.
function TestLedger:test_lookup_requires_context_and_fingerprint_match()
  local st = Ledger.new_state()
  local ctx = Ledger.context_key({
    { path = "a.lua", fingerprint = "fa" },
    { path = "b.lua", fingerprint = "fb" },
  })
  Ledger.record(st, {
    specialist = "r", path = "a.lua", fingerprint = "fa", context = ctx,
    verdict = "approve", ts = 1,
  })
  lu.assertTrue(Ledger.lookup(st, "r", "a.lua", "fa", ctx) ~= nil, "context match hits")
  lu.assertEquals(Ledger.lookup(st, "r", "a.lua", "fa", Ledger.context_key({
    { path = "a.lua", fingerprint = "fa" }, { path = "b.lua", fingerprint = "fb2" },
  })), nil, "a sibling change invalidates the sibling verdict")
  lu.assertEquals(Ledger.lookup(st, "r", "a.lua", "fa-changed", Ledger.context_key({
    { path = "a.lua", fingerprint = "fa-changed" }, { path = "b.lua", fingerprint = "fb" },
  })), nil, "the file's own fingerprint change misses")
  lu.assertEquals(Ledger.lookup(st, "r", "a.lua", "fa", ""), nil,
    "an empty-string context lookup misses even with the matching fingerprint: "
    .. "entry_key coerces a missing context to \"\", so \"\" must not collide "
    .. "with any recorded context")
end

-- Legacy rows (context == nil, e.g. persisted before the context-keyed
-- schema, or loaded from a ledger file with no context field) never satisfy
-- a context-bearing lookup and never raise: the cache cold-starts once
-- across the schema change.
function TestLedger:test_legacy_entries_never_hit_context_lookups()
  local st = Ledger.new_state()
  Ledger.record(st, {
    specialist = "r", path = "a.lua", fingerprint = "fp1",
    verdict = "approve", ts = 1,
  }) -- no context: legacy row
  local ctx = Ledger.context_key({ { path = "a.lua", fingerprint = "fp1" } })
  lu.assertEquals(Ledger.lookup(st, "r", "a.lua", "fp1", ctx), nil,
    "a legacy row never satisfies a context-bearing lookup")
  lu.assertEquals(Ledger.lookup(st, "r", "a.lua", "fp1", nil), nil,
    "a context-less lookup never hits")
  lu.assertEquals(Ledger.lookup(st, "r", "a.lua", "fp1", ""), nil,
    "an empty-string lookup never hits a legacy row: the legacy key collapses "
    .. "to context \"\", but a \"\"-context lookup is refused outright")

  -- the same holds for legacy rows loaded from a persisted ledger file
  _G.maki = stub_maki(LEDGER_WITH_NULLS)
  local ok, lstate = pcall(Ledger.load_state, "/proj")
  _G.maki = nil
  lu.assertTrue(ok)
  lu.assertEquals(
    Ledger.lookup(lstate, "lua-code-reviewer", "a.lua", "fp1", ctx), nil,
    "a persisted legacy row loads but never hits a context lookup")
end

-- The context field survives persistence: a context-bearing row written by
-- persist() and reloaded through load_state still hits its lookup. The stub
-- captures the real atomic_write payload, so the write-side serialization is
-- exercised, not just the load side.
function TestLedger:test_context_round_trips_through_persistence()
  local ctx = Ledger.context_key({ { path = "a.lua", fingerprint = "fp1" } })
  local st = Ledger.new_state()
  Ledger.record(st, {
    specialist = "r", path = "a.lua", fingerprint = "fp1", context = ctx,
    verdict = "approve", ts = 7,
  })
  local written = nil
  _G.maki = {
    env = { state_dir = function() return "/fake/state" end },
    log = { debug = function() end },
    fs = {
      joinpath = function(...) return table.concat({ ... }, "/") end,
      normalize = function(p) return p end,
      mkdir = function() end,
      atomic_write = function(_, payload)
        written = payload
        return true
      end,
      read = function() return written end,
    },
    json = { decode = stub_json_decode, encode = stub_json_encode },
  }
  local ok_p, perr = Ledger.persist(st, "/proj")
  lu.assertTrue(ok_p, "persist succeeds: " .. tostring(perr))
  lu.assertTrue(written ~= nil, "atomic_write captured a payload")
  lu.assertStrContains(written, ctx, "the payload carries the context field")

  local ok_l, state = pcall(Ledger.load_state, "/proj")
  _G.maki = nil
  lu.assertTrue(ok_l)
  local hit = Ledger.lookup(state, "r", "a.lua", "fp1", ctx)
  lu.assertTrue(hit ~= nil, "a reloaded context-bearing row hits its lookup")
  lu.assertEquals(hit.verdict, "approve")
  lu.assertEquals(hit.context, ctx)
end

-- Two review contexts coexist for the same (specialist, path): each hits
-- with its own context, neither hits with the other's, and LRU eviction
-- spans the combined keyspace (a context-A slot and its context-B sibling
-- are separate entries).
function TestLedger:test_two_contexts_coexist_per_specialist_path()
  local st = Ledger.new_state()
  st.cap = 3
  local ctx_a, ctx_b = "ctx-a", "ctx-b"
  Ledger.record(st, {
    specialist = "r", path = "p1", fingerprint = "fp", context = ctx_a,
    verdict = "approve", ts = 1,
  })
  Ledger.record(st, {
    specialist = "r", path = "p1", fingerprint = "fp", context = ctx_b,
    verdict = "approve", ts = 2,
  })
  lu.assertTrue(Ledger.lookup(st, "r", "p1", "fp", ctx_a) ~= nil, "the context-A entry hits")
  lu.assertTrue(Ledger.lookup(st, "r", "p1", "fp", ctx_b) ~= nil,
    "the context-B entry coexists instead of overwriting it")
  -- each lookup bumped its own LRU slot; filling the cap evicts only the
  -- context-A slot, proving the two contexts occupy separate slots
  Ledger.record(st, {
    specialist = "r", path = "p2", fingerprint = "fp", context = ctx_a,
    verdict = "approve", ts = 3,
  })
  Ledger.record(st, {
    specialist = "r", path = "p3", fingerprint = "fp", context = ctx_a,
    verdict = "approve", ts = 4,
  })
  lu.assertEquals(Ledger.lookup(st, "r", "p1", "fp", ctx_a), nil,
    "the (no longer recent) context-A slot was evicted")
  lu.assertTrue(Ledger.lookup(st, "r", "p1", "fp", ctx_b) ~= nil,
    "the recently used context-B slot survives the same eviction")
end

-- Soundness of full-cache-hit replay: entries recorded under context A
-- and context B must never combine into a cache hit for a third context C,
-- even when every file fingerprint matches. No single review saw C's
-- combination of file contents, so no lookup under C may hit.
function TestLedger:test_full_cache_hit_never_combines_verdicts_across_contexts()
  local st = Ledger.new_state()
  local r_a = { path = "a.lua", fingerprint = "fa" }
  local r_b = { path = "b.lua", fingerprint = "fb" }
  Ledger.record(st, {
    specialist = "r", path = "a.lua", fingerprint = "fa", context = Ledger.context_key({ r_a }),
    verdict = "approve", ts = 1,
  })
  Ledger.record(st, {
    specialist = "r", path = "b.lua", fingerprint = "fb", context = Ledger.context_key({ r_b }),
    verdict = "approve", ts = 1,
  })
  local ctx_c = Ledger.context_key({ r_a, r_b })
  lu.assertEquals(Ledger.lookup(st, "r", "a.lua", "fa", ctx_c), nil,
    "a lookup under a context no single review saw must miss")
  lu.assertEquals(Ledger.lookup(st, "r", "b.lua", "fb", ctx_c), nil,
    "the sibling file misses under the combined context too")
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

function TestLedger:test_stub_json_decode_emulates_maki_070_null_semantics()
  local d = stub_json_decode('{"a":null,"b":[1,null]}')
  lu.assertTrue(d.a ~= nil, "0.7.0 default: JSON null is a truthy sentinel")
  lu.assertTrue(d.b[2] ~= nil, "0.7.0 default: null array element is a truthy sentinel")

  local d2 = stub_json_decode('{"a":null,"b":[1,null]}', { luanil = { object = true, array = true } })
  lu.assertNil(d2.a, "luanil.object: null fields decode to nil")
  lu.assertNil(d2.b[2], "luanil.array: null elements decode to nil")
  lu.assertEquals(d2.b[1], 1)

  local d3 = stub_json_decode('{"a":null,"b":[1,null]}', { luanil = { object = true } })
  lu.assertNil(d3.a, "flags are per-context: object null is nil")
  lu.assertTrue(d3.b[2] ~= nil, "flags are per-context: array null is still the sentinel")

  local top = stub_json_decode("null", { luanil = { object = true, array = true } })
  lu.assertTrue(top ~= nil, "top-level null is always the sentinel")
end

function TestLedger:test_load_state_decodes_persisted_nulls_to_nil()
  _G.maki = stub_maki(LEDGER_WITH_NULLS)
  local ok, state = pcall(Ledger.load_state, "/proj")
  _G.maki = nil
  lu.assertTrue(ok)

  local hit = state.entries[Ledger.entry_key("lua-code-reviewer", "a.lua", "fp1")]
  lu.assertTrue(hit ~= nil, "entry with null verdict still loads")
  lu.assertNil(hit.verdict, "null verdict must be nil, not maki.NIL")
  lu.assertNil(hit.summary, "null summary must be nil, not maki.NIL")
  lu.assertNil(hit.findings[2], "null findings element must be nil, not maki.NIL")
  lu.assertEquals(hit.findings[1], "hole")
  lu.assertEquals(hit.ts, 7)
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

-- Regression: the same-dispatch self-overlap exemption. The optional third
-- parameter, a skip predicate, must drop exactly the rows it accepts -- here
-- the same-dispatch impl row -- while rows of other owners and other
-- dispatch ids still conflict. The untagged legacy row runs against the
-- predicate too (nil dispatch_id) without raising; its claims do not
-- overlap, so it yields no conflict either way.
function TestLedger:test_find_claim_conflicts_skip_predicate_honors_row()
  local active = {
    { owner = "impl", dispatch_id = 7, claims = { "src/**" } },
    { owner = "other", dispatch_id = 7, claims = { "src/**" } },
    { owner = "impl", dispatch_id = 9, claims = { "src/**" } },
    { owner = "impl", claims = { "docs/**" } }, -- untagged legacy row
  }
  local skip = function(row)
    return row.owner == "impl" and row.dispatch_id == 7
  end
  local conflicts = Ledger.find_claim_conflicts(active, { "src/x.lua" }, skip)
  lu.assertEquals(#conflicts, 2, "the skipped impl/7 row dropped, the rest survive")
  local impl_named = 0
  for _, c in ipairs(conflicts) do
    if string.find(c, "already claimed by impl", 1, true) then
      impl_named = impl_named + 1
    end
  end
  lu.assertEquals(impl_named, 1,
    "the same-owner rows were dropped by the predicate, not by dedup")
end

-- The skip parameter is optional: a nil skip must behave exactly like the
-- two-argument call (backward compatibility for every pre-existing caller).
function TestLedger:test_find_claim_conflicts_nil_skip_is_backward_compatible()
  local active = {
    { owner = "test-engineer", claims = { "spec/**" } },
    { owner = "other", claims = { "README.md" } },
  }
  local claims = { "spec/new_test.lua", "lua/x.lua" }
  local two_arg = Ledger.find_claim_conflicts(active, claims)
  local nil_skip = Ledger.find_claim_conflicts(active, claims, nil)

  lu.assertEquals(#nil_skip, #two_arg, "same length as the two-argument call")
  for i, c in ipairs(two_arg) do
    lu.assertEquals(nil_skip[i], c, "element " .. i .. " matches")
  end
end

return TestLedger
