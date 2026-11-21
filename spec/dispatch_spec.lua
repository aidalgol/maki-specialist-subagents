-- SPDX-FileCopyrightText: 2026 Aidan Gauland <aidalgol+git@fastmail.net>
--
-- SPDX-License-Identifier: MIT

-- Dispatch pure surface: input normalization and the policy engine
-- (cycle checks, review depth cap, main-only task/consult dispatches).

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

function TestDispatch:test_policy_nested_task_dispatch_is_refused_main_only()
  -- Nested (non-main) invokers can no longer task-dispatch, allowlisted or
  -- not: kind = "task" dispatches are main-only.
  local invoker = { name = "test-engineer", chain = {} }
  local target = { specialist = "component-implementer", brief = "b" }
  local ok, err = ok_policy(target, impl_spec, invoker)
  lu.assertEquals(ok, false)
  lu.assertStrContains(err, "main-only")
  lu.assertStrContains(err, "task dispatches are main-only")
end

function TestDispatch:test_policy_nested_review_dispatch_still_passes_without_a_delegate_field()
  -- The same invoker shape can still dispatch a review-type specialist;
  -- the invoker carries no delegate field (nested delegation is review-only).
  local invoker = { name = "test-engineer", chain = {} }
  lu.assertTrue(ok_policy({ specialist = "scss-reviewer", brief = "b" }, review_spec, invoker))
  -- A nested implementer (itself task-delegated) can still request a review
  local nested = {
    name = "impl",
    chain = { { name = "test-engineer", kind = "task" } },
  }
  lu.assertTrue(ok_policy({ specialist = "scss-reviewer", brief = "b" }, review_spec, nested))
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

function TestDispatch:test_policy_nested_kind_review_relabel_of_implementation_specialist_is_refused()
  -- A nested invoker cannot re-open nested task dispatch by dressing an
  -- implementation specialist up as kind = "review".
  local invoker = { name = "test-engineer", chain = {} }
  local ok, err = ok_policy(
    { specialist = "component-implementer", brief = "b", kind = "review" },
    impl_spec, invoker)
  lu.assertEquals(ok, false)
  lu.assertStrContains(err, "review-type specialists")
end

function TestDispatch:test_policy_review_type_specialist_refuses_non_review_kind()
  -- Review-type specialists are leaves: only kind = "review" dispatches are
  -- valid for them, even from main.
  local main = { name = "main", chain = {} }
  local ok, err = ok_policy(
    { specialist = "scss-reviewer", brief = "b", kind = "task" }, review_spec, main)
  lu.assertEquals(ok, false)
  lu.assertStrContains(err, 'only kind = "review"')
end

function TestDispatch:test_policy_main_explicit_review_kind_on_implementation_specialist_still_passes()
  -- Main invoking an implementation specialist in review mode is legitimate
  -- (the kind default test pins the returned kind; this pins acceptance).
  local main = { name = "main", chain = {} }
  lu.assertTrue(ok_policy(
    { specialist = "component-implementer", brief = "b", kind = "review" },
    impl_spec, main))
end

function TestDispatch:test_policy_nested_review_kind_on_review_type_specialist_still_passes()
  -- The nested review-only rule must not swallow legitimate nested reviews
  -- that name their kind explicitly.
  local invoker = {
    name = "impl",
    chain = { { name = "test-engineer", kind = "task" } },
  }
  lu.assertTrue(ok_policy(
    { specialist = "scss-reviewer", brief = "b", kind = "review" },
    review_spec, invoker))
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
  -- the review context the pipeline looks entries up under
  local snap = { files = {
    { path = "a.lua", fingerprint = "fp1" },
    { path = "b.lua", fingerprint = "fp2" },
  } }
  local ctx = Ledger.context_key(snap.files)
  Ledger.record(state, {
    specialist = "r", path = "a.lua", fingerprint = "fp1", context = ctx,
    verdict = nil, raw = "garbage without a verdict line",
  })
  Ledger.record(state, {
    specialist = "r", path = "b.lua", fingerprint = "fp2", context = ctx,
    verdict = "approve", raw = "SUMMARY: ok\nVERDICT: approve",
  })
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
    specialist = "r", path = "a.lua", fingerprint = "fp1", context = ctx,
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
  -- even a main-chain implementer cannot consult
  local child = {
    name = "test-engineer",
    chain = { { name = "test-engineer", kind = "task" } },
  }
  ok, err = ok_policy({ specialist = "x", brief = "b", kind = "consult" }, impl_spec, child)
  lu.assertEquals(ok, false)
  lu.assertStrContains(err, "main-only")
end

-- ---------------------------------------------------------------------------
-- Cached-findings and coverage regressions (plan: comic-positive-buck)
-- ---------------------------------------------------------------------------

-- A partial cache hit must not replay cached findings: findings are
-- changeset-level free text stored on every per-file ledger entry, so a
-- cached finding's subject may be the one file that changed. The warning
-- and the cached verdicts' coverage contribution must survive.
function TestDispatch:test_partial_cache_hit_suppresses_cached_findings_but_keeps_warning_and_coverage()
  local Ledger = require("specialist_subagents.ledger")
  local state = Ledger.new_state()
  local snap = { files = {
    { path = "a.lua", fingerprint = "fp-new" }, -- changed since the review
    { path = "b.lua", fingerprint = "fp-b" },
  } }
  -- the a.lua entry was reviewed under the OLD scope context (before a.lua
  -- changed); the b.lua entry under the current one
  local old_ctx = Ledger.context_key({
    { path = "a.lua", fingerprint = "fp-old" },
    { path = "b.lua", fingerprint = "fp-b" },
  })
  local ctx = Ledger.context_key(snap.files)
  Ledger.record(state, {
    specialist = "r", path = "a.lua", fingerprint = "fp-old", context = old_ctx,
    verdict = "request-changes",
    findings = { { text = "stale finding on a.lua" } },
    ts = 100,
  })
  Ledger.record(state, {
    specialist = "r", path = "b.lua", fingerprint = "fp-b", context = ctx,
    verdict = "approve", findings = {}, ts = 100,
  })
  local target = { specialist = "r", kind = "review", scope = { files = {} } }
  local spec = { name = "r" }

  local files, cached = Dispatch._resolve_review_files(state, target, spec, snap, false)
  lu.assertEquals(#cached, 1, "the changed file cache-misses")
  lu.assertEquals(files[1].cached, nil)
  lu.assertEquals(files[1].path, "a.lua")

  local result = { warnings = {} }
  Dispatch._apply_partial_cache(result, files, cached)
  lu.assertEquals(result.findings, nil, "cached findings are not replayed on a partial hit")
  lu.assertEquals(#result.warnings, 1)
  lu.assertStrContains(result.warnings[1], "1 of 2 file(s) returned cached verdicts")
  lu.assertStrContains(result.warnings[1], "approve")

  -- the cached verdict still contributes coverage for the unchanged file
  _G.maki = {
    fs = {
      glob = function() return {} end,
      normalize = function(p) return p end,
      joinpath = function(a, b) return a .. "/" .. b end,
    },
    env = { config_dir = function() return "/tmp/fake-config" end },
    uv = { os_homedir = function() return "/tmp/fake-home" end },
  }
  local rows, uncovered = Dispatch._coverage_audit("/tmp/cov-test-partial", snap, {
    { kind = "review", status = "done", specialist = "r", verdict = "approve",
      cached = true, scope_files = { "b.lua" } },
  })
  _G.maki = nil
  lu.assertEquals(#rows, 2)
  lu.assertEquals(rows[1].path, "a.lua")
  lu.assertEquals(rows[1].reviewers, nil, "the changed file has no coverage")
  lu.assertEquals(rows[2].path, "b.lua")
  lu.assertEquals(rows[2].reviewers[1].specialist, "r")
  lu.assertEquals(rows[2].reviewers[1].verdict, "approve")
  lu.assertEquals(#uncovered, 1, "the changed file is still uncovered")
  lu.assertEquals(uncovered[1].path, "a.lua")
end

-- Full cache hit: every file is provably unchanged, so cached findings ARE
-- replayed (combined_verdict prefixes each finding with its entry's path).
function TestDispatch:test_full_cache_hit_replays_cached_findings()
  local verdict, findings = Dispatch._combined_verdict({
    { path = "a.lua", verdict = "request-changes", findings = { { text = "fix x" } } },
    { path = "b.lua", verdict = "approve", findings = {} },
  })
  lu.assertEquals(verdict, "request-changes")
  lu.assertEquals(#findings, 1)
  lu.assertStrContains(findings[1].text, "[a.lua] fix x")
end

-- _resolve_review_files returns the review context as a third value: the
-- Ledger.context_key over the full scoped row set (fresh and cached files
-- alike). A full-scope cache hit requires every recorded entry to carry
-- exactly that context -- a mix of contexts never combines into a hit, and
-- any scoped change moves the context and empties the cache.
function TestDispatch:test_resolve_review_files_context_drives_full_cache_hit()
  local Ledger = require("specialist_subagents.ledger")
  local state = Ledger.new_state()
  local snap = { files = {
    { path = "a.lua", fingerprint = "fa" },
    { path = "b.lua", fingerprint = "fb" },
  } }
  local target = { specialist = "r", kind = "review", scope = { files = {} } }
  local spec = { name = "r" }

  local files, cached, context = Dispatch._resolve_review_files(state, target, spec, snap, false)
  lu.assertEquals(#files, 2)
  lu.assertEquals(context, Ledger.context_key(snap.files),
    "the third return value is context_key over the full scoped row set")

  -- entries recorded under two different contexts (each fingerprint
  -- matching its file) never combine into a hit for this scope's context
  Ledger.record(state, { specialist = "r", path = "a.lua", fingerprint = "fa",
    context = "review-context-a", verdict = "approve", ts = 1 })
  Ledger.record(state, { specialist = "r", path = "b.lua", fingerprint = "fb",
    context = "review-context-b", verdict = "approve", ts = 1 })
  files, cached = Dispatch._resolve_review_files(state, target, spec, snap, false)
  lu.assertEquals(#cached, 0, "no single review saw this scope's context: nothing hits")

  -- recording under exactly the scope's context yields the full cache hit
  for _, row in ipairs(snap.files) do
    Ledger.record(state, {
      specialist = "r", path = row.path, fingerprint = row.fingerprint,
      context = context, verdict = "approve", ts = 2,
    })
  end
  files, cached = Dispatch._resolve_review_files(state, target, spec, snap, false)
  lu.assertEquals(#cached, 2, "entries carrying exactly the scope context all hit")
  for _, f in ipairs(files) do
    lu.assertTrue(f.cached ~= nil)
  end

  -- a sibling fingerprint change moves the context: the hit is gone
  snap.files[2].fingerprint = "fb-changed"
  files, cached = Dispatch._resolve_review_files(state, target, spec, snap, false)
  lu.assertEquals(#cached, 0,
    "a scoped change moves the context and empties the cache")
end

-- A persist failure must not be swallowed: record_ledger warns via the
-- pipeline's warn_log convention.
function TestDispatch:test_record_ledger_persist_error_warns()
  local Ledger = require("specialist_subagents.ledger")
  local state = Ledger.new_state()
  local files = { { path = "a.lua", fingerprint = "fp" } }
  local parsed = { verdict = "approve", findings = {} }
  local real_persist = Ledger.persist
  local warnings = {}
  _G.maki = { log = { warn = function(msg) warnings[#warnings + 1] = msg end } }

  Ledger.persist = function() return nil, "boom" end
  Dispatch._record_ledger(state, { name = "r" }, files, parsed, "/tmp/cwd")
  Ledger.persist = real_persist
  lu.assertEquals(#warnings, 1)
  lu.assertStrContains(warnings[1], "ledger persist failed: boom")

  -- success path stays silent
  Ledger.persist = function() return true end
  Dispatch._record_ledger(state, { name = "r" }, files, parsed, "/tmp/cwd")
  Ledger.persist = real_persist
  _G.maki = nil
  lu.assertEquals(#warnings, 1, "no warning on a successful persist")
end

-- reviews_lookup must report every specialist that covered a path (newest
-- first), not only the newest entry, and count files in the summary.
-- Freshness is context-relative: an older review of the same file content
-- under a different (older) scope is still listed, but annotated stale and
-- never counts towards coverage.
function TestDispatch:test_reviews_lookup_reports_all_specialists_per_path()
  local Ledger = require("specialist_subagents.ledger")
  local Git = require("specialist_subagents.git")
  local state = Ledger.new_state()
  -- files-basis over a.lua; the stub reads every file as "content", so the
  -- live fingerprint is fnv1a("content")
  local fp = Git.fnv1a("content")
  local ctx = Ledger.context_key({ { path = "a.lua", fingerprint = fp } })
  local old_ctx = Ledger.context_key({
    { path = "a.lua", fingerprint = fp }, { path = "sibling.lua", fingerprint = "fp-sib" },
  })
  Ledger.record(state, { specialist = "old-reviewer", path = "a.lua",
    fingerprint = fp, context = old_ctx, verdict = "approve", ts = 1000 })
  Ledger.record(state, { specialist = "new-reviewer", path = "a.lua",
    fingerprint = fp, context = ctx, verdict = "request-changes", ts = 2000 })
  Dispatch._state.ledgers["/tmp/fake-proj"] = state
  _G.maki = {
    uv = { cwd = function() return "/tmp/fake-proj" end },
    fs = {
      glob = function() return { "/tmp/fake-proj/a.lua" } end,
      joinpath = function(a, b) return a .. "/" .. b end,
      normalize = function(p) return p end,
      read = function() return "content" end,
    },
  }
  local ok, text = pcall(Dispatch.reviews_lookup, nil, { basis = "files", files = { "a.lua" } })
  _G.maki = nil
  lu.assertTrue(ok, "reviews_lookup runs: " .. tostring(text))
  local new_pos = text:find("new-reviewer", 1, true)
  local old_pos = text:find("old-reviewer", 1, true)
  lu.assertTrue(new_pos ~= nil, "the newest specialist's row is present")
  lu.assertTrue(old_pos ~= nil, "the older specialist's row is not shadowed")
  lu.assertTrue(new_pos < old_pos, "rows are newest first")
  lu.assertStrContains(text, "request-changes")
  lu.assertStrContains(text, "approve")
  local stale_line, fresh_line
  for line in text:gmatch("[^\n]+") do
    if line:find("old-reviewer", 1, true) then
      stale_line = line
    elseif line:find("new-reviewer", 1, true) then
      fresh_line = line
    end
  end
  lu.assertTrue(stale_line ~= nil and fresh_line ~= nil, "both specialists rendered")
  lu.assertStrContains(stale_line, "; stale context",
    "the old-scope review is annotated stale")
  lu.assertEquals(fresh_line:find("; stale context", 1, true), nil,
    "the current-context review is fresh")
  lu.assertStrContains(text,
    "1 of 1 file(s) have fresh ledger coverage (file content and review scope unchanged since the review).",
    false, "only the current-context review counts as coverage")

  -- a path with no ledger entries is still reported UNREVIEWED
  _G.maki = {
    uv = { cwd = function() return "/tmp/fake-proj" end },
    fs = {
      glob = function() return { "/tmp/fake-proj/zzz.lua" } end,
      joinpath = function(a, b) return a .. "/" .. b end,
      normalize = function(p) return p end,
      read = function() return "content" end,
    },
  }
  ok, text = pcall(Dispatch.reviews_lookup, nil, { basis = "files", files = { "zzz.lua" } })
  _G.maki = nil
  Dispatch._state.ledgers["/tmp/fake-proj"] = nil
  lu.assertTrue(ok, "reviews_lookup runs: " .. tostring(text))

  lu.assertStrContains(text, "UNREVIEWED")
  lu.assertStrContains(text,
    "0 of 1 file(s) have fresh ledger coverage (file content and review scope unchanged since the review).")
end

-- Regression: the active-claims registry drops rows by identity, not by
-- owner name. Two fan-out targets sharing one specialist name used to be
-- able to drop each other's still-active claims when one of them hit an
-- open failure: the name-matching drop removed the sibling's row too.
function TestDispatch:test_claim_registration_is_per_dispatch()
  Dispatch._state.claims = {}
  local row_a = Dispatch._register_claims({ claims = { "src/**" }, specialist = "test-engineer" })
  local row_b = Dispatch._register_claims({ claims = { "spec/**" }, specialist = "test-engineer" })
  lu.assertEquals(row_a.owner, "test-engineer")
  lu.assertEquals(row_a.claims, { "src/**" })
  lu.assertEquals(#Dispatch._state.claims, 2)

  -- dropping row A leaves row B intact, by identity
  Dispatch._drop_claims(row_a)
  lu.assertEquals(#Dispatch._state.claims, 1)
  lu.assertTrue(rawequal(Dispatch._state.claims[1], row_b), "the sibling row survives the drop")
  lu.assertEquals(Dispatch._state.claims[1].owner, "test-engineer")

  -- the open-failure path and the completion path can both fire for the
  -- same dispatch; the second drop is a no-op and cannot touch row B
  Dispatch._drop_claims(row_a)
  lu.assertEquals(#Dispatch._state.claims, 1)
  Dispatch._drop_claims(nil)
  lu.assertEquals(#Dispatch._state.claims, 1, "dropping nil is a no-op")

  Dispatch._drop_claims(row_b)
  lu.assertEquals(#Dispatch._state.claims, 0)
  Dispatch._state.claims = {}
end

-- Regression: the same-dispatch self-overlap exemption. register_claim tags
-- each row with id of the target's dispatch, which is what the
-- _self_overlap_skip predicate scopes on; a target without _dispatch gets a
-- nil (not false) dispatch_id.
function TestDispatch:test_register_claim_tags_dispatch_id_from_target_dispatch()
  Dispatch._state.claims = {}
  local row_a = Dispatch._register_claims({
    claims = { "src/**" }, specialist = "test-engineer",
    _dispatch = { id = 7, idx = 1 },
  })
  lu.assertEquals(row_a.dispatch_id, 7, "the row carries target._dispatch.id")
  local row_b = Dispatch._register_claims({
    claims = { "spec/**" }, specialist = "test-engineer",
  })
  lu.assertNil(row_b.dispatch_id, "no _dispatch means nil, not false")
  Dispatch._state.claims = {}
end

-- Regression: the _self_overlap_skip predicate scopes the exemption to rows
-- of the same owner inside the same dispatch. The `target._dispatch ~= nil`
-- guard keeps untagged legacy rows from matching a target without a
-- dispatch: nil dispatch_id must never "equal" a nil dispatch id, and
-- evaluating the predicate must not raise.
function TestDispatch:test_self_overlap_skip_predicate_scopes_to_same_dispatch_and_owner()
  local skip = Dispatch._self_overlap_skip({ specialist = "impl", _dispatch = { id = 7 } })
  lu.assertEquals(skip({ owner = "impl", dispatch_id = 7 }), true)
  lu.assertEquals(skip({ owner = "other", dispatch_id = 7 }), false, "same dispatch, other owner")
  lu.assertEquals(skip({ owner = "impl", dispatch_id = 9 }), false, "same owner, other dispatch")
  lu.assertEquals(skip({ owner = "impl" }), false, "untagged legacy row is never skipped")

  -- a target without _dispatch gets an always-false predicate; indexing a
  -- nil _dispatch used to be the nil==nil hazard here (would raise)
  local no_dispatch = Dispatch._self_overlap_skip({ specialist = "impl" })
  lu.assertEquals(no_dispatch({ owner = "impl", dispatch_id = 7 }), false)
  lu.assertEquals(no_dispatch({ owner = "impl" }), false,
    "nil dispatch_id never matches a nil dispatch id, without raising")
end

-- Regression: plan-basis reviews_lookup used to stringify the failed
-- snapshot value itself ("error: nil"), hiding why basis = "plan" refused.
-- The snapshot's failure reason must surface, and a raising plan.read is
-- caught and surfaces the same reason.
function TestDispatch:test_reviews_lookup_plan_basis_surfaces_snapshot_reason()
  local Ledger = require("specialist_subagents.ledger")

  -- (a) plan.read reports no ready plan
  Dispatch._state.ledgers["/tmp/fake-proj"] = Ledger.new_state()
  _G.maki = {
    uv = { cwd = function() return "/tmp/fake-proj" end },
    plan = { read = function() return { ready = false } end },
  }
  local text, is_err = Dispatch.reviews_lookup(nil, { basis = "plan" })
  _G.maki = nil
  Dispatch._state.ledgers["/tmp/fake-proj"] = nil
  lu.assertTrue(is_err)
  lu.assertStrContains(text, "no ready plan")
  lu.assertNotEquals(text, "error: nil",
    "the snapshot's reason surfaces, not the nil snapshot value")

  -- (b) plan.read raising surfaces the same reason (pcall path)
  Dispatch._state.ledgers["/tmp/fake-proj"] = Ledger.new_state()
  _G.maki = {
    uv = { cwd = function() return "/tmp/fake-proj" end },
    plan = { read = function() error("no plan host") end },
  }
  text, is_err = Dispatch.reviews_lookup(nil, { basis = "plan" })
  _G.maki = nil
  Dispatch._state.ledgers["/tmp/fake-proj"] = nil
  lu.assertTrue(is_err)
  lu.assertStrContains(text, "no ready plan")
  lu.assertNotEquals(text, "error: nil")

  -- (c) happy path: a ready plan is covered by its ledger row
  local Git = require("specialist_subagents.git")
  local fp_plan = Git.fnv1a("planned work")
  local state = Ledger.new_state()
  Ledger.record(state, {
    specialist = "tech-writer", path = "plan.md",
    fingerprint = fp_plan,
    context = Ledger.context_key({ { path = "plan.md", fingerprint = fp_plan } }),
    verdict = "approve",
  })
  Dispatch._state.ledgers["/tmp/fake-proj"] = state
  _G.maki = {
    uv = { cwd = function() return "/tmp/fake-proj" end },
    plan = { read = function()
      return { ready = true, content = "planned work", path = "plan.md" }
    end },
  }
  text, is_err = Dispatch.reviews_lookup(nil, { basis = "plan" })
  _G.maki = nil
  Dispatch._state.ledgers["/tmp/fake-proj"] = nil
  lu.assertEquals(is_err, nil)
  lu.assertStrContains(text, "plan.md")
  lu.assertStrContains(text, "tech-writer")
  lu.assertStrContains(text,
    "1 of 1 file(s) have fresh ledger coverage (file content and review scope unchanged since the review).")
end

-- Regression: ledger entries without ts are legitimate (Ledger.record
-- stores caller input verbatim); reviews_lookup fed the nil ts straight
-- into a %d format and crashed the whole query. Nil-ts rows render with
-- "age unknown" and ts-bearing companions still render an age.
function TestDispatch:test_reviews_lookup_survives_entries_with_nil_timestamp()
  local Ledger = require("specialist_subagents.ledger")
  local Git = require("specialist_subagents.git")
  -- the stub reads every file as "content", so the live fingerprint is
  -- fnv1a("content"); the two queries below have different scopes, and
  -- freshness is scope-relative, so their entries carry different contexts
  local fp = Git.fnv1a("content")
  local ctx_a = Ledger.context_key({ { path = "a.lua", fingerprint = fp } })
  local ctx_ab = Ledger.context_key({
    { path = "a.lua", fingerprint = fp }, { path = "b.lua", fingerprint = fp },
  })
  local state = Ledger.new_state()
  Ledger.record(state, {
    specialist = "x", path = "a.lua", fingerprint = fp, context = ctx_a,
    verdict = "approve",
  }) -- deliberately no ts
  -- entries for the {a.lua, b.lua} scope: z is fresh for a.lua and y for
  -- b.lua under that (wider) query context
  Ledger.record(state, {
    specialist = "z", path = "a.lua", fingerprint = fp, context = ctx_ab,
    verdict = "approve", ts = os.time() - 3600,
  })
  Ledger.record(state, {
    specialist = "y", path = "b.lua", fingerprint = fp, context = ctx_ab,
    verdict = "approve", ts = os.time() - 3600,
  })
  Dispatch._state.ledgers["/tmp/fake-proj"] = state
  _G.maki = {
    uv = { cwd = function() return "/tmp/fake-proj" end },
    fs = {
      glob = function() return { "/tmp/fake-proj/a.lua" } end,
      joinpath = function(a, b) return a .. "/" .. b end,
      normalize = function(p) return p end,
      read = function() return "content" end,
    },
  }
  local ok, text = pcall(Dispatch.reviews_lookup, nil, { basis = "files", files = { "a.lua" } })
  lu.assertTrue(ok, "reviews_lookup does not raise on a ts-less entry: " .. tostring(text))
  lu.assertStrContains(text, "x")
  lu.assertStrContains(text,
    "1 of 1 file(s) have fresh ledger coverage (file content and review scope unchanged since the review).")
  lu.assertStrContains(text, "age unknown", "the ts-less row renders instead of crashing")

  -- a companion ts-bearing entry still renders an "Ns ago" age
  _G.maki.fs.glob = function() return { "/tmp/fake-proj/a.lua", "/tmp/fake-proj/b.lua" } end
  ok, text = pcall(Dispatch.reviews_lookup, nil, { basis = "files", files = { "a.lua", "b.lua" } })
  _G.maki = nil
  Dispatch._state.ledgers["/tmp/fake-proj"] = nil
  lu.assertTrue(ok, "reviews_lookup still runs: " .. tostring(text))
  lu.assertTrue(text:find("%ds ago") ~= nil, "the ts-bearing row renders an age")
  lu.assertStrContains(text,
    "2 of 2 file(s) have fresh ledger coverage (file content and review scope unchanged since the review).")
end

-- ---------------------------------------------------------------------------
-- Background dispatch validation + running-dispatch registry
-- (plan: refined-casual-grouse)
-- ---------------------------------------------------------------------------

function TestDispatch:test_background_error_rules()
  local main = { name = "main", chain = {} }
  local nested = { name = "impl", chain = { { name = "a", kind = "task" } } }
  -- allowed shape
  lu.assertEquals(Dispatch.background_error(main, true, false), nil)
  -- kill switch
  lu.assertStrContains(Dispatch.background_error(main, false, false), "allow_background = false")
  -- nested delegates stay synchronous (user decision, delegated-reach pricing)
  lu.assertStrContains(Dispatch.background_error(nested, true, false), "main-only")
  -- headless: no task UI to wake/notify
  lu.assertStrContains(Dispatch.background_error(main, true, true), "task UI")
  lu.assertStrContains(Dispatch.background_error(main, true, true), "synchronously")
end

function TestDispatch:test_action_error_rules()
  local main = { name = "main", chain = {} }
  local nested = { name = "impl", chain = { { name = "a", kind = "task" } } }
  lu.assertEquals(Dispatch.action_error({ action = "status" }, main), nil)
  lu.assertEquals(Dispatch.action_error({ action = "status" }, nested), nil,
    "status is a read-only query, allowed from any invoker")
  lu.assertEquals(Dispatch.action_error({ action = "message", text = "hi" }, main), nil)
  lu.assertEquals(Dispatch.action_error({ action = "stop" }, main), nil)
  lu.assertStrContains(Dispatch.action_error({ action = "message", text = "hi" }, nested), "main-only")
  lu.assertStrContains(Dispatch.action_error({ action = "stop" }, nested), "main-only")
  lu.assertStrContains(Dispatch.action_error({ action = "message" }, main), "needs text")
  lu.assertStrContains(Dispatch.action_error({ action = "message", text = "" }, main), "needs text")
  lu.assertStrContains(Dispatch.action_error({ action = "pause" }, main), "status")
  lu.assertStrContains(Dispatch.action_error({ action = "stop", dispatch = 7 }, main), "dispatch id")
  -- action must not be combined with dispatching fields
  lu.assertStrContains(Dispatch.action_error({ action = "status", specialist = "r", brief = "b" }, main),
    "remove specialist")
  lu.assertStrContains(Dispatch.action_error({ action = "status", background = true }, main),
    "remove background")
  lu.assertStrContains(Dispatch.action_error({ action = "status", targets = {} }, main), "remove targets")
end

function TestDispatch:test_running_registry_lifecycle()
  local State = Dispatch._state
  local entry = Dispatch.running_register("bg-77", "sess-A", true, {
    { specialist = "r1", kind = "review" },
    { specialist = "t1", kind = "task" },
  })
  lu.assertEquals(entry.seq, 77)
  lu.assertEquals(entry.background, true)
  lu.assertEquals(#entry.targets, 2)
  lu.assertEquals(entry.targets[1].status, "running")
  lu.assertEquals(State.running["bg-77"], entry)

  -- attach a live session, then mark terminal: the session is detached and
  -- the entry survives while the sibling target is still running
  Dispatch.running_attach("bg-77", 1, { fake = "sess" })
  lu.assertEquals(entry.targets[1].sess.fake, "sess")
  Dispatch.running_mark("bg-77", 1, "done")
  lu.assertEquals(entry.targets[1].status, "done")
  lu.assertEquals(entry.targets[1].sess, nil, "terminal target detaches its session")
  lu.assertEquals(State.running["bg-77"], entry, "entry survives while a target is running")
  -- marking a finished target again is idempotent
  Dispatch.running_mark("bg-77", 1, "done")
  lu.assertEquals(State.running["bg-77"], entry)
  Dispatch.running_mark("bg-77", 2, "cancelled")
  lu.assertEquals(State.running["bg-77"], nil, "entry dropped when every target is done")

  -- matching: by parent session, filtered and oldest-first; or by id
  Dispatch.running_register("bg-80", "sess-B", true, { { specialist = "x", kind = "review" } })
  Dispatch.running_register("d-79", "sess-A", false, { { specialist = "y", kind = "task" } })
  Dispatch.running_register("bg-81", "sess-A", true, { { specialist = "z", kind = "review" } })
  local ids = {}
  for _, e in ipairs(Dispatch.match_dispatches("sess-A")) do
    ids[#ids + 1] = e.id
  end
  lu.assertEquals(ids, { "d-79", "bg-81" }, "own dispatches, oldest first, not other sessions'")
  ids = {}
  for _, e in ipairs(Dispatch.match_dispatches("sess-B")) do
    ids[#ids + 1] = e.id
  end
  lu.assertEquals(ids, { "bg-80" })
  lu.assertEquals(#Dispatch.match_dispatches("sess-A", "bg-80"), 0,
    "an explicit id from another session is not matched")
  lu.assertEquals(Dispatch.match_dispatches("sess-A", "bg-81")[1].id, "bg-81")
  lu.assertEquals(#Dispatch.match_dispatches("sess-A", "bg-999"), 0)
  Dispatch.running_pop("bg-80")
  Dispatch.running_pop("d-79")
  Dispatch.running_pop("bg-81")
  lu.assertEquals(#Dispatch.match_dispatches("sess-A"), 0)
end

function TestDispatch:test_validate_background_target_refusals()
  local Registry = require("specialist_subagents.registry")
  local saved_get = Registry.get
  local specs = {
    r = { name = "r", type = "review" },
    impl = { name = "impl", type = "implementation" },
  }
  Registry.get = function(_, name) return specs[name] end
  local ok1, err = pcall(function()
    local main = { name = "main", chain = {} }
    -- unknown specialist
    local e = Dispatch.validate_background_target("/tmp/x",
      { specialist = "nobody", brief = "b", claims = {}, scope = { files = {} } }, main, { used = 0 })
    lu.assertStrContains(e, "unknown specialist")
    -- cycle refusal surfaces synchronously
    e = Dispatch.validate_background_target("/tmp/x",
      { specialist = "r", brief = "b", claims = {}, scope = { files = {} } },
      { name = "r", chain = {} }, { used = 0 })
    lu.assertStrContains(e, "cycle")
    -- budget exhaustion via the throwaway counter
    local Config = require("specialist_subagents.config")
    local saved_budget = Config.per_turn_budget
    Config.per_turn_budget = 1
    e = Dispatch.validate_background_target("/tmp/x",
      { specialist = "r", brief = "b", claims = {}, scope = { files = {} } }, main, { used = 1 })
    Config.per_turn_budget = saved_budget
    lu.assertStrContains(e, "budget exhausted")
    -- clean target passes
    e = Dispatch.validate_background_target("/tmp/x",
      { specialist = "r", brief = "b", kind = "review", claims = {}, scope = { files = {} } },
      main, { used = 0 })
    lu.assertEquals(e, nil)
    -- strict_claims conflict surfaces synchronously (task dispatch, strict on)
    local saved_strict = Config.strict_claims
    Config.strict_claims = true
    Dispatch._state.claims[1] = { claims = { "src/**" }, owner = "sibling" }
    e = Dispatch.validate_background_target("/tmp/x",
      { specialist = "impl", brief = "b", kind = "task", claims = { "src/**" }, scope = { files = {} } },
      main, { used = 0 })
    Config.strict_claims = saved_strict
    Dispatch._state.claims[1] = nil
    lu.assertStrContains(e, "strict_claims")
  end)
  Registry.get = saved_get
  lu.assertTrue(ok1, "validate_background_target runs: " .. tostring(err))
end

-- normalize_input must keep accepting dispatch inputs that also carry
-- background/action-style keys (they are handled by handle(), not targets).
function TestDispatch:test_normalize_input_ignores_background_and_action_keys()
  local targets, err = Dispatch.normalize_input({
    specialist = "r", brief = "b", background = true,
  })
  lu.assertEquals(err, nil)
  lu.assertEquals(#targets, 1)
  lu.assertEquals(targets[1].background, nil, "background is not a per-target field")
end

function TestDispatch:test_running_attach_stores_only_a_nonempty_string_task_id()
  -- row.task_id drives the action = "message" notify fallback and the
  -- requested compaction; a value that is not a non-empty string must never
  -- pose as one, or it would become a bogus host task lookup key.
  local entry = Dispatch.running_register("d-900", "sess-TID", false, {
    { specialist = "r1", kind = "review" },
  })
  Dispatch.running_attach("d-900", 1, { fake = "sess" }, "task-42")
  lu.assertEquals(entry.targets[1].sess.fake, "sess")
  lu.assertEquals(entry.targets[1].task_id, "task-42")

  for _, bad in ipairs({ 42, "", nil, { "task-42" } }) do
    Dispatch.running_attach("d-900", 1, { fake = "sess" }, bad)
    lu.assertEquals(entry.targets[1].task_id, nil,
      "task_id " .. tostring(bad) .. " is dropped, not stored")
  end

  -- the resolved kind (the kind the session actually opened under, defaulted
  -- from the specialist type) replaces the row's raw input kind, which is
  -- nil for kind-omitting dispatches; a non-string never overwrites
  local entry2 = Dispatch.running_register("d-901", "sess-TID", false, {
    { specialist = "r2", kind = nil },
  })
  lu.assertEquals(entry2.targets[1].kind, nil, "raw kind starts nil")
  Dispatch.running_attach("d-901", 1, { fake = "sess" }, "task-43", "review")
  lu.assertEquals(entry2.targets[1].kind, "review",
    "attach records the resolved kind for ownership checks")
  Dispatch.running_attach("d-901", 1, { fake = "sess" }, nil, 42)
  lu.assertEquals(entry2.targets[1].kind, "review", "non-string kind is ignored")
  Dispatch.running_pop("d-901")

  -- attaching to an unknown dispatch or index is a no-op, never a raise
  Dispatch.running_attach("d-999", 1, { fake = "x" }, "task-42")
  Dispatch.running_attach("d-900", 9, { fake = "x" }, "task-42")
  Dispatch.running_pop("d-900")
end

function TestDispatch:test_running_for_session_counts_running_targets_and_collects_sorted_ids()
  -- The agent.compact.before defer layer's input: (count, ids) for one
  -- parent chat session. Counts live targets, not entries — a dispatch
  -- with two specialists still running contributes 2.
  Dispatch.running_register("bg-31", "sess-D1", true, {
    { specialist = "r", kind = "review" },
    { specialist = "t", kind = "task" },
  })
  Dispatch.running_register("d-12", "sess-D1", false, { { specialist = "x", kind = "review" } })
  Dispatch.running_register("bg-30", "sess-D2", true, { { specialist = "y", kind = "review" } })

  local count, ids = Dispatch.running_for_session("sess-D1")
  lu.assertEquals(count, 3, "two targets of bg-31 plus one of d-12")
  lu.assertEquals(ids, { "bg-31", "d-12" }, "ids sorted, other sessions excluded")
  count, ids = Dispatch.running_for_session("sess-D2")
  lu.assertEquals(count, 1)
  lu.assertEquals(ids, { "bg-30" })

  -- non-string session ids (headless host, unknown session): nothing to
  -- defer for, and never an error
  for _, sid in ipairs({ nil, 42, {}, true }) do
    count, ids = Dispatch.running_for_session(sid)
    lu.assertEquals(count, 0, "session id " .. tostring(sid) .. " counts nothing")
    lu.assertEquals(ids, {})
  end

  -- marking one target of bg-31 done: one live target still counts
  Dispatch.running_mark("bg-31", 1, "done")
  count, ids = Dispatch.running_for_session("sess-D1")
  lu.assertEquals(count, 2)
  lu.assertEquals(ids, { "bg-31", "d-12" }, "the entry survives while a target runs")
  -- last target done: the entry is dropped and contributes nothing
  Dispatch.running_mark("bg-31", 2, "done")
  count, ids = Dispatch.running_for_session("sess-D1")
  lu.assertEquals(count, 1)
  lu.assertEquals(ids, { "d-12" })
  -- an entry whose every target is terminal (injected directly, as
  -- running_mark would have dropped it) contributes nothing either
  Dispatch._state.running["d-13"] = {
    id = "d-13", parent_session = "sess-D1", targets = { { status = "done" } },
  }
  count, ids = Dispatch.running_for_session("sess-D1")
  lu.assertEquals(count, 1, "a finished entry adds no live targets")
  lu.assertEquals(ids, { "d-12" }, "a finished entry contributes no id")
  Dispatch._state.running["d-13"] = nil
  -- and popping the live dispatch empties the result
  Dispatch.running_pop("d-12")
  count, ids = Dispatch.running_for_session("sess-D1")
  lu.assertEquals(count, 0)
  lu.assertEquals(ids, {})
  Dispatch.running_pop("bg-30")
end

-- The host-bound helpers (owned_task, message_task, request_compact) must
-- degrade to "delivered nothing", never raise, on a hostless (spec)
-- environment or a pre-0.7.3 host lacking the APIs.
function TestDispatch:test_host_helper_guards_are_all_false_without_a_host()
  lu.assertEquals(_G.maki, nil, "precondition: no host global is set")
  local ok, err = pcall(function()
    lu.assertEquals(Dispatch.owned_task("t-1", "r", "review"), false)
    lu.assertEquals(Dispatch.owned_task(nil, "r", "review"), false)
    lu.assertEquals(Dispatch.owned_task(42, "r", "review"), false)
    lu.assertEquals(Dispatch.owned_task("t-1", nil, "review"), false)
    lu.assertEquals(Dispatch.message_task("sess", "t-1", "hi"), false)
    lu.assertEquals(Dispatch.message_task(nil, "t-1", "hi"), false)
    lu.assertEquals(Dispatch.message_task("sess", nil, "hi"), false)
    lu.assertEquals(Dispatch.message_task("sess", "t-1", ""), false, "empty text refused")
    lu.assertEquals(Dispatch.message_task("sess", "t-1", nil), false)
    lu.assertEquals(Dispatch.request_compact("sess", "t-1"), false)
    lu.assertEquals(Dispatch.request_compact(nil, "t-1"), false)
    lu.assertEquals(Dispatch.request_compact("sess", nil), false)
  end)
  lu.assertTrue(ok, "guards never raise: " .. tostring(err))
end

function TestDispatch:test_owned_task_matches_id_name_and_ownership_with_a_stubbed_host()
  _G.maki = {
    task = {
      list = function()
        -- malformed list entries must not break the scan; only our own
        -- plugin's sub sessions under the expected "<spec>:<kind>" name
        -- count as owned
        return {
          { id = "t-1", name = "r:review", plugin = "specialist-subagents" },
          { id = "t-2", name = "r:review", plugin = "project/init.lua" },
          { id = "t-3", name = "other:review", plugin = "specialist-subagents" },
          { id = "t-4", name = "r:task", plugin = "specialist-subagents" },
          "garbage", { id = 42 }, {},
        }
      end,
    },
  }
  local ok, err = pcall(function()
    lu.assertEquals(Dispatch.owned_task("t-1", "r", "review"), true)
    lu.assertEquals(Dispatch.owned_task("t-2", "r", "review"), true,
      "config-dir plugins load under \"<dir>/init.lua\" names too")
    lu.assertEquals(Dispatch.owned_task("t-3", "r", "review"), false,
      "same id shape, wrong specialist name: not ours")
    lu.assertEquals(Dispatch.owned_task("t-4", "r", "review"), false,
      "same specialist, wrong kind: not ours")
    lu.assertEquals(Dispatch.owned_task("t-5", "r", "review"), false)
    lu.assertEquals(Dispatch.owned_task(42, "r", "review"), false)
    -- a raising task.list is absorbed, never surfaces
    _G.maki.task.list = function() error("host boom") end
    lu.assertEquals(Dispatch.owned_task("t-1", "r", "review"), false)
    -- a non-table list result reads as "not owned"
    _G.maki.task.list = function() return "garbage" end
    lu.assertEquals(Dispatch.owned_task("t-1", "r", "review"), false)
  end)
  _G.maki = nil
  if not ok then
    error(err)
  end
end

function TestDispatch:test_message_task_passes_task_scoped_options_with_a_stubbed_host()
  local notified = {}
  _G.maki = {
    session = {
      notify = function(text, opts)
        notified[#notified + 1] = { text, opts }
        return true, nil
      end,
    },
  }
  local ok, err = pcall(function()
    lu.assertEquals(Dispatch.message_task("sess", "t-1", "hi"), true)
    lu.assertEquals(#notified, 1)
    lu.assertEquals(notified[1][1], "hi")
    lu.assertEquals(notified[1][2], { session = "sess", task = "t-1", wake = true },
      "wake = true so the specialist's next run reads the message")
    -- a raising notify is absorbed: failed delivery, not a raise
    _G.maki.session.notify = function() error("host boom") end
    lu.assertEquals(Dispatch.message_task("sess", "t-1", "hi"), false)
    -- notify reports failure by return value (nil, err), not by raising:
    -- that is a failed delivery too, never a reported success
    _G.maki.session.notify = function() return nil, "no such task" end
    lu.assertEquals(Dispatch.message_task("sess", "t-1", "hi"), false)
  end)
  _G.maki = nil
  if not ok then
    error(err)
  end
end

function TestDispatch:test_request_compact_config_gates_before_the_host_with_a_stubbed_host()
  -- compact_specialists = false must refuse before any host call: the gate
  -- is the first branch, so a disabled config costs nothing on the host.
  local Config = require("specialist_subagents.config")
  local compacted = {}
  _G.maki = {
    session = {
      request_compact = function(opts)
        compacted[#compacted + 1] = opts
        return true, nil
      end,
    },
  }
  local saved = Config.compact_specialists
  local ok, err = pcall(function()
    Config.compact_specialists = false
    lu.assertEquals(Dispatch.request_compact("sess", "t-1"), false)
    lu.assertEquals(#compacted, 0, "the gate fires before the host call")
    Config.compact_specialists = true
    lu.assertEquals(Dispatch.request_compact("sess", "t-1"), true)
    lu.assertEquals(compacted, { { session = "sess", task = "t-1" } })
    -- a raising host call is absorbed, never surfaces
    _G.maki.session.request_compact = function() error("host boom") end
    lu.assertEquals(Dispatch.request_compact("sess", "t-1"), false)
    -- a nil, err return (the documented second-request refusal) is a
    -- failed queueing, not a success
    _G.maki.session.request_compact = function() return nil, "already queued" end
    lu.assertEquals(Dispatch.request_compact("sess", "t-1"), false)
  end)
  Config.compact_specialists = saved
  _G.maki = nil
  if not ok then
    error(err)
  end
end

function TestDispatch:test_handle_action_message_send_failure_falls_back_to_task_notify()
  -- End-to-end over the message path with a minimal global maki stub:
  -- sess:send fails, the target's task is alive, so the text goes out via
  -- maki.session.notify's task option, the row reports the fallback, both
  -- targets get a compaction queued for their continued runs, and the
  -- well-behaved sibling never goes through the fallback.
  local main = { name = "main", chain = {} }
  local ctx = { session_id = function() return "sess-ACT" end }
  Dispatch.running_register("bg-90", "sess-ACT", true, {
    { specialist = "r1", kind = "review" },
    { specialist = "r2", kind = "task" },
  })
  local sent, notified, compacted = {}, {}, {}
  local failing = {
    send = function(_, text)
      sent[#sent + 1] = { "failing", text }
      return false, "peer closed"
    end,
    close = function() end,
  }
  local working = {
    send = function(_, text)
      sent[#sent + 1] = { "working", text }
      return true
    end,
    close = function() end,
  }
  Dispatch.running_attach("bg-90", 1, failing, "task-1")
  Dispatch.running_attach("bg-90", 2, working, "task-2")
  _G.maki = {
    task = {
      list = function()
        -- ownership-shaped entries: the fallback re-verifies that the row's
        -- task id is a live task of ours under "<specialist>:<kind>"
        return {
          { id = "task-1", name = "r1:review", plugin = "specialist-subagents" },
          { id = "task-2", name = "r2:task", plugin = "specialist-subagents" },
        }
      end,
    },
    session = {
      notify = function(text, opts)
        notified[#notified + 1] = { text, opts }
        return true, nil
      end,
      request_compact = function(opts)
        compacted[#compacted + 1] = opts
        return true, nil
      end,
    },
  }
  local out, is_err
  local ok, e = pcall(function()
    out, is_err = Dispatch.handle_action(ctx,
      { action = "message", text = "status?", dispatch = "bg-90" }, main)
  end)
  _G.maki = nil
  Dispatch.running_pop("bg-90")
  lu.assertTrue(ok, "handle_action runs: " .. tostring(e))
  lu.assertEquals(is_err, false)
  lu.assertStrContains(out, "2 delivered, 0 not delivered")
  lu.assertStrContains(out, "send failed; queued via task notify")
  lu.assertStrContains(out, "queued")
  lu.assertEquals(#notified, 1, "only the failing send falls back to notify")
  lu.assertEquals(notified[1][1], "status?")
  lu.assertEquals(notified[1][2], { session = "sess-ACT", task = "task-1", wake = true })
  -- after either successful delivery a compaction was queued for the
  -- specialist's continued run (fallback first, direct send second)
  lu.assertEquals(compacted, {
    { session = "sess-ACT", task = "task-1" },
    { session = "sess-ACT", task = "task-2" },
  })
end

return TestDispatch
