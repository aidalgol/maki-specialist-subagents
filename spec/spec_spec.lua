-- SPDX-FileCopyrightText: 2026 Aidan Gauland <aidalgol+git@fastmail.net>
--
-- SPDX-License-Identifier: MIT

-- Specialist definition validation and defaults.

local lu = require("luaunit")

local TestSpec = {}
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

function TestSpec:test_validate_minimal_review_definition_passes_with_defaults()
  local norm, err, warnings = Spec.validate(minimal())
  lu.assertEquals(err, nil)
  lu.assertEquals(#warnings, 0)
  lu.assertEquals(norm.name, "sample-reviewer")
  lu.assertEquals(norm.instructions, "sample-reviewer.md")
  lu.assertEquals(norm.omit_agents_md, false)
  lu.assertEquals(norm.delegate, nil)
  lu.assertEquals(norm.review.files, {})
  lu.assertEquals(norm.skills, {})
end

function TestSpec:test_validate_name_format_is_enforced()
  for _, bad in ipairs({ "", "X", "has space", "under_score", "-lead" }) do
    local norm, err = Spec.validate(minimal({ name = bad }))
    lu.assertEquals(norm, nil, "name " .. bad .. " must fail")
    lu.assertStrContains(err, "name")
  end
  local norm = Spec.validate(minimal({ name = "scss-reviewer2" }))
  lu.assertTrue(norm ~= nil)
end

function TestSpec:test_validate_type_is_required_and_constrained()
  lu.assertEquals(Spec.validate(minimal({ type = "other" })), nil)
  lu.assertEquals(Spec.validate({ name = "x", description = "d" }), nil, "missing type fails")
  lu.assertTrue(Spec.validate(minimal({ type = "implementation" })) ~= nil)
end

function TestSpec:test_validate_description_required()
  lu.assertEquals(Spec.validate(minimal({ description = "" })), nil)
  lu.assertEquals(Spec.validate({ name = "x", type = "review" }), nil, "missing description fails")
end

function TestSpec:test_validate_instructions_default_and_override()
  lu.assertEquals(Spec.validate(minimal({ instructions = "custom.md" })).instructions, "custom.md")
  lu.assertEquals(Spec.validate(minimal({ instructions = "" })).instructions, "sample-reviewer.md")
end

function TestSpec:test_validate_model_table()
  local norm, err, warnings = Spec.validate(minimal({ model = { tier = "fast" } }))
  lu.assertEquals(err, nil)
  lu.assertEquals(warnings, {})
  lu.assertEquals(norm.model.tier, "fast")
  norm, err, warnings = Spec.validate(minimal({ model = { spec = "m/x" } }))
  lu.assertEquals(err, nil)
  lu.assertEquals(warnings, {})
  lu.assertEquals(norm.model.spec, "m/x")
  lu.assertEquals(Spec.validate(minimal({ model = {} })), nil)
  lu.assertEquals(Spec.validate(minimal({ model = "fast" })), nil)
end

function TestSpec:test_validate_model_tier_and_spec_together_warns_spec_wins()
  local norm, err, warnings = Spec.validate(minimal({ model = { tier = "fast", spec = "x/y" } }))
  lu.assertEquals(err, nil)
  lu.assertEquals(norm.model, { spec = "x/y" })
  lu.assertEquals(#warnings, 1)
  lu.assertStrContains(warnings[1], "tier is ignored")
end

function TestSpec:test_validate_thinking_levels()
  lu.assertEquals(Spec.validate(minimal({ thinking = "low" })).thinking, "low")
  lu.assertEquals(Spec.validate(minimal({ thinking = 2048 })).thinking, 2048)
  lu.assertEquals(Spec.validate(minimal({ thinking = "sideways" })), nil)
end

function TestSpec:test_validate_tools_only_except()
  local norm = Spec.validate(minimal({ tools = { except = { "bash" } } }))
  lu.assertEquals(norm.tools.except, { "bash" })
  lu.assertEquals(Spec.validate(minimal({ tools = { only = { "read" }, except = { "bash" } } })), nil)
  lu.assertEquals(Spec.validate(minimal({ tools = { only = "read" } })), nil)
end

function TestSpec:test_validate_review_files_globs()
  local norm = Spec.validate(minimal({ review = { files = { "**/*.md" } } }))
  lu.assertEquals(norm.review.files, { "**/*.md" })
  lu.assertEquals(Spec.validate(minimal({ review = { files = "**/*.md" } })), nil)
end

function TestSpec:test_validate_review_type_ignores_delegate_with_a_warning()
  local norm, err, warnings = Spec.validate(minimal({ delegate = { reviews = true } }))
  lu.assertEquals(err, nil)
  lu.assertEquals(norm.delegate, nil)
  lu.assertEquals(#warnings, 1)
  lu.assertStrContains(warnings[1], "delegate is ignored")
end

function TestSpec:test_validate_implementation_delegate_defaults_and_validation()
  local norm, err, warnings = Spec.validate(minimal({ type = "implementation" }))
  lu.assertEquals(err, nil)
  lu.assertEquals(norm.delegate, { reviews = false })
  norm = Spec.validate(minimal({
    type = "implementation",
    delegate = { reviews = true },
  }))
  lu.assertEquals(err, nil)
  lu.assertEquals(norm.delegate.reviews, true)
  lu.assertEquals(Spec.validate(minimal({
    type = "implementation", delegate = { reviews = "yes" },
  })), nil)
  -- Legacy delegate.tasks keys still validate, warn as unknown keys, and
  -- are dropped from the normalized delegate.
  norm, err, warnings = Spec.validate(minimal({
    type = "implementation",
    delegate = { tasks = { "reviewer" } },
  }))
  lu.assertEquals(err, nil)
  lu.assertEquals(norm.delegate, { reviews = false })
  lu.assertEquals(norm.delegate.tasks, nil)
  lu.assertEquals(#warnings, 1)
  lu.assertStrContains(warnings[1], "delegate.tasks")
end

function TestSpec:test_validate_max_iterations()
  lu.assertEquals(Spec.validate(minimal({ max_iterations = 2 })).max_iterations, 2)
  lu.assertEquals(Spec.validate(minimal({ max_iterations = 0 })), nil)
  lu.assertEquals(Spec.validate(minimal({ max_iterations = 2.5 })), nil)
  lu.assertEquals(Spec.validate(minimal({ max_iterations = "3" })), nil)
end

function TestSpec:test_validate_skills()
  lu.assertEquals(Spec.validate(minimal({ skills = { "maki-plugin-dev" } })).skills, { "maki-plugin-dev" })
  lu.assertEquals(Spec.validate(minimal({ skills = { 1 } })), nil)
end

function TestSpec:test_validate_omit_agents_md()
  lu.assertEquals(Spec.validate(minimal({ omit_agents_md = true })).omit_agents_md, true)
end

function TestSpec:test_validate_unknown_top_level_key_warns_and_is_ignored()
  local norm, err, warnings = Spec.validate(minimal({ instrucions = "typo.md" }))
  lu.assertEquals(err, nil)
  lu.assertEquals(norm.instructions, "sample-reviewer.md")
  lu.assertEquals(#warnings, 1)
  lu.assertStrContains(warnings[1], "unknown key")
  lu.assertStrContains(warnings[1], "instrucions")
end

function TestSpec:test_validate_unknown_nested_tools_key_warns()
  local norm, err, warnings = Spec.validate(minimal({ tools = { only = { "read" }, exclude = { "bash" } } }))
  lu.assertEquals(err, nil)
  lu.assertEquals(norm.tools.only, { "read" })
  lu.assertEquals(#warnings, 1)
  lu.assertStrContains(warnings[1], "tools.exclude")
end

function TestSpec:test_validate_stale_agents_md_key_warns_as_unknown()
  local norm, err, warnings = Spec.validate(minimal({ agents_md = false }))
  lu.assertEquals(err, nil)
  lu.assertEquals(norm.omit_agents_md, false)
  lu.assertEquals(#warnings, 1)
  lu.assertStrContains(warnings[1], "agents_md")
end

function TestSpec:test_validate_unknown_key_warning_survives_a_later_branch_error()
  local norm, err, warnings = Spec.validate(minimal({ instrucions = "typo.md", thinking = "sideways" }))
  lu.assertEquals(norm, nil)
  lu.assertStrContains(err, "thinking")
  lu.assertEquals(#warnings, 1)
  lu.assertStrContains(warnings[1], "instrucions")
end

function TestSpec:test_validate_fully_valid_definition_has_no_warnings()
  local _, err, warnings = Spec.validate(minimal({
    instructions = "custom.md",
    model = { tier = "fast" },
    thinking = "low",
    tools = { only = { "read" } },
    review = { files = { "**/*.md" } },
    max_iterations = 2,
    skills = { "maki-plugin-dev" },
  }))
  lu.assertEquals(err, nil)
  lu.assertEquals(warnings, {})
end

function TestSpec:test_iteration_cap_falls_back_to_the_config_default()
  local norm = Spec.validate(minimal())
  lu.assertEquals(Spec.iteration_cap(norm, 3), 3)
  norm = Spec.validate(minimal({ max_iterations = 5 }))
  lu.assertEquals(Spec.iteration_cap(norm, 3), 5)
end

function TestSpec:test_validate_non_table_input()
  lu.assertEquals(Spec.validate("nope"), nil)
  lu.assertEquals(Spec.validate(nil), nil)
end

return TestSpec
