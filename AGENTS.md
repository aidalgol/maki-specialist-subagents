<!--
SPDX-FileCopyrightText: 2026 Aidan Gauland <aidalgol+git@fastmail.net>

SPDX-License-Identifier: MIT
-->

# Working on `specialist-subagents`

Maki plugin providing specialist subagents with harness-enforced delegation
workflows: a two-type (review/implementation) specialist system, nested
delegation, a content-addressed review ledger, and budget caps. This
repository dogfoods the plugin. The four specialists under `.maki/` are
dispatched against changes made here.

## Before finishing

Run `prettier --check README.md AGENTS.md`.

Dispatch the relevant area specialists in one `delegate` `targets` call (your
judgment; see `specialist_reviews` for prior coverage). Completion requires
the report's coverage table to show every changed file passing, with no
`UNCOVERED` entries — previously-reviewed content returns instantly from the
ledger.

- `lua-code-reviewer` — Lua: handler error propagation, permission
  declarations, maki API use (`lua/**/*.lua`, `spec/**/*.lua`).
- `security-engineer` — the plugin's privileged surface: trust boundaries,
  privilege grants, argv/path/state injection, budgets.
- `technical-writer` — prose against the red-hat technical writing style
  (`**/*.md`).
- `test-engineer` — authors the LuaUnit specs in `spec/`; delegate test-writing
  to it rather than writing specs by hand.

## Running the tests

```sh
$ lua spec/run.lua
```

Run the LuaUnit suite from the repository root. Note the following
requirements:

- The suite requires plain Lua 5.x.
- Luau's require-by-string refuses this layout: `lua/specialist_subagents.lua`
  beside `lua/specialist_subagents/` is an ambiguous component.
- LuaUnit is vendored in the `external/luaunit` submodule, so clone with
  `--recurse-submodules`.
- No linter or formatter is configured; match the style of the surrounding
  code.

## Conventions

- Run `reuse annotate` on every new file to add an SPDX header.
  - Pass `--license=MIT` for code and markdown, `--license=0BSD` for
    project-config files such as `.editorconfig` and `.gitignore`.
  - Pass `--copyright=''` with your name and email address.
  - Run `reuse annotate --help` for full command usage.
- Put maki-independent logic in pure cores inside
  `lua/specialist_subagents/` (`spec.lua` validation, `ledger.lua`, the
  pure half of `git.lua`, `report.lua`, the `permissions.lua` relay core).
  Cover each core in `spec/*_spec.lua`. Session-bound behaviour is not
  unit-tested; verify it manually against the checklist in README.md
  ("Testing").
- Never edit anything under `external/` — vendored submodules. The
  writing-style skill is symlinked in via `.agents/`.
- The plugin targets Maki >= 0.7.0 and holds `agent`, `fs_read`, `fs_write`,
  `run`, `net`, `session_read`, `session_write` only; it registers no
  permission rules and no pre-approvals. Keep it that way; narrowing
  grants is fine, widening never.
- `.maki/init.lua` loads the plugin project-locally, so it clashes with a
  globally installed copy — do not rely on global config here.
- A specialist definition that fails validation blocks the whole plugin,
  and maki logs where and why. Load-time warnings, such as an unknown key
  or `model.tier` besides `model.spec`, still load. Definitions live in
  `.maki/lua/specialists/*.lua`; their instruction files in
  `.maki/specialists/*.md`.
