-- Reviews prose written by any other agent, scoped to markdown. Uses the
-- project skill that ships with this repo (reachable through the .agents/
-- symlink into the external/ submodule).
return {
  name = "technical-writer",
  type = "review",
  description = "Reviews documentation and prose against the red-hat technical writing style.",
  instructions = "technical-writer.md",
  model = { tier = "weak" },
  thinking = "low",
  review = { files = { "**/*.md" } },
  skills = { "red-hat-tech-writing-style" },
}
