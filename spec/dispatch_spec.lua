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
  Ledger.record(state, {
    specialist = "r", path = "a.lua", fingerprint = "fp-old",
    verdict = "request-changes",
    findings = { { text = "stale finding on a.lua" } },
    ts = 100,
  })
  Ledger.record(state, {
    specialist = "r", path = "b.lua", fingerprint = "fp-b",
    verdict = "approve", findings = {}, ts = 100,
  })
  local snap = { files = {
    { path = "a.lua", fingerprint = "fp-new" }, -- changed since the review
    { path = "b.lua", fingerprint = "fp-b" },
  } }
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
function TestDispatch:test_reviews_lookup_reports_all_specialists_per_path()
  local Ledger = require("specialist_subagents.ledger")
  local state = Ledger.new_state()
  Ledger.record(state, { specialist = "old-reviewer", path = "a.lua",
    fingerprint = "fp1", verdict = "approve", ts = 1000 })
  Ledger.record(state, { specialist = "new-reviewer", path = "a.lua",
    fingerprint = "fp2", verdict = "request-changes", ts = 2000 })
  Ledger.record(state, { specialist = "new-reviewer", path = "b.lua",
    fingerprint = "fp3", verdict = "approve", ts = 2000 })
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
  lu.assertStrContains(text, "1 of 1 file(s) have ledger coverage") -- summary counts files, not rows

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
  lu.assertStrContains(text, "0 of 1 file(s) have ledger coverage")
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

return TestDispatch
