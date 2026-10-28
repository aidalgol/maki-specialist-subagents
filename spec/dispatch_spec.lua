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
