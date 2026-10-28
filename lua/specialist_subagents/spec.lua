-- Specialist definition validation and per-type defaults.
--
-- Pure Lua: no maki global. Registry feeds each discovered module through
-- `validate()`; invalid definitions are skipped with a warning, never crash
-- the plugin.

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

-- Validate one definition module's return value. Returns
-- (normalized, err, warnings); `normalized` is nil when err is set.
function M.validate(def)
  local warnings = {}
  if type(def) ~= "table" then
    return nil, "definition must be a table"
  end
  if not valid_name(def.name) then
    return nil, "name is required and must match [a-z0-9-]+"
  end
  if def.type ~= "review" and def.type ~= "implementation" then
    return nil, "type must be \"review\" or \"implementation\""
  end
  if type(def.description) ~= "string" or #def.description == 0 then
    return nil, "description is required"
  end

  local norm = {
    name = def.name,
    type = def.type,
    description = def.description,
    instructions = type(def.instructions) == "string" and #def.instructions > 0
      and def.instructions or (def.name .. ".md"),
    agents_md = def.agents_md ~= false,
    skills = {},
    review = { files = {} },
  }

  -- model = { tier = ... } or { spec = ... }; tier clamps to the parent at
  -- resolve time, spec pins one model.
  if def.model ~= nil then
    if type(def.model) ~= "table" then
      return nil, "model must be a table { tier = ... } or { spec = ... }"
    end
    if def.model.spec ~= nil then
      if type(def.model.spec) ~= "string" or #def.model.spec == 0 then
        return nil, "model.spec must be a non-empty string"
      end
      norm.model = { spec = def.model.spec }
    elseif def.model.tier ~= nil then
      if type(def.model.tier) ~= "string" then
        return nil, "model.tier must be a string"
      end
      norm.model = { tier = def.model.tier }
    else
      return nil, "model needs a tier or spec field"
    end
  end

  if def.thinking ~= nil then
    if type(def.thinking) == "number" or (type(def.thinking) == "string" and THINKING_LEVELS[def.thinking]) then
      norm.thinking = def.thinking
    else
      return nil, "thinking must be off|adaptive|minimal|low|medium|high|xhigh|max or a token budget"
    end
  end

  if def.tools ~= nil then
    if type(def.tools) ~= "table" then
      return nil, "tools must be a table { only = {...} } or { except = {...} }"
    end
    norm.tools = {}
    if def.tools.only ~= nil then
      if not is_string_array(def.tools.only) then
        return nil, "tools.only must be an array of tool names"
      end
      norm.tools.only = def.tools.only
    end
    if def.tools.except ~= nil then
      if not is_string_array(def.tools.except) then
        return nil, "tools.except must be an array of tool names"
      end
      norm.tools.except = def.tools.except
    end
    if norm.tools.only and norm.tools.except then
      return nil, "tools.only and tools.except are mutually exclusive"
    end
  end

  if def.review ~= nil then
    if type(def.review) ~= "table" then
      return nil, "review must be a table { files = {...} }"
    end
    if def.review.files ~= nil then
      if not is_string_array(def.review.files) then
        return nil, "review.files must be an array of glob strings"
      end
      norm.review.files = def.review.files
    end
  end

  if def.skills ~= nil then
    if not is_string_array(def.skills) then
      return nil, "skills must be an array of skill names"
    end
    norm.skills = def.skills
  end

  if def.max_iterations ~= nil then
    if type(def.max_iterations) ~= "number" or def.max_iterations < 1 or def.max_iterations % 1 ~= 0 then
      return nil, "max_iterations must be a positive integer"
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
        return nil, "delegate must be a table { reviews = bool, tasks = {...} }"
      end
      if def.delegate.reviews ~= nil then
        if type(def.delegate.reviews) ~= "boolean" then
          return nil, "delegate.reviews must be a boolean"
        end
        delegate.reviews = def.delegate.reviews
      end
      if def.delegate.tasks ~= nil then
        if not is_string_array(def.delegate.tasks) then
          return nil, "delegate.tasks must be an array of specialist names"
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
