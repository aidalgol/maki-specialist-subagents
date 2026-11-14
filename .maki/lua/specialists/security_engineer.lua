-- SPDX-FileCopyrightText: 2026 Aidan Gauland <aidalgol+git@fastmail.net>
--
-- SPDX-License-Identifier: MIT

-- Narrowly scoped reviewer of this plugin's privileged surface. Its body
-- encodes the checklist from the security posture section of the plan.
return {
  name = "security-engineer",
  type = "review",
  description = "Reviews the plugin's privileged surface: trust boundaries, privilege grants, argv/path/state injection, budgets.",
  instructions = "security-engineer.md",
  model = { spec = "synthetic/hf:zai-org/GLM-5.3" },
  review = {
    files = {
      "lua/**/*.lua",
      "spec/**/*.lua",
      "plugin.toml",
      ".maki/lua/specialists/*.lua",
    },
  },
}
