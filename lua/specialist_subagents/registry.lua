-- Specialist discovery: glob the two config roots, pcall(require) each
-- definition module, validate, merge (project overrides global by name), and
-- resolve instruction bodies.
--
-- Trust stance: specialist definition modules are config code, the same
-- trust class as any plugin maki loads. Loading goes through require from
-- the config-dir `lua/specialists/` trees; maki sandboxes require per config
-- dir, so when this plugin does not live in the same config dir as the
-- definitions, loading falls back to reading those same two documented roots
-- with maki.fs.read and compiling them with loadstring. Nothing is ever
-- loaded from a path outside `lua/specialists/` in either config root, and
-- no model-controlled input ever reaches the loader.

local M = {}

-- Tolerant require: dotted in maki, file-relative under the luau CLI.
local function req(dotted, sibling)
  local ok, mod = pcall(require, dotted)
  if ok and mod then
    return mod
  end
  return require(sibling)
end

local Spec = req("specialist_subagents.spec", "./spec")

local CATALOG_TTL = 5 -- seconds

local function try_require(module_name)
  local ok, result = pcall(require, module_name)
  if ok then
    return result, nil
  end
  local msg = tostring(result)
  -- Lua 5.1-5.5 say `module 'x' not found:`; maki's sandboxed require may
  -- phrase it without the quotes. A false match is harmless: the caller
  -- re-reads the file and reports the real error.
  if msg:find("module not found", 1, true) or msg:match("module '[^']*' not found") then
    return nil, "not_found"
  end
  return nil, msg
end

local function load_module_file(path)
  local ok, text = pcall(function() return maki.fs.read(path) end)
  if not ok or type(text) ~= "string" then
    return nil, "unreadable: " .. path
  end
  local chunk, err = loadstring(text, "@" .. path)
  if not chunk then
    return nil, "syntax error in " .. path .. ": " .. tostring(err)
  end
  local ok_run, result = pcall(chunk)
  if not ok_run then
    return nil, "error in " .. path .. ": " .. tostring(result)
  end
  return result, nil
end

function M.roots(cwd)
  local project_cfg = maki.fs.joinpath(maki.fs.normalize(cwd), ".maki")
  local global_cfg = maki.env.config_dir()
  if not global_cfg then
    global_cfg = maki.fs.joinpath(maki.uv.os_homedir(), ".config", "maki")
  end
  return {
    project = {
      lua = maki.fs.joinpath(project_cfg, "lua", "specialists"),
      bodies = maki.fs.joinpath(project_cfg, "specialists"),
    },
    global = {
      lua = maki.fs.joinpath(global_cfg, "lua", "specialists"),
      bodies = maki.fs.joinpath(global_cfg, "specialists"),
    },
  }
end

local function valid_stem(stem)
  return type(stem) == "string" and stem:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

-- Discover specialists for a project cwd. Returns (catalog, warnings, errors)
-- where catalog maps name -> normalized spec with `.source` (root kind +
-- path). `errors` are fatal: the plugin refuses to load while any exist.
-- `warnings` stay non-fatal (definition warnings, duplicate names, scan
-- failures).
function M.discover(cwd)
  local roots = M.roots(cwd)
  local catalog = {}
  local warnings = {}
  local errors = {}

  local function scan(root_kind, root, module_prefix)
    local files, err = maki.fs.glob("*.lua", { path = root, gitignore = false })
    if not files then
      if err and not err:find("not found", 1, true) and not err:find("no such", 1, true) then
        warnings[#warnings + 1] = root_kind .. " specialists scan failed: " .. err
      end
      return
    end
    table.sort(files)
    for _, path in ipairs(files) do
      local stem = path:match("([^/]+)%.lua$")
      if not valid_stem(stem) then
        errors[#errors + 1] = string.format(
          "%s: module stem must be a valid require path (letters, digits, underscores)", path)
      else
        local def, load_err
        if module_prefix then
          def, load_err = try_require(module_prefix .. stem)
          if load_err == "not_found" then
            -- plugin lives in a different config dir than this root
            def, load_err = load_module_file(path)
          end
        else
          def, load_err = load_module_file(path)
        end
        if not def then
          errors[#errors + 1] = string.format("%s: %s", path, tostring(load_err))
        else
          local norm, verr, vwarns = Spec.validate(def)
          for _, w in ipairs(vwarns or {}) do
            warnings[#warnings + 1] = path .. ": " .. w
          end
          if not norm then
            errors[#errors + 1] = string.format("%s: %s", path, verr)
          else
            if catalog[norm.name] then
              warnings[#warnings + 1] = string.format(
                "specialist %q defined more than once; %s wins", norm.name, path)
            end
            norm.source = { root = root_kind, path = path }
            catalog[norm.name] = norm
          end
        end
      end
    end
  end

  scan("global", roots.global.lua, "specialists.")
  scan("project", roots.project.lua, "specialists.")

  return catalog, warnings, errors
end

-- Cached catalog; the prompt hint rebuilds it when older than the TTL.
-- Returns (catalog, warnings, errors); see discover().
function M.catalog(cwd, force_refresh)
  M._cache = M._cache or {}
  local cached = M._cache[cwd]
  local now = os.time()
  if force_refresh or not cached or now - cached.at > CATALOG_TTL then
    local cat, warns, errs = M.discover(cwd)
    M._cache[cwd] = { at = now, catalog = cat, warnings = warns, errors = errs }
    cached = M._cache[cwd]
  end
  return cached.catalog, cached.warnings, cached.errors
end

function M.get(cwd, name)
  local catalog = M.catalog(cwd)
  return catalog[name]
end

-- Instruction body: `instructions` file name, project dir then global dir.
function M.read_body(cwd, spec)
  local roots = M.roots(cwd)
  local fname = spec.instructions or (spec.name .. ".md")
  for _, root in ipairs({ roots.project.bodies, roots.global.bodies }) do
    local path = maki.fs.joinpath(root, fname)
    local ok, text = pcall(function() return maki.fs.read(path) end)
    if ok and type(text) == "string" then
      return text, nil, path
    end
  end
  return nil, string.format(
    "instruction body %q not found (looked in %s and %s)", fname,
    roots.project.bodies, roots.global.bodies)
end

-- One-line catalog summary for prompts and /specialists.
function M.summarize(catalog)
  local names = {}
  for name in pairs(catalog) do
    names[#names + 1] = name
  end
  table.sort(names)
  local out = {}
  for _, name in ipairs(names) do
    local s = catalog[name]
    out[#out + 1] = string.format("- %s (%s): %s", s.name, s.type, s.description)
  end
  return table.concat(out, "\n")
end

return M
