-- The task-delegated author of this repo's unit tests. Doubles as the
-- canonical "implementation specialist in both roles" example: the
-- orchestrator delegates test authoring (kind = "task"), and anyone can
-- invoke it with kind = "review" over test changes authored by someone else.
-- delegate.reviews lets it nested-delegate fresh specs to lua-code-reviewer.
return {
  name = "test-engineer",
  type = "implementation",
  description = "Authors unit tests for the pure cores in spec/, runnable with the luau CLI.",
  instructions = "test-engineer.md",
  model = { tier = "medium" },
  thinking = "medium",
  review = { files = { "spec/**" } },
  delegate = { reviews = true },
  max_iterations = 3,
  skills = { "maki-plugin-dev" },
}
