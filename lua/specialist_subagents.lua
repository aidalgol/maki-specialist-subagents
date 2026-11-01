-- specialist-subagents: specialist subagents with harness-enforced
-- delegation workflows (nested delegation, review ledger, budgets).
--
-- Registers:
--   delegate           (tool, main audience only) the delegation pipeline
--   specialist_reviews (tool, all audiences) read-only ledger coverage query
--   /specialists       (command) catalog + live invocations + coverage view
--   tool_usage hint    (prompt hint) catalog + delegation guidance
--   permission.prompt  (slot layer) relays specialist sub permission prompts
--                      to the user (see lua/specialist_subagents/permissions.lua)

local Config = require("specialist_subagents.config")
local Dispatch = require("specialist_subagents.dispatch")
local Permissions = require("specialist_subagents.permissions")
local Registry = require("specialist_subagents.registry")
local Report = require("specialist_subagents.report")
local UI = require("specialist_subagents.ui")

local M = {}

function M.setup(opts)
  Config.setup(opts)
  -- Idempotent; also re-run so enabling the relay in setup (after this file
  -- loaded with it disabled) still installs the layer.
  Permissions.install()
  return M
end

-- Eager discovery: a specialist definition that fails to load or validate
-- must fail specialist work before anything is dispatched. The check itself
-- runs deferred: it walks the config dirs with maki.fs.*, which yields, and
-- init.lua loading cannot yield across the C-call boundary. Failing closed
-- does not depend on this gate — the delegate handler and the prompt hint
-- re-run discovery on every use and refuse to dispatch on errors.
do
  local function eager_check()
    local _, _, discovery_errors = Registry.catalog(maki.uv.cwd())
    if #discovery_errors > 0 then
      maki.log.error("specialist-subagents: broken specialist definitions:\n  - "
        .. table.concat(discovery_errors, "\n  - "))
    end
  end
  if type(maki) == "table" and type(maki.defer_fn) == "function" then
    maki.defer_fn(eager_check, 0)
  else
    local ok, err = pcall(eager_check)
    if not ok then
      error("specialist-subagents: discovery check failed: " .. tostring(err), 0)
    end
  end
end

local DELEGATE_SCHEMA = {
  type = "object",
  properties = {
    specialist = {
      type = "string",
      description = "Specialist name (scalar form).",
    },
    brief = {
      type = "string",
      description = "Self-contained brief: task, relevant context, expectations. Reviews get the changed-file list and diff automatically.",
    },
    kind = {
      type = "string",
      enum = { "review", "task", "consult" },
      description = "Dispatch envelope. Defaults to the specialist's type. kind = \"review\" invokes an implementation specialist in review mode. kind = \"consult\" asks a specialist for advice/judgement: no review contract, no ledger, the answer comes back as the report (main-only).",
    },
    scope = {
      type = "object",
      description = "Review scope. files: glob filters over changed files; basis: \"changed\" (default), \"plan\" (review the plan file), or \"files\" (explicit paths/globs resolved against the working tree; review on-disk state, git status ignored).",
      properties = {
        files = { type = "array", items = { type = "string" } },
        basis = { type = "string", enum = { "changed", "plan", "files" } },
      },
    },
    claims = {
      type = "array",
      items = { type = "string" },
      description = "Task dispatches only: path globs this work will touch. Overlap with active sibling claims warns (or refuses under strict_claims).",
    },
    force_review = {
      type = "boolean",
      description = "Re-run a review even when every file in scope already has a fresh ledger entry.",
    },
    targets = {
      type = "array",
      description = "Parallel fan-out form: one pipeline run per entry, bounded by max_active, one aggregated report.",
      items = {
        type = "object",
        properties = {
          specialist = { type = "string" },
          brief = { type = "string" },
          kind = { type = "string", enum = { "review", "task" } },
          scope = {
            type = "object",
            properties = {
              files = { type = "array", items = { type = "string" } },
              basis = { type = "string", enum = { "changed", "plan", "files" } },
            },
          },
          claims = { type = "array", items = { type = "string" } },
          force_review = { type = "boolean" },
        },
        required = { "specialist", "brief" },
      },
    },
  },
}

maki.api.register_tool({
  name = "delegate",
  description = [[Dispatch work to specialist subagents (defined in .maki/lua/specialists/ and ~/.config/maki/lua/specialists/). Scalar form: one specialist; list form: `targets` fans out in parallel and returns one aggregated report.

Use it to delegate reviews of a change set (reviews are content-addressed: unchanged content returns the recorded verdict instantly, and an identical in-flight review is joined instead of duplicated), to delegate implementation tasks to implementation-type specialists, and — with kind = "consult" — to ask a specialist a question (main-only; no review contract, nothing recorded). Every dispatch runs a harness pipeline: cycle/depth/allowlist policy, budgets, path claims, and a review ledger shared across the session.

Prefer one `targets` call over several sequential ones when several independent specialists apply.]],
  schema = DELEGATE_SCHEMA,
  audiences = { "main" },
  permission = "agent",
  kind = "agent",
  annotation = "specialists",
  header = function(input)
    local names = {}
    if type(input) == "table" and type(input.targets) == "table" then
      for _, t in ipairs(input.targets) do
        names[#names + 1] = tostring(t.specialist or "?")
      end
    elseif type(input) == "table" and input.specialist then
      names[1] = tostring(input.specialist)
    end
    local buf = maki.ui.buf()
    buf:line({ { "delegate ", "tool" }, { table.concat(names, ", "), "dim" } })
    return buf
  end,
  handler = function(input, ctx)
    local out, is_err = Dispatch.handle(ctx, input, { name = "main", chain = {} })
    return { llm_output = out, is_error = is_err, format = "plain" }
  end,
})

maki.api.register_tool({
  name = "specialist_reviews",
  description = [[Report which files already have specialist review coverage in the ledger (specialist, verdict, age). Read-only; cheap. Use it before dispatching reviews: files with fresh coverage do not need a new review, and a `delegate` call over them returns cached verdicts instantly.]],
  schema = {
    type = "object",
    properties = {
      files = {
        type = "array",
        items = { type = "string" },
        description = "Glob filters over the changed files (default: all changed files). With basis = \"files\": explicit paths/globs resolved against the working tree.",
      },
      basis = { type = "string", enum = { "changed", "plan", "files" }, description = "Defaults to \"changed\". \"files\": explicit paths/globs resolved against the working tree; on-disk state, git status ignored." },
    },
  },
  audiences = { "main", "general_sub" },
  kind = "search",
  header = function(input)
    local buf = maki.ui.buf()
    buf:line({ { "specialist_reviews", "tool" } })
    return buf
  end,
  handler = function(input)
    local out, is_err = Dispatch.reviews_lookup(nil, input or {})
    return { llm_output = out, is_error = is_err }
  end,
})

maki.api.register_command({
  name = "/specialists",
  description = "Specialist catalog, live invocations, review coverage",
  handler = function()
    UI.show()
  end,
})

maki.api.register_prompt_hint({
  slot = "tool_usage",
  prompt = "system",
  content = function()
    local cwd = maki.uv.cwd()
    local catalog, warnings, errors = Registry.catalog(cwd)
    local lines = {}
    lines[#lines + 1] = "<specialist_delegation>"
    if errors and #errors > 0 then
      -- Unreachable while the load-time check runs first; defense in depth
      -- against any future rescan path.
      maki.log.error("specialist-subagents: broken specialist definitions:\n  - "
        .. table.concat(errors, "\n  - "))
      lines[#lines + 1] = "Specialist discovery FAILED; do not dispatch specialist work:"
      lines[#lines + 1] = "  - " .. table.concat(errors, "\n  - ")
      lines[#lines + 1] = "</specialist_delegation>"
      return table.concat(lines, "\n")
    end
    lines[#lines + 1] = "Specialists available via the delegate tool:"
    local summary = Registry.summarize(catalog)
    if summary ~= "" then
      lines[#lines + 1] = summary
    else
      lines[#lines + 1] = "- (none discovered; check .maki/lua/specialists/)"
    end
    lines[#lines + 1] = table.concat({
      "Guidance:",
      "- Delegate reviews before declaring work complete; run independent specialists in one `targets` call.",
      "- Cached reviews are authoritative: an unchanged file returns its recorded verdict instantly. Use force_review only after the content changed.",
      "- Resolve a report's UNCOVERED lines (changed files no dispatched scope covered) before declaring a review pass; `specialist_reviews` shows prior coverage cheaply.",
      "- Fix<->re-review rounds are capped per specialist and scope; change the content or accept the findings instead of re-dispatching.",
      "- Task dispatches to implementation specialists record path claims; overlapping claims warn (or refuse under strict_claims).",
      "- To review explicit working-tree content (e.g. a clean tree), use scope.basis = \"files\" with explicit paths/globs instead of filtering changed files.",
      "- When you need judgement rather than a diff review, consult instead of forcing a review: kind = \"consult\" asks a specialist a question (main-only; no review contract, nothing recorded).",
    }, "\n")
    if warnings and #warnings > 0 then
      lines[#lines + 1] = "Definition warnings: " .. table.concat(warnings, "; ")
    end
    lines[#lines + 1] = "</specialist_delegation>"
    return table.concat(lines, "\n")
  end,
})

-- The permission relay layer: after the tools above register, per the slot
-- contract set_slot may also be called before the host slot fires. install()
-- is idempotent and a no-op when permission_relay is disabled.
Permissions.install()

return M
