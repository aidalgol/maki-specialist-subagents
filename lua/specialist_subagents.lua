-- specialist-subagents: specialist subagents with harness-enforced
-- delegation workflows (nested delegation, review ledger, budgets).
--
-- Registers:
--   delegate           (tool, main audience only) the delegation pipeline
--   specialist_reviews (tool, all audiences) read-only ledger coverage query
--   /specialists       (command) catalog + live invocations + coverage view
--   tool_usage hint    (prompt hint) catalog + delegation guidance

local Config = require("specialist_subagents.config")
local Dispatch = require("specialist_subagents.dispatch")
local Registry = require("specialist_subagents.registry")
local Report = require("specialist_subagents.report")
local UI = require("specialist_subagents.ui")

local M = {}

function M.setup(opts)
  Config.setup(opts)
  return M
end

-- Eager discovery: a specialist definition that fails to load or validate
-- must stop the plugin here, before any specialist work can start. maki logs
-- the load error at startup and on /reload, and none of the registrations
-- below run, so `delegate`, `specialist_reviews`, the prompt hint, and
-- /specialists are all absent until the definition is fixed.
local _, _, discovery_errors = Registry.catalog(maki.uv.cwd())
if #discovery_errors > 0 then
  error("specialist-subagents: broken specialist definitions:\n  - "
    .. table.concat(discovery_errors, "\n  - "), 0)
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
      enum = { "review", "task" },
      description = "Dispatch envelope. Defaults to the specialist's type. kind = \"review\" invokes an implementation specialist in review mode.",
    },
    scope = {
      type = "object",
      description = "Review scope. files: glob filters over changed files; basis: \"changed\" (default) or \"plan\" (review the plan file).",
      properties = {
        files = { type = "array", items = { type = "string" } },
        basis = { type = "string", enum = { "changed", "plan" } },
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
              basis = { type = "string", enum = { "changed", "plan" } },
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

Use it to delegate reviews of a change set (reviews are content-addressed: unchanged content returns the recorded verdict instantly, and an identical in-flight review is joined instead of duplicated) and to delegate implementation tasks to implementation-type specialists. Every dispatch runs a harness pipeline: cycle/depth/allowlist policy, budgets, path claims, and a review ledger shared across the session.

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
        description = "Glob filters over the changed files (default: all changed files).",
      },
      basis = { type = "string", enum = { "changed", "plan" }, description = "Defaults to \"changed\"." },
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
    }, "\n")
    if warnings and #warnings > 0 then
      lines[#lines + 1] = "Definition warnings: " .. table.concat(warnings, "; ")
    end
    lines[#lines + 1] = "</specialist_delegation>"
    return table.concat(lines, "\n")
  end,
})

return M
