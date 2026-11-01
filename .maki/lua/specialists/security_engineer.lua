-- Narrowly scoped reviewer of this plugin's privileged surface. Its body
-- encodes the checklist from the security posture section of the plan.
return {
  name = "security-engineer",
  type = "review",
  description = "Reviews the plugin's privileged surface: trust boundaries, privilege grants, argv/path/state injection, budgets.",
  instructions = "security-engineer.md",
  model = { tier = "strong" },
  thinking = "medium",
  review = {
    files = {
      "lua/**/*.lua",
      "spec/**/*.lua",
      "plugin.toml",
      ".maki/lua/specialists/*.lua",
    },
  },
}
