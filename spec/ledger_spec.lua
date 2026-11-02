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

return TestLedger
