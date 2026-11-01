-- Knobs for the specialist-subagents plugin.
--
-- Plain table on purpose: maki rejects `register_options` from non-bundled
-- plugins. Override through `require("specialist_subagents.config").setup(opts)`
-- from init.lua, or edit the defaults here.
--
-- Every budget here is a security control, not a UX nicety: it is enforced in
-- dispatch handlers, never in prompt text.

local M = {
  -- Concurrent specialist sessions across one fan-out (semaphore bound on
  -- the gather fan-out; maki.async.join is unusable here, its workers die at
  -- maki.async.run's 60-second cap).
  max_active = 6,
  -- Specialist dispatches allowed per delegate tool call (every target in a
  -- `targets` list counts).
  per_turn_budget = 16,
  -- How deep a review invocation may nest (review chains terminate by
  -- construction: review-only types are leaves without a delegate tool).
  review_max_depth = 2,
  -- Implementation delegation depth: a specialist delegated by a specialist
  -- gets no task-delegation capability at all.
  impl_chain_max = 1,
  -- Default cap on fix<->re-review rounds per (implementer, reviewer, scope);
  -- a reviewer's own `max_iterations` overrides it.
  iteration_cap = 3,
  -- Reject task dispatches whose claims overlap an active sibling claim,
  -- instead of warning.
  strict_claims = false,
  -- Max files one files-basis review may resolve (scope.basis = "files" is
  -- model-supplied explicit paths/globs; the cap keeps a runaway `**/*` from
  -- blowing up briefs and the ledger). Security control, like every budget
  -- here: enforced in the dispatch handler, never in prompt text.
  review_files_cap = 50,
  -- Consult answers are the deliverable, so they get a wider cap than the
  -- 2000-char task summary.
  consult_summary_cap = 4000,
  -- Persisted review ledger LRU cap.
  ledger_cap = 500,
  -- Iteration-cap bookkeeping entries older than this many seconds expire.
  iteration_ttl = 3600,
  -- Relay permission prompts from specialist sub sessions to the user in the
  -- parent UI (permission.prompt layer). Off: sub prompts keep denying.
  permission_relay = true,
}

function M.setup(opts)
  if type(opts) ~= "table" then
    return M
  end
  for k, v in pairs(opts) do
    if M[k] ~= nil and type(v) == type(M[k]) then
      M[k] = v
    end
  end
  return M
end

return M
