-- SPDX-FileCopyrightText: 2026 Aidan Gauland <aidalgol+git@fastmail.net>
--
-- SPDX-License-Identifier: MIT

-- The task-delegated author of this repo's unit tests. Doubles as the
-- canonical "implementation specialist in both roles" example: the
-- orchestrator delegates test authoring (kind = "task"), and anyone can
-- invoke it with kind = "review" over test changes authored by someone else.
-- delegate.reviews lets it nested-delegate fresh specs to lua-code-reviewer.
return {
  name = "test-engineer",
  type = "implementation",
  description = "Authors the LuaUnit unit tests for the pure cores in spec/, run from the repo root with `lua spec/run.lua`.",
  instructions = "test-engineer.md",
  model = { spec = "synthetic/hf:zai-org/GLM-5.3" },
  review = { files = { "spec/**" } },
  delegate = { reviews = true },
  max_iterations = 3,
  skills = { "maki-plugin-dev" },
}
