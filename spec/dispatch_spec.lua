-- SPDX-FileCopyrightText: 2026 Aidan Gauland <aidalgol+git@fastmail.net>
--
-- SPDX-License-Identifier: MIT

-- Dispatch pure surface: input normalization and the policy engine
-- (cycle checks, depth caps, task allowlists, impl chain cap).

local lu = require("luaunit")

local TestDispatch = {}
local Dispatch = require("specialist_subagents.dispatch")

local function ok_policy(target, spec, invoker)
  local kind, err = Dispatch.check_policy(target, spec, invoker)
  return kind ~= nil, err
end

local review_spec = { name = "scss-reviewer", type = "review" }
local impl_spec = { name = "test-engineer", type = "implementation" }

function TestDispatch:test_normalize_input_scalar_form_gets_defaults()
  local targets, err = Dispatch.normalize_input({ specialist = "r", brief = "do it" })
  lu.assertEquals(err, nil)
  lu.assertEquals(#targets, 1)
  lu.assertEquals(targets[1].specialist, "r")
  lu.assertEquals(targets[1].kind, nil, "kind inferred later from the specialist type")
  lu.assertEquals(targets[1].scope.basis, "changed")
  lu.assertEquals(targets[1].scope.files, {})
  lu.assertEquals(targets[1].claims, {})
  lu.assertEquals(targets[1].force_review, false)
end

function TestDispatch:test_normalize_input_targets_list_form()
  local targets = Dispatch.normalize_input({
    targets = {
      { specialist = "a", brief = "x" },
      { specialist = "b", brief = "y", kind = "review", force_review = true,
        scope = { files = { "**/*.lua" }, basis = "plan" }, claims = { "src/**" } },
    },
  })
  lu.assertEquals(#targets, 2)
  lu.assertEquals(targets[2].kind, "review")
  lu.assertEquals(targets[2].scope.basis, "plan")
  lu.assertEquals(targets[2].claims, { "src/**" })
end

function TestDispatch:test_normalize_input_rejects_malformed_input()
  lu.assertEquals(Dispatch.normalize_input({ specialist = "r" }), nil, "brief required")
  lu.assertEquals(Dispatch.normalize_input({ brief = "x" }), nil, "specialist required")
  lu.assertEquals(Dispatch.normalize_input({ targets = {} }), nil, "empty fan-out")
  lu.assertEquals(Dispatch.normalize_input("nope"), nil)
  lu.assertEquals(Dispatch.normalize_input({ targets = { { specialist = "a" } } }), nil)
end

function TestDispatch:test_policy_main_can_dispatch_anything()
  local main = { name = "main", chain = {} }
  lu.assertTrue(ok_policy({ specialist = "scss-reviewer", brief = "b" }, review_spec, main))
  lu.assertTrue(ok_policy({ specialist = "test-engineer", brief = "b" }, impl_spec, main))
end

function TestDispatch:test_policy_cycle_through_the_chain_is_refused()
  local invoker = {
    name = "impl",
    chain = { { name = "test-engineer", kind = "task" } },
  }
  local ok, err = ok_policy({ specialist = "test-engineer", brief = "b" }, impl_spec, invoker)
  lu.assertEquals(ok, false)
  lu.assertStrContains(err, "cycle")
end

function TestDispatch:test_policy_self_delegation_is_refused()
  local ok, err = ok_policy(
    { specialist = "test-engineer", brief = "b" }, impl_spec,
    { name = "test-engineer", chain = {} })
  lu.assertEquals(ok, false)
  lu.assertStrContains(err, "cycle")
end

function TestDispatch:test_policy_review_depth_cap()
  local deep = {
    name = "reviewer",
    chain = { { name = "a", kind = "task" }, { name = "b", kind = "review" } },
  }
  local ok, err = ok_policy({ specialist = "scss-reviewer", brief = "b" }, review_spec, deep)
  lu.assertEquals(ok, false)
  lu.assertStrContains(err, "depth")
  -- depth 2 (one ancestor hop) is allowed
  local mid = { name = "impl", chain = { { name = "a", kind = "task" } } }
  lu.assertTrue(ok_policy({ specialist = "scss-reviewer", brief = "b" }, review_spec, mid))
end

function TestDispatch:test_policy_task_delegation_needs_the_allowlist()
  local invoker = { name = "test-engineer", chain = {} }
  local target = { specialist = "component-implementer", brief = "b" }
  local ok, err = ok_policy(target, impl_spec, invoker)
  lu.assertEquals(ok, false)
  lu.assertStrContains(err, "allowlist")
  local with_allow = { name = "test-engineer", chain = {}, delegate = { tasks = { "component-implementer" } } }
  lu.assertTrue(ok_policy(target, impl_spec, with_allow))
end

function TestDispatch:test_policy_impl_chain_cap_task_delegated_specialists_cannot_task_delegate()
  local nested = {
    name = "impl",
    chain = { { name = "test-engineer", kind = "task" } },
    delegate = { tasks = { "anything" } },
  }
  local ok, err = ok_policy({ specialist = "anything", brief = "b" }, impl_spec, nested)
  lu.assertEquals(ok, false)
  lu.assertStrContains(err, "impl chain cap")
  -- review delegation still works from the same invoker (depth 2)
  lu.assertTrue(ok_policy({ specialist = "scss-reviewer", brief = "b" }, review_spec, nested))
end

function TestDispatch:test_policy_an_implementer_s_own_hop_does_not_block_its_task_delegation()
  -- real shape: the child invoker's chain ends with its own dispatch hop
  local child = {
    name = "test-engineer",
    chain = { { name = "test-engineer", kind = "task" } },
    delegate = { tasks = { "component-implementer" } },
  }
  lu.assertTrue(ok_policy({ specialist = "component-implementer", brief = "b" }, impl_spec, child),
    "impl-depth 0 implementer task-delegates its allowlisted target")
  -- a specialist that was itself delegated by a specialist cannot
  local grandchild = {
    name = "component-implementer",
    chain = {
      { name = "test-engineer", kind = "task" },
      { name = "component-implementer", kind = "task" },
    },
    delegate = { tasks = { "anything" } },
  }
  local ok, err = ok_policy({ specialist = "anything", brief = "b" }, impl_spec, grandchild)
  lu.assertEquals(ok, false)
  lu.assertStrContains(err, "impl chain cap")
end

function TestDispatch:test_policy_kind_defaults_follow_the_specialist_type()
  local main = { name = "main", chain = {} }
  local kind = Dispatch.check_policy({ specialist = "x", brief = "b" }, review_spec, main)
  lu.assertEquals(kind, "review")
  kind = Dispatch.check_policy({ specialist = "x", brief = "b" }, impl_spec, main)
  lu.assertEquals(kind, "task")
  kind = Dispatch.check_policy({ specialist = "x", brief = "b", kind = "review" }, impl_spec, main)
  lu.assertEquals(kind, "review", "explicit kind overrides the type default")
end

-- Regression: the recent-finished handoff lives on the plugin-lifetime
-- State, not on the per-project ledger state (which has no finished table).
-- The wrong-table version crashed every completing review with
-- "attempt to index nil with string" at store_finished.
function TestDispatch:test_finished_handoff_stored_on_state_bounded_at_max_finished()
  Dispatch._store_finished("handoff-regression", { status = "done", verdict = "approve" })
  local fin = Dispatch._state.finished["handoff-regression"]
  lu.assertTrue(fin ~= nil, "handoff stored on State.finished")
  lu.assertEquals(fin.result.verdict, "approve")
  lu.assertEquals(type(fin.at), "number")
  for i = 1, 60 do
    Dispatch._store_finished("bound-" .. i, { status = "done" })
  end
  local n = 0
  for _ in pairs(Dispatch._state.finished) do
    n = n + 1
  end
  lu.assertTrue(n <= 50, "handoff bounded (got " .. n .. ")")
  -- cleanup: leave no bound-* entries for later cases
  for k in pairs(Dispatch._state.finished) do
    Dispatch._state.finished[k] = nil
  end
end

-- Regression: an unparsable review satisfies nothing, the review cache
-- included. combined_verdict defaults to "approve", so a verdict-less
-- cached entry would approve unchanged files without any review running.
function TestDispatch:test_review_cache_verdict_less_ledger_entries_are_cache_misses()
  local Ledger = require("specialist_subagents.ledger")
  local state = Ledger.new_state()
  Ledger.record(state, {
    specialist = "r", path = "a.lua", fingerprint = "fp1",
    verdict = nil, raw = "garbage without a verdict line",
  })
  Ledger.record(state, {
    specialist = "r", path = "b.lua", fingerprint = "fp2",
    verdict = "approve", raw = "SUMMARY: ok\nVERDICT: approve",
  })
  local snap = { files = {
    { path = "a.lua", fingerprint = "fp1" },
    { path = "b.lua", fingerprint = "fp2" },
  } }
  local target = { specialist = "r", kind = "review", scope = { files = {} } }
  local spec = { name = "r" }

  local files, cached = Dispatch._resolve_review_files(state, target, spec, snap, false)
  lu.assertEquals(#files, 2, "both scoped files resolved")
  lu.assertEquals(#cached, 1, "only the verdict-bearing entry is cached")
  for _, f in ipairs(files) do
    if f.path == "a.lua" then
      lu.assertEquals(f.cached, nil, "verdict-less entry is a cache miss")
    else
      lu.assertTrue(f.cached ~= nil, "b.lua carries its cached entry")
      lu.assertEquals(f.cached.verdict, "approve")
    end
  end

  -- positive case: a verdict-bearing entry is served from cache
  Ledger.record(state, {
    specialist = "r", path = "a.lua", fingerprint = "fp1",
    verdict = "request-changes", raw = "SUMMARY: needs work\nVERDICT: request-changes",
  })
  files, cached = Dispatch._resolve_review_files(state, target, spec, snap, false)
  lu.assertEquals(#cached, 2, "both verdict-bearing entries cached")
  for _, f in ipairs(files) do
    lu.assertTrue(f.cached ~= nil)
  end

  -- force_review bypasses even a good cache entry
  files, cached = Dispatch._resolve_review_files(state, target, spec, snap, true)
  lu.assertEquals(#cached, 0, "force_review re-reviews everything")
  for _, f in ipairs(files) do
    lu.assertEquals(f.cached, nil)
  end
end

function TestDispatch:test_normalize_input_files_basis_round_trips_with_files_intact()
  local targets, err = Dispatch.normalize_input({
    specialist = "r", brief = "review the readme", kind = "review",
    scope = { basis = "files", files = { "README.md", "lua/**/*.lua" } },
  })
  lu.assertEquals(err, nil)
  lu.assertEquals(targets[1].scope.basis, "files")
  lu.assertEquals(targets[1].scope.files, { "README.md", "lua/**/*.lua" })
  -- unknown basis still falls back to changed
  targets = Dispatch.normalize_input({
    specialist = "r", brief = "b", scope = { basis = "bogus" },
  })
  lu.assertEquals(targets[1].scope.basis, "changed")
end

function TestDispatch:test_normalize_input_kind_consult_is_accepted()
  local targets, err = Dispatch.normalize_input({
    specialist = "x", brief = "b", kind = "consult",
  })
  lu.assertEquals(err, nil)
  lu.assertEquals(targets[1].kind, "consult")
end

function TestDispatch:test_review_path_in_root_containment_guard_on_normalized_absolute_paths()
  local root = "/tmp/proj"
  lu.assertEquals(Dispatch._review_path_in_root(root, "/tmp/proj/a.lua"), "a.lua")
  lu.assertEquals(Dispatch._review_path_in_root(root, "/tmp/proj/sub/b.lua"), "sub/b.lua")
  lu.assertEquals(Dispatch._review_path_in_root(root, "/tmp/proj/../etc/passwd"), nil,
    "traversal collapses outside the root")
  lu.assertEquals(Dispatch._review_path_in_root(root, "/etc/passwd"), nil, "absolute-outside refused")
  lu.assertEquals(Dispatch._review_path_in_root(root, "/tmp/projx/a.lua"), nil,
    "a sibling directory sharing the prefix is not inside")
  lu.assertEquals(Dispatch._review_path_in_root(root, "-leading-dash"), nil,
    "non-absolute (leading-dash) paths refused")
  lu.assertEquals(Dispatch._review_path_in_root(root, "/tmp/proj"), nil, "the root itself is not a file")
  lu.assertEquals(Dispatch._review_path_in_root(root, nil), nil)
end

function TestDispatch:test_policy_consults_are_main_only_but_run_on_both_specialist_types()
  local main = { name = "main", chain = {} }
  lu.assertEquals(Dispatch.check_policy({ specialist = "x", brief = "b", kind = "consult" }, review_spec, main),
    "consult", "consult a review-type specialist")
  lu.assertEquals(Dispatch.check_policy({ specialist = "x", brief = "b", kind = "consult" }, impl_spec, main),
    "consult", "consult an implementation-type specialist")
  local nested = { name = "impl", chain = { { name = "a", kind = "task" } } }
  local ok, err = ok_policy({ specialist = "x", brief = "b", kind = "consult" }, impl_spec, nested)
  lu.assertEquals(ok, false)
  lu.assertStrContains(err, "main-only")
  -- even a main-chain implementer (impl-depth 0, allowlisted) cannot consult
  local child = {
    name = "test-engineer",
    chain = { { name = "test-engineer", kind = "task" } },
    delegate = { tasks = { "x" } },
  }
  ok, err = ok_policy({ specialist = "x", brief = "b", kind = "consult" }, impl_spec, child)
  lu.assertEquals(ok, false)
  lu.assertStrContains(err, "main-only")
end

return TestDispatch
