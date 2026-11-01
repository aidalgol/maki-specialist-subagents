# specialist-subagents

Specialist subagents for [Maki](https://maki.sh) with delegation-workflow
support that goes beyond "just spawn a subagent": a two-type specialist system,
harness-enforced nested delegation, a content-addressed review ledger that
deduplicates reviews, and budgets that make delegation trees safe instead of
forbidden.

## What it gives you

| Tool / command | Audience | Purpose |
|---|---|---|
| `delegate` | main only | Dispatch specialists: one scalar dispatch, or a `targets` list that fans out in parallel and returns one aggregated report. |
| `specialist_reviews` | main + subs | Read-only ledger query: which changed files already have review coverage. |
| `/specialists` | user | Catalog, live invocations, recent coverage. |
| prompt hint (`tool_usage`) | main | Fresh catalog plus delegation guidance, rebuilt every run. |

## Specialist definitions

A specialist is defined by a Lua module and a markdown instruction file, located under either the project-local `.maki/` directory, or the user's global Maki config directory.

- Project: `<project>/.maki/lua/specialists/`
- Global: `~/.config/maki/lua/specialists/`

The basename of the Lua module must be a valid require path, but there is
no restriction on the markdown file. For example, `test_engineer.lua` +
`test-engineer.md` would be valid; `test-engineer.lua` + `test-engineer.md`
would not.

```lua
-- .maki/lua/specialists/scss_reviewer.lua
-- "scss_reviewer" is the stem.
return {
  -- Required. Must be unique and contain only lower alphanumeric characters and dashes.
  name = "scss-reviewer",

  -- Required. May be "review" or "implementation".
  type = "review",

  -- Required. Brief description of the specialist's role.
  description = "Reviews SCSS for selector hygiene, BEM compliance, and dead styles.",

  -- Optional. Name of the instructions file. Defaults to "<name>.md" if not specified.
  instructions = "scss-reviewer.md",

  -- Optional. Specifies a model tier or exact model. Defaults to the parent
  -- model if unspecified.
  model = {
    tier = "weak" -- Clamped to the parent's tier.
    -- spec = "..."  -- Pins one model; wins if both tier and spec are set.
  },

  -- Optional. Capped at the parent's thinking level.
  thinking = "low",

  -- Optional.
  -- `only` and `exclude` are mutually exclusive.
  -- Defaults differ depending on the value of `type`. See below.
  tools = {
    -- Explicitly specify tools available to this specialist.
    only = { "read", "index", "grep", "glob", "list", "bash" }
    -- Exclude certain tools from the defaults.
    -- except = { "..." }
  },

  -- Optional. Advisory only. Indicates to the user which files to which this
  -- specialist applies.
  review = { files = { "**/*.scss" } },

  -- Optional. Caps the fix<->re-review iterations on this specialist's
  -- reviews. Valid for both types.
  max_iterations = 3,

  -- Optional. Omit project instruction files (AGENTS.md etc.) from the base
  -- prompt.
  omit_agents_md = true,

  -- Optional. Skills for this specialist to always load. Valid for both
  -- types.
  skills = { "maki-plugin-dev" },
}
```

One additional field that is valid only when `type = "implementation"`.
```lua
return {
  -- ...

  delegate = {
    -- Allow the specialist to invoke *any* reviewer specialist to review its
    -- changes.
    reviews = true,
    -- Implementation specialists to which the specialist may delegate.
    tasks = { "component-implementer" }
  },
}
```

An invalid definition prevents the plugin from loading, causing Maki to log an
error naming each broken file, with a reason. This is to avoid you wasting time
and tokens in a session with some of your specialists unavailable, when you
thought they would be used.

Non-fatal issues can still occur and allow the plugin to load, but how you
learn of them depends on the kind of issue.

At load, definition problems such as duplicate specialist names and invalid keys
become discovery warnings. `/specialists` lists them under "Discovery warnings",
and the delegation guidance shown to the main agent includes them. Nothing is
written to the log.

At dispatch time, problems with a specialist's environment are logged, such as
a requested skill or instruction file that cannot be found. These surface only
in the log, so a specialist may run without its intended instructions if you do
not check.

Note that because the global specialists definitions are always read, a broken
global specialist disables the plugin in every project.

### Tool defaults

The default tools available to a specialist depends upon the value of the `type`
field in the specialist definition.

#### Review

When `type = "review"`, the specialist has read tools plus `bash` and the web
tools. This is by design, because it is impossible to know ahead of time what
a specialist will need to properly do its job. Maki's permission system is the
security mechanism. You can remove any tools via the specialist table field
`tools.except`.

#### Implementation

When `type = "implementation"`, the specialist has the full `general_sub`
toolset, minus interactive tools, plus the nested `delegate` local tool per the
`delegate` policy. `batch`, `code_execution`, and `task` are always excluded
(their permission cost exceeds this plugin's grants).

## The AGENTS.md gate recipe

Put this in your project's AGENTS.md (or instructions) to make the gate
harness-backed rather than convention-backed:

> Before finishing, dispatch the relevant area specialists in one `delegate`
> `targets` call (your judgment; see `specialist_reviews` for prior
> coverage). Completion requires the report's coverage table to show every
> changed file passing, with no `UNCOVERED` entries — previously-reviewed
> content returns instantly from the ledger.

The gate rides both the dedup and the audit: the model chooses whom to
invoke, and the harness computes what was missed. A final re-review of
unchanged content is a cache hit, so the gate costs nothing the earlier
reviews did not already spend.

## Install

Global config (recommended):

```lua
-- ~/.config/maki/init.lua
maki.pack.add({
  { src = "https://github.com/<you>/specialist-subagents" },
})
```

This repository itself also uses the plugin: four specialists under `.maki/`.

- `lua-code-reviewer`
- `technical-writer`
- `security-engineer`
- `test-engineer`

This means that working on this project with maki installed exercises the whole
pipeline on itself.

## Permissions guidance

`plugin.toml` grants exactly `agent`, `fs_read`, `fs_write`, `run`,
`session_read`, `session_write` — no `net`, no `env`. The plugin never
widens anyone's authority: no pre-approvals, no private execution channels,
zero `register_permission_rule`, zero `set_prompt`. The one seam it wraps is
maki's `permission.prompt` slot, described below: it answers prompts in the
user's name, it never bypasses a deny.

Sub sessions cannot answer permission prompts, so by default a call that
would prompt is denied. Two mechanisms fill that gap:

**Permission relay (default on; `permission_relay = false` disables).** When
a specialist sub session's call would prompt — maki fires the
`permission.prompt` slot for subagent calls too — the plugin opens a small
window next to the chat input in the parent UI: specialist name and kind,
tool, command/input, and the scopes the prompt asks about. Keys:

- `y` — allow once: the call runs, no model round trip.
- `s` — allow for this specialist: remembered in memory until the session
  closes, so a repeated identical call (same tool, same scopes) runs silent.
- `n` (or `Esc`) — deny: the sub receives a guidance message and adapts.

The window waits 55 s; if nobody answers (or it cannot open, e.g. under
`maki -p`), the call is denied with guidance instead of hanging the sub.
Verdicts record no rules host-side, so relays never persist: allow-always
answers live only for the session, and `.maki/permissions.toml` remains the
way to pre-allow recurring commands. Attribution is re-verified against the
live task list on every relay, so a closed session's cache dies with it.
Calls from the main session and from other plugins' subagents pass the layer
untouched, and deny rules and escalated (`ask`) calls never reach it —
nothing here bypasses a deny.

The plugin holds no `net`, so the layer is skipped for `webfetch`/
`websearch` prompts: those keep denying. That is deliberate — the relay
adds no network authority. Pre-allow rules cover the rest:

- file writes by implementation specialists inside the project are
  pre-allowed by maki's builtin `<cwd>/**` rule;
- add project rules (`.maki/permissions.toml`) for the lint and
  static-analysis commands your review specialists run, e.g.
  `ruff *`, `npm run lint*`, `cargo check *` — cheaper than answering the
  relay window on every dispatch.

The plugin's own process execution is a fixed git channel only
(`status`, `diff`, `rev-parse`, `hash-object` via argv arrays); everything a
specialist runs goes through maki's native `bash` tool and its permission
machinery.

## Configuration

```lua
-- optional, from ~/.config/maki/init.lua
require("specialist_subagents").setup({
  max_active = 6,          -- concurrent specialist sessions
  per_turn_budget = 16,    -- delegations per tool call (every target counts)
  review_max_depth = 2,    -- nested review depth cap
  impl_chain_max = 1,      -- implementation delegation depth
  iteration_cap = 3,       -- fix<->re-review rounds per (implementer, reviewer, scope)
  strict_claims = false,   -- reject overlapping path claims instead of warning
  ledger_cap = 500,        -- persisted review ledger entries per project
  permission_relay = true, -- show specialist permission prompts in the parent UI
})
```

The ledger persists under `~/.local/state/maki/specialists/<hash(project
cwd)>/ledger.json`; fingerprints self-invalidate stale entries
semantically.

## Testing

Code that does not need to call into the Maki API is unit-tested in plain Lua
without Maki. The standalone **Lua** interpreter is used because Luau's
require-by-string refuses this repository's layout (the entry file
`lua/specialist_subagents.lua` beside the package directory
`lua/specialist_subagents/` is an ambiguous component), while Lua's
`package.path` require resolves it. Maki's own module loader handles dotted
names, so the suite also runs inside Maki.

```sh
$ lua spec/run.lua
```

The suite uses the same helper API as maki's `maki.test_helpers` (`case`,
`eq`, `has`, `report`); inside Maki the real helper is used, outside it a
local stand-in with identical semantics runs instead.

Live-session behaviour (dispatch, cache hits, joins, nested delegation) requires
manual testing.

1. `/reload` in a project with specialists; check `/specialists` for
   definition warnings.
2. Ask the agent to run `delegate` with `specialist_reviews` first, then a
   review fan-out; confirm parsed verdicts, token costs, and the coverage
   table.
3. Repeat the same review — expect `CACHED REVIEW` with zero session spend.
4. Dispatch an implementation task to `test-engineer`; confirm it lands a
   passing spec in `spec/` and that its local `delegate` tool offers only
   review targets plus its allowlisted tasks.
5. Ask a task-delegated specialist to task-delegate further — expect a
   refusal from the harness, not from a prompt.
6. Run two identical reviews concurrently from two calls — expect one
   `JOINED IN-FLIGHT SESSION` result.
7. Break a definition (introduce a syntax error, for example), `/reload`, and
   confirm maki logs a plugin-load error that names the file and the reason
   while `delegate` is absent; fix the definition, `/reload`, and confirm the
   tool registers again. A definition that only warns (a `model.tier` next to
   a `model.spec`, or an unknown key) still loads the plugin.
