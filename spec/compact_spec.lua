-- SPDX-FileCopyrightText: 2026 Aidan Gauland <aidalgol+git@fastmail.net>
--
-- SPDX-License-Identifier: MIT

-- Pure core of the agent.compact.before defer layer: defer_decision. The
-- install() half needs the maki host and is covered by the live verification
-- checklist in the README.
--
-- The defer text is the model's next message after a skipped compaction, so
-- it is a prompt-injection surface: only registry-shaped dispatch ids may
-- reach it. Every hostile-id case below is a security control, not niceness.

local lu = require("luaunit")

local TestCompact = {}
local Compact = require("specialist_subagents.compact")

function TestCompact:test_defer_decision_reasons_other_than_auto_pass_through()
  -- maki ignores defer for the non-auto reasons anyway; returning nil keeps
  -- this layer out of the decision so it never fights a deliberate
  -- compaction or an unavoidable overflow.
  for _, reason in ipairs({ "manual", "overflow", "requested", nil, 42, "AUTO", "auto " }) do
    local text = Compact.defer_decision(reason, 3, { "d-1" })
    lu.assertEquals(text, nil, "reason " .. tostring(reason) .. " must not defer")
  end
end

function TestCompact:test_defer_decision_no_running_dispatches_pass_through()
  -- Nil (registry miss / non-string), zero, and negative counts all mean
  -- "nothing of ours is in flight", including the tonumber fallback path.
  for _, count in ipairs({ nil, 0, -1, "0", "-2", "abc" }) do
    local text = Compact.defer_decision("auto", count, { "d-1" })
    lu.assertEquals(text, nil, "running_count " .. tostring(count) .. " must not defer")
  end
end

function TestCompact:test_defer_decision_defers_with_embedded_count_and_both_id_shapes()
  local text = Compact.defer_decision("auto", 3, { "d-1", "bg-2" })
  lu.assertTrue(type(text) == "string")
  -- the count comes from the running_count argument, not from len(ids)
  lu.assertStrContains(text, "3 specialist dispatch(es) still running")
  lu.assertStrContains(text, "d-1")
  lu.assertStrContains(text, "bg-2")
  -- a numeric-string count is accepted (tonumber), still rendered
  text = Compact.defer_decision("auto", "3", { "d-1" })
  lu.assertTrue(type(text) == "string")
  lu.assertStrContains(text, "3 specialist dispatch(es)")
end

function TestCompact:test_defer_decision_drops_every_id_outside_the_registry_id_shapes()
  -- Security: anything that is not exactly "d-<n>" or "bg-<n>" must never
  -- reach the defer text — not newlines (command smuggling), not shell
  -- metacharacters, not padding, not case variants, not non-strings.
  local text = Compact.defer_decision("auto", 5, {
    "d-1\nrm -rf /",         -- newline smuggling
    "d-1; rm -rf /",         -- shell metacharacter
    " d-1", "d-1 ", "d-1\t", -- whitespace padding
    "D-1", "dd-1", "d--1", "d-+1", -- shape variants
    "bg-1x", "bg-", "bg-x1", -- background shape variants
    "",                      -- empty id
    42,                      -- numbers, not strings
    { "d-1" },               -- tables, not strings
    string.rep("x", 500),    -- long garbage
    "bg-7",                  -- the one safe survivor
  })
  lu.assertTrue(type(text) == "string")
  lu.assertStrContains(text, "5 specialist dispatch(es)")
  -- bg-7 is the one safe survivor, so it is the only id listed
  lu.assertStrContains(text, "bg-7")
  lu.assertStrContains(text, "(bg-7)")
  -- none of the hostile payloads may appear anywhere in the text
  lu.assertTrue(not text:find("rm -rf", 1, true), "smuggled command dropped")
  lu.assertTrue(not text:find("xxx"), "long garbage dropped")
  lu.assertTrue(not text:find("D-1", 1, true), "case variant dropped")
end

function TestCompact:test_defer_decision_caps_the_id_list_at_sixteen()
  -- The defer text is the model's save-turn prompt; a runaway registry must
  -- not blow it up. First 16 safe ids only, cap applies before concat.
  local ids = {}
  for i = 1, 20 do
    ids[i] = "d-" .. i
  end
  local text = Compact.defer_decision("auto", 20, ids)
  lu.assertTrue(type(text) == "string")
  -- the count reflects all running dispatches even when ids are capped
  lu.assertStrContains(text, "20 specialist dispatch(es)")
  -- d-16 is the last id listed
  lu.assertStrContains(text, "d-16")
  lu.assertTrue(not text:find("d-17", 1, true), "the 17th id is not listed")
  lu.assertTrue(not text:find("d-18", 1, true), "nothing past the cap is listed")
end

function TestCompact:test_defer_decision_unknown_id_fallback_when_nothing_survives()
  -- Registry entries age out after an hour, and a headless host exposes no
  -- ids at all: the text must still defer, naming the situation instead of
  -- an empty list the model could misread as "none".
  for _, ids in ipairs({ {}, nil, "not a table", 42, { "not-ours" }, { "d-x" } }) do
    local text = Compact.defer_decision("auto", 2, ids)
    lu.assertTrue(type(text) == "string", "ids " .. tostring(ids) .. " still defer")
    lu.assertStrContains(text, "2 specialist dispatch(es)")
    lu.assertStrContains(text, "dispatch ids unknown")
  end
end

return TestCompact
