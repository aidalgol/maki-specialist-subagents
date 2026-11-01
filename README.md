# specialist-subagents

Specialist subagents for [maki](https://maki.sh) with delegation-workflow
support that goes beyond "just spawn a subagent": a two-type specialist
system, harness-enforced nested delegation, a content-addressed review
ledger that deduplicates reviews, and budgets that make delegation trees
safe instead of forbidden.

## What it gives you

| Tool / command | Audience | Purpose |
|---|---|---|
| `delegate` | main only | Dispatch specialists: one scalar dispatch, or a `targets` list that fans out in parallel and returns one aggregated report. |
| `specialist_reviews` | main + subs | Read-only ledger query: which changed files already have review coverage. |
| `/specialists` | user | Catalog, live invocations, recent coverage. |
| prompt hint (`tool_usage`) | main | Fresh catalog plus delegation guidance, rebuilt every run. |

A registered `delegate` tool is hidden from sub sessions
(`audiences = { "main" }`); nested delegation exists only as per-invoker
`local_tools` closures, so a sub session can never reach the orchestrator's
tool.

## Specialist definitions

Definitions are Lua modules; instruction bodies are standalone markdown
files. Both config roots are globbed, and project definitions override
global ones by `name`:

- Project: `<project>/.maki/lua/specialists/<stem>.lua`, body at
  `<project>/.maki/specialists/<name>.md`
- Global: `~/.config/maki/lua/specialists/<stem>.lua`, body at
  `~/.config/maki/specialists/<name>.md`

The module stem (file basename) must be a valid require path (underscores); the display
`name` may use dashes.

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

A definition that fails to load or validate stops the plugin from loading:
maki logs an error that names each broken file and the reason, and none of
the plugin's tools or commands register. Fix the definition and run
`/reload`. Non-fatal problems (a definition warning, a duplicate name) keep
the plugin loaded; `/specialists` lists them under "Discovery warnings".

Both config roots are scanned, so a broken definition in the global
directory disables the plugin in every project until you fix it.

### Tool defaults

When `type = "review"`, the specialist has read tools plus `bash` and the web
tools: arbitrary commands by design (ruff, stylelint, clippy, `npm run`, project
linters). Safety rests entirely on maki's permission machinery, never on command
vetting here. Strict read-only is one line away: `tools = { except = { "bash"
} }`.

When `type = "implementation"`, the full `general_sub` tool set minus
interactive tools, plus the nested `delegate` local tool per the `delegate`
policy. `batch`, `code_execution`, and `task` are always excluded (their
permission cost exceeds this plugin's grants).

### Dispatch kinds select the envelope

`kind` selects the envelope, not the specialist. `kind = "review"` always
uses the review tool set, the review report contract, fingerprints, and the
ledger, and records no claims — even for implementation-type targets.
`kind = "task"` uses the implementation tool set and records claims. This is
what lets one implementation specialist work in both roles.

`kind = "consult"` asks a specialist a question instead of giving it work.
A consult runs the review tool set regardless of the specialist's type, has
no review contract (no SUMMARY/FINDINGS/VERDICT tail), records nothing in
the ledger, and is main-only — nested delegate tools never offer the kind.
The free-form answer comes back as the report.

### Review scope basis

`scope.basis` selects what a review looks at. `"changed"` (the default)
filters the git-changed set with `scope.files` globs; `"plan"` reviews the
ready plan file. `"files"` resolves `scope.files` as explicit paths or globs
against the working tree (gitignore-respecting), so a clean tree can be
reviewed too — git status is ignored and the on-disk state is what gets
fingerprinted. The set is capped at `review_files_cap` (50) files; entries
matching nothing produce warnings, not failures.

## Delegation model

Every dispatch runs the same pipeline, whether it comes from the
orchestrator tool or a nested local tool:

1. **Policy** — cycle check (a target already in the invocation chain is
   refused), review depth cap, and the task rules: task delegation is
   allowed from main, or from an implementation specialist at impl-depth 0
   whose `delegate.tasks` allowlist names the target. A specialist that was
   itself delegated by a specialist gets **no** task-delegation capability
   (impl chain cap 1) — enforced by which local tools the harness installs,
   never by prompt text.
2. **Budgets** — concurrent sessions (`max_active`), delegations per tool
   call (`per_turn_budget`), and a fix<->re-review iteration cap per
   (implementer, reviewer, scope). All enforced in handlers, never in
   prompt text.
3. **Claims** — task dispatches declare path globs; overlap with an active
   sibling claim warns (or refuses under `strict_claims`).
4. **Review dedup** — fingerprints are `hash(base commit ++ path ++
   diff-or-content hash)`. Unchanged content returns the recorded verdict
   marked `CACHED REVIEW` with no session; partial coverage reviews only the
   unresolved subset; an identical in-flight review is joined and both
   callers receive the same parsed result. `force_review = true` re-runs.
5. **Spawn and report** — a self-contained brief (task, chain trace, and
   for reviews the changed-file list plus diff text), one prompt, lenient
   parsing of the machine-readable tail
   (`SUMMARY:` / `FINDINGS:` / `VERDICT: approve|request-changes`).
   Unparsable tails degrade to raw text and satisfy nothing. Ledger entries
   are written only from parsed results, through one atomic choke point.
6. **Fan-out** — targets run concurrently, bounded by `max_active`; the
   report aggregates per-target sections, summed cost, and the union of
   warnings.

Review-kind reports end with a computed **coverage audit**: changed file ->
reviewing specialist -> verdict, plus an `UNCOVERED` list of changed files
no dispatched scope covered, each annotated with a `review.files` glob
suggestion where one matches. Routing stays the model's judgment; the
harness computes what was missed.

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

or vendor the repo's `lua/`, `init.lua`, and `plugin.toml` into
`~/.config/maki/` and `require("specialist_subagents")` from
`~/.config/maki/init.lua`.

This repository also dogfoods four specialists under `.maki/`
(`lua-code-reviewer`, `technical-writer`, `security-engineer`,
`test-engineer`), so working on this project with maki installed exercises
the whole pipeline on itself.

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

The pure cores (definition validation, ledger semantics, verdict parsing,
git fingerprints, glob matching, policy checks, permission-relay cache and
prompt rendering) are unit-tested without the maki host:

```
cd <repo root> && lua spec/run.lua
```

The suite uses the same helper API as maki's `maki.test_helpers` and runs
inside maki too. Live-session behaviour (dispatch, cache hits, joins,
nested delegation) has a manual checklist:

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

## Known host-behaviour notes

- A parallel `targets` fan-out opens one subagent session per target (verified
  via the log: equal session lifetimes, interleaved API streams). maki's
  tasks view has shown only one of the concurrent specialist tasks; treat the
  log or `/specialists` as the source of truth for live invocations until the
  host UI lists them all.
- Audience gating (`audiences = { "main" }`) hiding `delegate` from sub
  sessions is verified against maki's documented tool-registry semantics and
  the prompt render; verify once from a live nested session on first use.
- If maki refuses a session because a handed-over tool's permission bank
  exceeds the plugin's grants, the session builder retries with the
  over-cost tools dropped and logs a warning.
- Specialist definition modules are config code (the same trust class as
  any project plugin). When this plugin is not installed in the same config
  dir as the definitions, loading falls back to reading those same two
  documented roots and compiling them — never from anywhere else, never
  from model input.
