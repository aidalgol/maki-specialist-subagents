-- Specialist definition validation and defaults.

local H = require("helpers")
local Spec = require("specialist_subagents.spec")

local function minimal(over)
  local def = {
    name = "sample-reviewer",
    type = "review",
    description = "Reviews samples.",
  }
  for k, v in pairs(over or {}) do
    def[k] = v
  end
  return def
end

H.case("validate: minimal review definition passes with defaults", function()
  local norm, err, warnings = Spec.validate(minimal())
  H.eq(err, nil)
  H.eq(#warnings, 0)
  H.eq(norm.name, "sample-reviewer")
  H.eq(norm.instructions, "sample-reviewer.md")
  H.eq(norm.agents_md, true)
  H.eq(norm.delegate, nil)
  H.eq(norm.review.files, {})
  H.eq(norm.skills, {})
end)

H.case("validate: name format is enforced", function()
  for _, bad in ipairs({ "", "X", "has space", "under_score", "-lead" }) do
    local norm, err = Spec.validate(minimal({ name = bad }))
    H.eq(norm, nil, "name " .. bad .. " must fail")
    H.has(err, "name")
  end
  local norm = Spec.validate(minimal({ name = "scss-reviewer2" }))
  H.truthy(norm)
end)

H.case("validate: type is required and constrained", function()
  H.eq(Spec.validate(minimal({ type = "other" })), nil)
  H.eq(Spec.validate({ name = "x", description = "d" }), nil, "missing type fails")
  H.truthy(Spec.validate(minimal({ type = "implementation" })))
end)

H.case("validate: description required", function()
  H.eq(Spec.validate(minimal({ description = "" })), nil)
  H.eq(Spec.validate({ name = "x", type = "review" }), nil, "missing description fails")
end)

H.case("validate: instructions default and override", function()
  H.eq(Spec.validate(minimal({ instructions = "custom.md" })).instructions, "custom.md")
  H.eq(Spec.validate(minimal({ instructions = "" })).instructions, "sample-reviewer.md")
end)

H.case("validate: model table", function()
  H.eq(Spec.validate(minimal({ model = { tier = "fast" } })).model.tier, "fast")
  H.eq(Spec.validate(minimal({ model = { spec = "m/x" } })).model.spec, "m/x")
  H.eq(Spec.validate(minimal({ model = {} })), nil)
  H.eq(Spec.validate(minimal({ model = "fast" })), nil)
end)

H.case("validate: thinking levels", function()
  H.eq(Spec.validate(minimal({ thinking = "low" })).thinking, "low")
  H.eq(Spec.validate(minimal({ thinking = 2048 })).thinking, 2048)
  H.eq(Spec.validate(minimal({ thinking = "sideways" })), nil)
end)

H.case("validate: tools only/except", function()
  local norm = Spec.validate(minimal({ tools = { except = { "bash" } } }))
  H.eq(norm.tools.except, { "bash" })
  H.eq(Spec.validate(minimal({ tools = { only = { "read" }, except = { "bash" } } })), nil)
  H.eq(Spec.validate(minimal({ tools = { only = "read" } })), nil)
end)

H.case("validate: review.files globs", function()
  local norm = Spec.validate(minimal({ review = { files = { "**/*.md" } } }))
  H.eq(norm.review.files, { "**/*.md" })
  H.eq(Spec.validate(minimal({ review = { files = "**/*.md" } })), nil)
end)

H.case("validate: review type ignores delegate with a warning", function()
  local norm, err, warnings = Spec.validate(minimal({ delegate = { reviews = true } }))
  H.eq(err, nil)
  H.eq(norm.delegate, nil)
  H.eq(#warnings, 1)
  H.has(warnings[1], "delegate is ignored")
end)

H.case("validate: implementation delegate defaults and validation", function()
  local norm = Spec.validate(minimal({ type = "implementation" }))
  H.eq(norm.delegate, { reviews = false, tasks = {} })
  norm = Spec.validate(minimal({
    type = "implementation",
    delegate = { reviews = true, tasks = { "reviewer" } },
  }))
  H.eq(norm.delegate.reviews, true)
  H.eq(norm.delegate.tasks, { "reviewer" })
  H.eq(Spec.validate(minimal({
    type = "implementation", delegate = { reviews = "yes" },
  })), nil)
  H.eq(Spec.validate(minimal({
    type = "implementation", delegate = { tasks = { 1 } },
  })), nil)
end)

H.case("validate: max_iterations", function()
  H.eq(Spec.validate(minimal({ max_iterations = 2 })).max_iterations, 2)
  H.eq(Spec.validate(minimal({ max_iterations = 0 })), nil)
  H.eq(Spec.validate(minimal({ max_iterations = 2.5 })), nil)
  H.eq(Spec.validate(minimal({ max_iterations = "3" })), nil)
end)

H.case("validate: skills", function()
  H.eq(Spec.validate(minimal({ skills = { "maki-plugin-dev" } })).skills, { "maki-plugin-dev" })
  H.eq(Spec.validate(minimal({ skills = { 1 } })), nil)
end)

H.case("validate: agents_md", function()
  H.eq(Spec.validate(minimal({ agents_md = false })).agents_md, false)
end)

H.case("iteration_cap falls back to the config default", function()
  local norm = Spec.validate(minimal())
  H.eq(Spec.iteration_cap(norm, 3), 3)
  norm = Spec.validate(minimal({ max_iterations = 5 }))
  H.eq(Spec.iteration_cap(norm, 3), 5)
end)

H.case("validate: non-table input", function()
  H.eq(Spec.validate("nope"), nil)
  H.eq(Spec.validate(nil), nil)
end)
