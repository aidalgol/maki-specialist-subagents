-- Specialist definition validation and per-type defaults.
--
-- Pure Lua: no maki global. Registry feeds each discovered module through
-- `validate()`; a definition that fails validation is a fatal discovery
-- error, softer problems come back as warnings.

local M = {}

local THINKING_LEVELS = {
  off = true, adaptive = true, minimal = true, low = true,
  medium = true, high = true, xhigh = true, max = true,
}

local function is_string_array(v)
  if type(v) ~= "table" then
    return false
  end
  for _, item in ipairs(v) do
    if type(item) ~= "string" then
      return false
    end
  end
  return true
end

local function valid_name(name)
  return type(name) == "string" and name:match("^[a-z0-9][a-z0-9%-]*$") ~= nil
end

-- Unknown keys are reported as warnings and ignored.
local TOP_LEVEL_KEYS = {
  name = true, type = true, description = true, instructions = true,
  model = true, thinking = true, tools = true, review = true, delegate = true,
  max_iterations = true, omit_agents_md = true, skills = true,
}
local MODEL_KEYS = { tier = true, spec = true }
local TOOLS_KEYS = { only = true, except = true }
local REVIEW_KEYS = { files = true }
local DELEGATE_KEYS = { reviews = true, tasks = true }

local function unknown_keys(warnings, name, prefix, tbl, allowed)
  for k in pairs(tbl) do
    if not allowed[k] then
      warnings[#warnings + 1] = string.format(
        "specialist %q: unknown key %q (ignored)", name, prefix .. tostring(k))
    end
  end
end

-- Validate one definition module's return value. Returns
-- (normalized, err, warnings); `normalized` is nil when err is set.
-- Warnings collected so far are returned alongside errors, so an unknown-key
-- warning is not lost when a later branch fails.
function M.validate(def)
  local warnings = {}
  local function fail(msg)
    return nil, msg, warnings
  end
  if type(def) ~= "table" then
    return fail("definition must be a table")
  end
  if not valid_name(def.name) then
    return fail("name is required and must match [a-z0-9-]+")
  end
  if def.type ~= "review" and def.type ~= "implementation" then
    return fail("type must be \"review\" or \"implementation\"")
  end
  if type(def.description) ~= "string" or #def.description == 0 then
    return fail("description is required")
  end

  unknown_keys(warnings, def.name, "", def, TOP_LEVEL_KEYS)

  local norm = {
    name = def.name,
    type = def.type,
    description = def.description,
    instructions = type(def.instructions) == "string" and #def.instructions > 0
      and def.instructions or (def.name .. ".md"),
    omit_agents_md = def.omit_agents_md == true,
    skills = {},
    review = { files = {} },
  }

  -- model = { tier = ... } or { spec = ... }; tier clamps to the parent at
  -- resolve time, spec pins one model.
  if def.model ~= nil then
    if type(def.model) ~= "table" then
      return fail("model must be a table { tier = ... } or { spec = ... }")
    end
    unknown_keys(warnings, def.name, "model.", def.model, MODEL_KEYS)
    if def.model.spec ~= nil then
      if def.model.tier ~= nil then
        warnings[#warnings + 1] = string.format(
          "specialist %q specifies both model.tier and model.spec; tier is ignored (spec pins the model)",
          def.name)
      end
      if type(def.model.spec) ~= "string" or #def.model.spec == 0 then
        return fail("model.spec must be a non-empty string")
      end
      norm.model = { spec = def.model.spec }
    elseif def.model.tier ~= nil then
      if type(def.model.tier) ~= "string" then
        return fail("model.tier must be a string")
      end
      norm.model = { tier = def.model.tier }
    else
      return fail("model needs a tier or spec field")
    end
  end

  if def.thinking ~= nil then
    if type(def.thinking) == "number" or (type(def.thinking) == "string" and THINKING_LEVELS[def.thinking]) then
      norm.thinking = def.thinking
    else
      return fail("thinking must be off|adaptive|minimal|low|medium|high|xhigh|max or a token budget")
    end
  end

  if def.tools ~= nil then
    if type(def.tools) ~= "table" then
      return fail("tools must be a table { only = {...} } or { except = {...} }")
    end
    unknown_keys(warnings, def.name, "tools.", def.tools, TOOLS_KEYS)
    norm.tools = {}
    if def.tools.only ~= nil then
      if not is_string_array(def.tools.only) then
        return fail("tools.only must be an array of tool names")
      end
      norm.tools.only = def.tools.only
    end
    if def.tools.except ~= nil then
      if not is_string_array(def.tools.except) then
        return fail("tools.except must be an array of tool names")
      end
      norm.tools.except = def.tools.except
    end
    if norm.tools.only and norm.tools.except then
      return fail("tools.only and tools.except are mutually exclusive")
    end
  end

  if def.review ~= nil then
    if type(def.review) ~= "table" then
      return fail("review must be a table { files = {...} }")
    end
    unknown_keys(warnings, def.name, "review.", def.review, REVIEW_KEYS)
    if def.review.files ~= nil then
      if not is_string_array(def.review.files) then
        return fail("review.files must be an array of glob strings")
      end
      norm.review.files = def.review.files
    end
  end

  if def.skills ~= nil then
    if not is_string_array(def.skills) then
      return fail("skills must be an array of skill names")
    end
    norm.skills = def.skills
  end

  if def.max_iterations ~= nil then
    if type(def.max_iterations) ~= "number" or def.max_iterations < 1 or def.max_iterations % 1 ~= 0 then
      return fail("max_iterations must be a positive integer")
    end
    norm.max_iterations = def.max_iterations
  end

  if def.type == "review" then
    if def.delegate ~= nil then
      warnings[#warnings + 1] = string.format(
        "specialist %q is a review type; delegate is ignored (reviewers are leaves without a delegate tool)",
        def.name)
    end
    norm.delegate = nil
  else
    local delegate = { reviews = false, tasks = {} }
    if def.delegate ~= nil then
      if type(def.delegate) ~= "table" then
        return fail("delegate must be a table { reviews = bool, tasks = {...} }")
      end
      unknown_keys(warnings, def.name, "delegate.", def.delegate, DELEGATE_KEYS)
      if def.delegate.reviews ~= nil then
        if type(def.delegate.reviews) ~= "boolean" then
          return fail("delegate.reviews must be a boolean")
        end
        delegate.reviews = def.delegate.reviews
      end
      if def.delegate.tasks ~= nil then
        if not is_string_array(def.delegate.tasks) then
          return fail("delegate.tasks must be an array of specialist names")
        end
        delegate.tasks = def.delegate.tasks
      end
    end
    norm.delegate = delegate
  end

  return norm, nil, warnings
end

-- Max fix<->re-review rounds this reviewer accepts; falls back to the
-- iteration_cap knob when the definition does not set one.
function M.iteration_cap(norm, default_cap)
  return norm.max_iterations or default_cap
end

return M
