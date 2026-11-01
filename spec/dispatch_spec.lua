-- Dispatch pure surface: input normalization and the policy engine
-- (cycle checks, depth caps, task allowlists, impl chain cap).

local H = require("helpers")
local Dispatch = require("specialist_subagents.dispatch")

local function ok_policy(target, spec, invoker)
  local kind, err = Dispatch.check_policy(target, spec, invoker)
  return kind ~= nil, err
end

local review_spec = { name = "scss-reviewer", type = "review" }
local impl_spec = { name = "test-engineer", type = "implementation" }

H.case("normalize_input: scalar form gets defaults", function()
  local targets, err = Dispatch.normalize_input({ specialist = "r", brief = "do it" })
  H.eq(err, nil)
  H.eq(#targets, 1)
  H.eq(targets[1].specialist, "r")
  H.eq(targets[1].kind, nil, "kind inferred later from the specialist type")
  H.eq(targets[1].scope.basis, "changed")
  H.eq(targets[1].scope.files, {})
  H.eq(targets[1].claims, {})
  H.eq(targets[1].force_review, false)
end)

H.case("normalize_input: targets list form", function()
  local targets = Dispatch.normalize_input({
    targets = {
      { specialist = "a", brief = "x" },
      { specialist = "b", brief = "y", kind = "review", force_review = true,
        scope = { files = { "**/*.lua" }, basis = "plan" }, claims = { "src/**" } },
    },
  })
  H.eq(#targets, 2)
  H.eq(targets[2].kind, "review")
  H.eq(targets[2].scope.basis, "plan")
  H.eq(targets[2].claims, { "src/**" })
end)

H.case("normalize_input: rejects malformed input", function()
  H.eq(Dispatch.normalize_input({ specialist = "r" }), nil, "brief required")
  H.eq(Dispatch.normalize_input({ brief = "x" }), nil, "specialist required")
  H.eq(Dispatch.normalize_input({ targets = {} }), nil, "empty fan-out")
  H.eq(Dispatch.normalize_input("nope"), nil)
  H.eq(Dispatch.normalize_input({ targets = { { specialist = "a" } } }), nil)
end)

H.case("policy: main can dispatch anything", function()
  local main = { name = "main", chain = {} }
  H.truthy(ok_policy({ specialist = "scss-reviewer", brief = "b" }, review_spec, main))
  H.truthy(ok_policy({ specialist = "test-engineer", brief = "b" }, impl_spec, main))
end)

H.case("policy: cycle through the chain is refused", function()
  local invoker = {
    name = "impl",
    chain = { { name = "test-engineer", kind = "task" } },
  }
  local ok, err = ok_policy({ specialist = "test-engineer", brief = "b" }, impl_spec, invoker)
  H.eq(ok, false)
  H.has(err, "cycle")
end)

H.case("policy: self-delegation is refused", function()
  local ok, err = ok_policy(
    { specialist = "test-engineer", brief = "b" }, impl_spec,
    { name = "test-engineer", chain = {} })
  H.eq(ok, false)
  H.has(err, "cycle")
end)

H.case("policy: review depth cap", function()
  local deep = {
    name = "reviewer",
    chain = { { name = "a", kind = "task" }, { name = "b", kind = "review" } },
  }
  local ok, err = ok_policy({ specialist = "scss-reviewer", brief = "b" }, review_spec, deep)
  H.eq(ok, false)
  H.has(err, "depth")
  -- depth 2 (one ancestor hop) is allowed
  local mid = { name = "impl", chain = { { name = "a", kind = "task" } } }
  H.truthy(ok_policy({ specialist = "scss-reviewer", brief = "b" }, review_spec, mid))
end)

H.case("policy: task delegation needs the allowlist", function()
  local invoker = { name = "test-engineer", chain = {} }
  local target = { specialist = "component-implementer", brief = "b" }
  local ok, err = ok_policy(target, impl_spec, invoker)
  H.eq(ok, false)
  H.has(err, "allowlist")
  local with_allow = { name = "test-engineer", chain = {}, delegate = { tasks = { "component-implementer" } } }
  H.truthy(ok_policy(target, impl_spec, with_allow))
end)

H.case("policy: impl chain cap - task-delegated specialists cannot task-delegate", function()
  local nested = {
    name = "impl",
    chain = { { name = "test-engineer", kind = "task" } },
    delegate = { tasks = { "anything" } },
  }
  local ok, err = ok_policy({ specialist = "anything", brief = "b" }, impl_spec, nested)
  H.eq(ok, false)
  H.has(err, "impl chain cap")
  -- review delegation still works from the same invoker (depth 2)
  H.truthy(ok_policy({ specialist = "scss-reviewer", brief = "b" }, review_spec, nested))
end)

H.case("policy: an implementer's own hop does not block its task delegation", function()
  -- real shape: the child invoker's chain ends with its own dispatch hop
  local child = {
    name = "test-engineer",
    chain = { { name = "test-engineer", kind = "task" } },
    delegate = { tasks = { "component-implementer" } },
  }
  H.truthy(ok_policy({ specialist = "component-implementer", brief = "b" }, impl_spec, child),
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
  H.eq(ok, false)
  H.has(err, "impl chain cap")
end)

H.case("policy: kind defaults follow the specialist type", function()
  local main = { name = "main", chain = {} }
  local kind = Dispatch.check_policy({ specialist = "x", brief = "b" }, review_spec, main)
  H.eq(kind, "review")
  kind = Dispatch.check_policy({ specialist = "x", brief = "b" }, impl_spec, main)
  H.eq(kind, "task")
  kind = Dispatch.check_policy({ specialist = "x", brief = "b", kind = "review" }, impl_spec, main)
  H.eq(kind, "review", "explicit kind overrides the type default")
end)

-- Regression: the recent-finished handoff lives on the plugin-lifetime
-- State, not on the per-project ledger state (which has no finished table).
-- The wrong-table version crashed every completing review with
-- "attempt to index nil with string" at store_finished.
H.case("finished handoff: stored on State, bounded at MAX_FINISHED", function()
  Dispatch._store_finished("handoff-regression", { status = "done", verdict = "approve" })
  local fin = Dispatch._state.finished["handoff-regression"]
  H.truthy(fin ~= nil, "handoff stored on State.finished")
  H.eq(fin.result.verdict, "approve")
  H.eq(type(fin.at), "number")
  for i = 1, 60 do
    Dispatch._store_finished("bound-" .. i, { status = "done" })
  end
  local n = 0
  for _ in pairs(Dispatch._state.finished) do
    n = n + 1
  end
  H.truthy(n <= 50, "handoff bounded (got " .. n .. ")")
  -- cleanup: leave no bound-* entries for later cases
  for k in pairs(Dispatch._state.finished) do
    Dispatch._state.finished[k] = nil
  end
end)

-- Regression: an unparsable review satisfies nothing, the review cache
-- included. combined_verdict defaults to "approve", so a verdict-less
-- cached entry would approve unchanged files without any review running.
H.case("review cache: verdict-less ledger entries are cache misses", function()
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
  H.eq(#files, 2, "both scoped files resolved")
  H.eq(#cached, 1, "only the verdict-bearing entry is cached")
  for _, f in ipairs(files) do
    if f.path == "a.lua" then
      H.eq(f.cached, nil, "verdict-less entry is a cache miss")
    else
      H.truthy(f.cached ~= nil, "b.lua carries its cached entry")
      H.eq(f.cached.verdict, "approve")
    end
  end

  -- positive case: a verdict-bearing entry is served from cache
  Ledger.record(state, {
    specialist = "r", path = "a.lua", fingerprint = "fp1",
    verdict = "request-changes", raw = "SUMMARY: needs work\nVERDICT: request-changes",
  })
  files, cached = Dispatch._resolve_review_files(state, target, spec, snap, false)
  H.eq(#cached, 2, "both verdict-bearing entries cached")
  for _, f in ipairs(files) do
    H.truthy(f.cached ~= nil)
  end

  -- force_review bypasses even a good cache entry
  files, cached = Dispatch._resolve_review_files(state, target, spec, snap, true)
  H.eq(#cached, 0, "force_review re-reviews everything")
  for _, f in ipairs(files) do
    H.eq(f.cached, nil)
  end
end)

H.case("normalize_input: files basis round-trips with files intact", function()
  local targets, err = Dispatch.normalize_input({
    specialist = "r", brief = "review the readme", kind = "review",
    scope = { basis = "files", files = { "README.md", "lua/**/*.lua" } },
  })
  H.eq(err, nil)
  H.eq(targets[1].scope.basis, "files")
  H.eq(targets[1].scope.files, { "README.md", "lua/**/*.lua" })
  -- unknown basis still falls back to changed
  targets = Dispatch.normalize_input({
    specialist = "r", brief = "b", scope = { basis = "bogus" },
  })
  H.eq(targets[1].scope.basis, "changed")
end)

H.case("normalize_input: kind consult is accepted", function()
  local targets, err = Dispatch.normalize_input({
    specialist = "x", brief = "b", kind = "consult",
  })
  H.eq(err, nil)
  H.eq(targets[1].kind, "consult")
end)

H.case("_review_path_in_root: containment guard on normalized absolute paths", function()
  local root = "/tmp/proj"
  H.eq(Dispatch._review_path_in_root(root, "/tmp/proj/a.lua"), "a.lua")
  H.eq(Dispatch._review_path_in_root(root, "/tmp/proj/sub/b.lua"), "sub/b.lua")
  H.eq(Dispatch._review_path_in_root(root, "/tmp/proj/../etc/passwd"), nil,
    "traversal collapses outside the root")
  H.eq(Dispatch._review_path_in_root(root, "/etc/passwd"), nil, "absolute-outside refused")
  H.eq(Dispatch._review_path_in_root(root, "/tmp/projx/a.lua"), nil,
    "a sibling directory sharing the prefix is not inside")
  H.eq(Dispatch._review_path_in_root(root, "-leading-dash"), nil,
    "non-absolute (leading-dash) paths refused")
  H.eq(Dispatch._review_path_in_root(root, "/tmp/proj"), nil, "the root itself is not a file")
  H.eq(Dispatch._review_path_in_root(root, nil), nil)
end)

H.case("policy: consults are main-only but run on both specialist types", function()
  local main = { name = "main", chain = {} }
  H.eq(Dispatch.check_policy({ specialist = "x", brief = "b", kind = "consult" }, review_spec, main),
    "consult", "consult a review-type specialist")
  H.eq(Dispatch.check_policy({ specialist = "x", brief = "b", kind = "consult" }, impl_spec, main),
    "consult", "consult an implementation-type specialist")
  local nested = { name = "impl", chain = { { name = "a", kind = "task" } } }
  local ok, err = ok_policy({ specialist = "x", brief = "b", kind = "consult" }, impl_spec, nested)
  H.eq(ok, false)
  H.has(err, "main-only")
  -- even a main-chain implementer (impl-depth 0, allowlisted) cannot consult
  local child = {
    name = "test-engineer",
    chain = { { name = "test-engineer", kind = "task" } },
    delegate = { tasks = { "x" } },
  }
  ok, err = ok_policy({ specialist = "x", brief = "b", kind = "consult" }, impl_spec, child)
  H.eq(ok, false)
  H.has(err, "main-only")
end)
