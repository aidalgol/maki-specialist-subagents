-- Reviews this plugin's own Lua for handler error propagation, permission
-- declarations, and API use. Demonstrates deterministic loading of a builtin
-- skill (maki-plugin-dev).
return {
  name = "lua-code-reviewer",
  type = "review",
  description = "Reviews Lua for maki API misuse, error propagation, permission declarations, and conventions.",
  instructions = "lua-code-reviewer.md",
  model = { tier = "medium" },
  thinking = "low",
  review = { files = { "lua/**/*.lua", "spec/**/*.lua" } },
  skills = { "maki-plugin-dev" },
}
