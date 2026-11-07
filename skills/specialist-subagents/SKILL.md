---
name: specialist-subagents
description: >
  Author and maintain specialist definitions for the maki-specialist-subagents
  plugin. Use when the user asks to add or create a specialist, reviewer, or
  subagent; to fix a broken specialist definition; to change what tools or
  model a specialist uses; or asks how to write specialists for the delegate
  tool. Also covers a primer on how the delegate tool invokes specialists:
  dispatch forms, kinds, review scopes, and budget knobs.
---

<!--
SPDX-FileCopyrightText: 2026 Aidan Gauland <aidalgol+git@fastmail.net>

SPDX-License-Identifier: MIT
-->

# Authoring specialist subagents

This skill is for the maki-specialist-subagents plugin, which provides the
`delegate` and `specialist_reviews` tools. It teaches you how to define new
specialists, and how the harness invokes them.

## What specialists are

A specialist is a named subagent that the main agent dispatches through the
`delegate` tool. There are two types:

- **review** — a leaf. It reviews changes and returns a verdict. It has no
  `delegate` tool and cannot dispatch work itself.
- **implementation** — a worker. It can change files and, if its definition
  allows it, can delegate further: reviews of its own changes, or tasks to
  other implementation specialists.

Specialists are discovered from two places:

- Project-local: `<project>/.maki/lua/specialists/`
- Global: `~/.config/maki/lua/specialists/`

The same names are read from both. When a name is defined in both places, the
project-local definition wins and Maki logs a discovery warning.

## File layout

Each specialist is two files. The directory is the same for both types.

| Files | Location | Naming rule |
|---|---|---|
| Lua definition | `.maki/lua/specialists/<stem>.lua` | The stem must be a valid require path: `^[A-Za-z_][A-Za-z0-9_]*$` |
| Instruction file | `.maki/specialists/<name>.md` | Free-form; the `instructions` field points to it |

The instruction file defaults to `<name>.md` — the specialist's `name`, not
the module stem. For example, a module `test_engineer.lua` with
`name = "test-engineer"` defaults to `test-engineer.md`. Instruction files
resolve against the project `.maki/specialists/` directory first, then the
global one.

## Definition schema

The Lua file returns one table. Here is a complete annotated example:

```lua
-- .maki/lua/specialists/scss_reviewer.lua
-- The stem "scss_reviewer" is a valid require path.
return {
  -- Required. Must match ^[a-z0-9][a-z0-9%-]*$ and be unique.
  name = "scss-reviewer",

  -- Required. Either "review" or "implementation".
  type = "review",

  -- Required. Non-empty. This is what the main agent reads when choosing
  -- whom to dispatch, so describe the role and when to use it.
  description = "Reviews SCSS for selector hygiene, BEM compliance, and dead styles.",

  -- Optional. Instruction file name; defaults to "<name>.md".
  instructions = "scss-reviewer.md",

  -- Optional. Defaults to the parent model.
  model = {
    tier = "weak",      -- Clamped to the parent's tier at dispatch time.
    -- spec = "..."     -- Pins one model. If both are set, spec wins and
  },                    -- tier is ignored, with a warning.

  -- Optional. A level name (off, adaptive, minimal, low, medium, high,
  -- xhigh, max) or a token budget (number). Capped at the parent's level.
  thinking = "low",

  -- Optional. `only` and `except` are mutually exclusive. Defaults depend
  -- on `type`; see "Tool defaults" below.
  tools = {
    only = { "read", "index", "grep", "glob", "list", "bash" },
    -- except = { "webfetch", "websearch" },
  },

  -- Optional. Advisory globs shown to users, indicating which files this
  -- specialist applies to.
  review = { files = { "**/*.scss" } },

  -- Optional. Caps the fix <-> re-review rounds for reviews by this
  -- specialist. Valid for both types. Positive integer.
  max_iterations = 3,

  -- Optional. Omit project instruction files (AGENTS.md and similar) from
  -- the specialist's base prompt.
  omit_agents_md = true,

  -- Optional. Skills for this specialist to always load. Valid for both
  -- types.
  skills = { "maki-plugin-dev" },
}
```

One more field, valid only when `type = "implementation"`:

```lua
  -- true lets the specialist have any review specialist review its own
  -- changes. Nested delegation exists for this fix<->re-review loop;
  -- cross-discipline routing is the orchestrator's job (fan-out), so
  -- `kind = "task"` dispatches from a nested session are refused.
  delegate = { reviews = true },
```

On a `review`-type specialist, `delegate` is ignored and produces a discovery
warning: reviewers are leaves by construction.

Unknown keys do not fail validation; they produce a discovery warning and are
ignored.

## Tool defaults

Default tools depend on `type`:

- **review**: read tools (`read`, `index`, `grep`, `glob`, `list`) plus `bash`
  and the web tools. This is deliberately broad — it is impossible to predict
  what a reviewer needs, and Maki's permission system is the security
  mechanism. Narrow it with `tools.except` if a reviewer does not need web
  access.
- **implementation**: the full `general_sub` toolset, minus interactive tools,
  plus a nested `delegate` tool per its `delegate` policy. Over-cost
  containers (`batch`, `code_execution`, `task`) and capability-less
  built-ins (`skill`, `todo_write`, `memory`, `view_image`, `task_stop`,
  `task_message`) are always excluded: either would price the session at
  permissions the plugin's narrow grants do not include. If a session is
  still refused on a tool, the builder retries without it and logs what was
  dropped. `skills = { ... }` still works: bodies are injected at dispatch
  time.

## Failure modes

Problems surface at three different times, and knowing which one applies
saves debugging time:

1. **Validation error (fatal).** A definition that fails schema validation
   prevents the plugin from loading everywhere: `delegate` and
   `specialist_reviews` do not register, and Maki logs an error naming each
   broken file and reason. Because global definitions are always read, one
   broken *global* definition disables the plugin in *every* project.
2. **Discovery warnings (non-fatal).** Duplicate names, unknown keys, and
   ignored fields. These appear under "Discovery warnings" in the
   `/specialists` command output and in the delegation guidance shown to the
   main agent. Nothing is written to the log.
3. **Dispatch-time environment problems.** A missing instruction file or a
   skill that cannot be found is logged at dispatch time only. A specialist
   can run without its intended instructions if nobody checks the log.

After writing or changing a definition, verify it. See the checklist at the
end of this skill.

## Writing the instruction file

A specialist's prompt is built from the definition fields, the instruction
file, the project's AGENTS.md files (unless `omit_agents_md = true`), and any
skills named in the definition's `skills` field. Nothing else is injected. A
specialist has read tools and can open the project's README or other docs,
but nothing tells it they exist. Make the file self-contained: spell out
what the specialist must know rather than relying on ambient project
documentation. Cover:

- **Role.** One short paragraph: what this specialist is and what it owns.
- **Scope.** What to check, and what is out of scope. For reviewers, keep the
  globs in `review.files` consistent with the scope you describe here.
- **Report format.** Say what a report must contain. Review reports need a
  verdict, a coverage table over the changed files, and explicit `UNCOVERED`
  lines for changed files the scope did not cover — the harness audits
  coverage against that table.
- **Style.** Imperative and concise. Specialists are workers, not conversationalists.

## Delegate primer

Knowing how the harness invokes a specialist helps you write a definition it
can live within:

- **Dispatch forms.** A scalar dispatch sends one brief to one specialist. A
  `targets` list fans out in parallel and returns one aggregated report. Use
  one `targets` call instead of several sequential calls when several
  independent specialists apply.
- **Kinds.** `kind = "review"` runs an implementation specialist in review
  mode; `kind = "task"` delegates implementation work; `kind = "consult"`
  asks for judgement, with no review contract and nothing recorded in the
  ledger.
- **Review scopes.** `scope.basis` is `changed` (the changed files, the
  default), `plan` (the plan file), or `files` (explicit paths or globs,
  capped at 50 files per review).
- **Path claims.** Task dispatches can declare the path globs they will
  touch. Overlapping claims from active siblings warn, or are rejected when
  `strict_claims` is on.
- **Budgets.** Defaults: `max_active` 6 concurrent sessions per fan-out,
  `per_turn_budget` 16 dispatches per call, review nesting depth 2, and a
  fix-to-re-review iteration cap of 3. Every budget is enforced in the
  dispatch handler, never in prompt text.
- **Nested delegation is review-only.** `kind = "task"` dispatches are
  main-only. Cross-discipline routing (which specialist changes which files)
  is the orchestrator's job: fan out over `targets`. A specialist that finds
  work outside its brief reports the gap back instead of dispatching; a
  delegated specialist may only have its own changes reviewed.
- **Background dispatches.** `background = true` returns a receipt
  immediately; the aggregated report arrives as a message when the fan-out
  completes. Main-only.
- **Coverage queries.** `specialist_reviews` reports which changed files
  already have fresh review coverage. Reviews are content-addressed:
  unchanged content returns the recorded verdict instantly.

## Verification checklist

After writing or changing a specialist definition:

1. `/reload` — pick up the new files.
2. `/specialists` — confirm the specialist appears in the catalog and that
   no discovery warnings name it.
3. Check the maki log for dispatch-time warnings (missing instruction file,
   missing skill).
4. Run one real dispatch and read the report: does the specialist behave as
   its instruction file describes?
