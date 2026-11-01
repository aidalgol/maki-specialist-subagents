-- SPDX-FileCopyrightText: 2026 Aidan Gauland <aidalgol+git@fastmail.net>
--
-- SPDX-License-Identifier: MIT

-- Git plumbing for review fingerprints, plus the content hash used outside
-- git repos. All process execution goes through maki.fn.jobstart with fixed
-- argv arrays (never shell strings) and a git subcommand allowlist; derived
-- paths are always passed after `--` and rejected when they start with a dash
-- or contain `..` segments. This channel runs unprompted on the plugin's own
-- `run` grant, so it stays git-only, permanently.

local M = {}

-- ---------------------------------------------------------------------------
-- Pure helpers (unit-tested without maki)
-- ---------------------------------------------------------------------------

local band, bxor, rshift
if bit32 then
  band, bxor, rshift = bit32.band, bit32.bxor, bit32.rshift
else
  -- pure-Lua 32-bit fallback so the hashing core runs on any Lua (the luau
  -- host ships bit32; this keeps the module testable and portable)
  local MASK = 0xFFFFFFFF
  function band(a, b)
    local r, bit = 0, 1
    for _ = 1, 32 do
      if a % 2 == 1 and b % 2 == 1 then
        r = r + bit
      end
      a = math.floor(a / 2)
      b = math.floor(b / 2)
      bit = bit * 2
    end
    return r % (MASK + 1)
  end
  function bxor(a, b)
    local r, bit = 0, 1
    for _ = 1, 32 do
      if (a % 2) ~= (b % 2) then
        r = r + bit
      end
      a = math.floor(a / 2)
      b = math.floor(b / 2)
      bit = bit * 2
    end
    return r
  end
  function rshift(a, n)
    return math.floor(a / (2 ^ n)) % (MASK + 1)
  end
end

local function fnv1a_32(data, basis)
  local h = basis
  for i = 1, #data do
    h = bxor(h, data:byte(i))
    h = band(h * 16777619, 0xFFFFFFFF)
  end
  return h
end

-- 64-bit FNV-1a via two 32-bit lanes with different bases; Luau numbers are
-- doubles, so the lanes stay separate and render as 16 hex digits.
function M.fnv1a(data)
  if not bxor then
    error("bit32 library is required for hashing", 2)
  end
  local hi = fnv1a_32(data, 2166136261)
  local lo = fnv1a_32(data, 3184587111)
  return string.format("%08x%08x", hi, lo)
end

-- Parse `git status --porcelain -z --untracked-files=all` output. Returns
-- entries { path, untracked } sorted by path (both sides of renames included).
function M.parse_porcelain(ztext)
  local entries = {}
  if not ztext or ztext == "" then
    return entries
  end
  local fields = {}
  local pos = 1
  while pos <= #ztext do
    local nul = ztext:find("\0", pos, true)
    if not nul then
      fields[#fields + 1] = ztext:sub(pos)
      break
    end
    fields[#fields + 1] = ztext:sub(pos, nul - 1)
    pos = nul + 1
  end
  for _, field in ipairs(fields) do
    if #field > 3 and field:byte(3) == 32 then
      local status = field:sub(1, 2)
      local path = field:sub(4)
      local untracked = status:sub(1, 1) == "?"
      entries[#entries + 1] = { path = path, untracked = untracked }
      if status:find("[RC]") then
        -- rename/copy pairs continue with the original path in the next field
        entries[#entries].paired = true
      end
    elseif #field > 0 then
      -- the rename/copy source belongs to the previous entry
      entries[#entries + 1] = { path = field, untracked = false }
    end
  end
  table.sort(entries, function(a, b) return a.path < b.path end)
  return entries
end

-- Pure validation of a model-supplied relative path: dash rejection and
-- `..`-segment rejection before any git or fs use. Returns (relpath, error).
function M.validate_relpath(raw)
  if type(raw) ~= "string" or raw == "" then
    return nil, "path must be a non-empty string"
  end
  if raw:sub(1, 1) == "-" then
    return nil, "path must not start with a dash: " .. raw
  end
  local rel = raw:gsub("\\", "/")
  rel = rel:gsub("^%./", "")
  for seg in rel:gmatch("[^/]+") do
    if seg == ".." then
      return nil, "path escapes the project root: " .. raw
    end
  end
  if rel == "" then
    return nil, "path is empty after normalization: " .. raw
  end
  return rel, nil
end

-- Normalize a model-supplied path against the project root and reject
-- traversal. Returns (absolute path, error, project-relative path).
function M.sanitize_path(project_root, raw)
  local rel, err = M.validate_relpath(raw)
  if not rel then
    return nil, err
  end
  local root = maki.fs.normalize(project_root)
  local abs = maki.fs.normalize(maki.fs.joinpath(root, rel))
  return abs, nil, rel
end

-- Fingerprint = hash(base commit ++ path ++ diff-or-content hash).
function M.compose_fingerprint(base_oid, relpath, payload_hash)
  return M.fnv1a((base_oid or "no-head") .. "\0" .. relpath .. "\0" .. payload_hash)
end

-- Glob matching for scope filters, claims, and review.files hints.
-- `**` crosses directory separators, `*` and `?` do not.
function M.glob_match(pattern, path)
  if type(pattern) ~= "string" or type(path) ~= "string" then
    return false
  end
  local out = {}
  local i = 1
  while i <= #pattern do
    local c = pattern:sub(i, i)
    if pattern:sub(i, i + 1) == "**" then
      out[#out + 1] = ".*"
      i = i + 2
      if pattern:sub(i, i) == "/" then
        i = i + 1
      end
    elseif c == "*" then
      out[#out + 1] = "[^/]*"
      i = i + 1
    elseif c == "?" then
      out[#out + 1] = "[^/]"
      i = i + 1
    else
      out[#out + 1] = c:match("^[%w_%. ]$") and c or ("%" .. c)
      i = i + 1
    end
  end
  local ok, matched = pcall(function()
    return path:match("^" .. table.concat(out) .. "$") ~= nil
  end)
  return ok and matched or false
end

-- Filter a list of paths by glob patterns (nil or empty keeps everything).
function M.filter_by_globs(paths, globs)
  if not globs or #globs == 0 then
    return paths
  end
  local out = {}
  for _, path in ipairs(paths) do
    for _, g in ipairs(globs) do
      if M.glob_match(g, path) then
        out[#out + 1] = path
        break
      end
    end
  end
  return out
end

-- First catalog glob (from `review.files`) matching a path, for UNCOVERED
-- suggestions; nil when none of the catalog's hints apply.
function M.suggest_for_path(catalog, path)
  local best
  for _, spec in pairs(catalog or {}) do
    for _, g in ipairs(spec.review.files or {}) do
      if M.glob_match(g, path) then
        if not best then
          best = { specialist = spec.name, glob = g }
        end
        break
      end
    end
  end
  return best
end

-- ---------------------------------------------------------------------------
-- maki-backed plumbing
-- ---------------------------------------------------------------------------

local GIT_SUBCOMMANDS = {
  status = true,
  diff = true,
  ["rev-parse"] = true,
  ["hash-object"] = true,
}

local function require_maki()
  if not maki or not maki.fn or not maki.fn.jobstart then
    error("git plumbing requires the maki host", 2)
  end
end

-- Fixed argv, git subcommand allowlist, `--` before derived paths.
function M.run_git(cwd, args, timeout_ms)
  require_maki()
  if type(args) ~= "table" or #args == 0 then
    return nil, "git args must be a non-empty array"
  end
  if not GIT_SUBCOMMANDS[args[1]] then
    return nil, "git subcommand not allowed: " .. tostring(args[1])
  end
  local argv = { "git", "-C", cwd }
  for _, a in ipairs(args) do
    argv[#argv + 1] = a
  end
  local id, err = maki.fn.jobstart(argv, { cwd = cwd, tail = 0 })
  if not id then
    return nil, err
  end
  local res, wait_err = maki.fn.jobwait(id, timeout_ms or 30000)
  maki.fn.jobforget(id)
  if not res then
    return nil, wait_err
  end
  if res.exit_code ~= 0 then
    local msg = (res.stderr or ""):gsub("%s+$", "")
    if msg == "" then
      msg = "exit code " .. tostring(res.exit_code)
    end
    return nil, msg
  end
  return res.stdout or "", nil
end

function M.is_git_repo(cwd)
  local out, err = M.run_git(cwd, { "rev-parse", "--is-inside-work-tree" })
  return out ~= nil and out:find("true", 1, true) ~= nil, err
end

function M.base_oid(cwd)
  local out, err = M.run_git(cwd, { "rev-parse", "HEAD" })
  if not out then
    return nil, err
  end
  return (out:gsub("%s+$", ""))
end

function M.changed_files(cwd)
  local out, err = M.run_git(cwd, {
    "status", "--porcelain", "-z", "--untracked-files=all",
  })
  if not out then
    return nil, err
  end
  return M.parse_porcelain(out)
end

function M.file_diff(cwd, relpath)
  local rel = M.validate_relpath(relpath)
  if not rel then
    return ""
  end
  return M.run_git(cwd, { "diff", "HEAD", "--", rel }) or ""
end

function M.content_hash(cwd, abspath)
  if maki.fn.executable("git") then
    local out, err = M.run_git(cwd, { "hash-object", "--", abspath })
    if out then
      return (out:gsub("%s+$", ""))
    end
  end
  local text = maki.fs.read(abspath)
  if not text then
    return "unreadable"
  end
  return M.fnv1a(text)
end

-- Fingerprint one changed file. `untracked` files and files in non-git dirs
-- hash content; tracked files hash their diff against HEAD.
function M.fingerprint_file(cwd, relpath, base_oid, untracked)
  local abs, err, rel = M.sanitize_path(cwd, relpath)
  if not abs then
    return nil, err
  end
  rel = rel or relpath
  local payload
  if base_oid and not untracked then
    local diff = M.file_diff(cwd, rel)
    payload = M.fnv1a(diff or "")
  else
    payload = M.content_hash(cwd, abs)
  end
  return M.compose_fingerprint(base_oid, rel, payload), nil, rel
end

-- Full snapshot for a review scope: per-file fingerprints for the changed
-- files selected by `files` (nil selects every changed file). Returns
-- { base_oid, files = { { path, fingerprint, untracked } }, git = bool }.
function M.changed_snapshot(cwd, files)
  local snap = { base_oid = nil, files = {}, git = false }
  local is_git = M.is_git_repo(cwd)
  snap.git = is_git
  if is_git then
    snap.base_oid = M.base_oid(cwd)
  end
  local changed = nil
  if is_git then
    changed = M.changed_files(cwd)
    if not changed then
      snap.git = false
    end
  end
  local selected_set = nil
  if files and #files > 0 then
    selected_set = {}
    for _, raw in ipairs(files) do
      local abs = M.sanitize_path(cwd, raw)
      if abs then
        selected_set[abs] = true
      end
    end
  end
  local candidates = changed
  if not candidates then
    -- non-git dir or explicit file list: hash the listed (or globbed) content
    if selected_set then
      candidates = {}
      for abs in pairs(selected_set) do
        candidates[#candidates + 1] = abs
      end
      table.sort(candidates, function(a, b) return a < b end)
    else
      local globbed = maki.fs.glob("**/*", { path = cwd, gitignore = true, limit = 2000 })
      candidates = globbed or {}
      table.sort(candidates, function(a, b) return a < b end)
    end
  end
  for _, entry in ipairs(candidates) do
    local path, untracked
    if type(entry) == "table" then
      path, untracked = entry.path, entry.untracked
    else
      path, untracked = entry, true
    end
    local abs = path
    if not abs:find("^/") then
      abs = maki.fs.normalize(maki.fs.joinpath(cwd, path))
    end
    if not selected_set or selected_set[abs] then
      local fp, ferr, rel = M.fingerprint_file(cwd, path, snap.base_oid, untracked and true or false)
      if fp then
        snap.files[#snap.files + 1] = { path = rel or path, fingerprint = fp, untracked = untracked }
      elseif ferr then
        maki.log.warn("specialist-subagents: fingerprint failed for " .. tostring(path) .. ": " .. ferr)
      end
    end
  end
  return snap
end

return M
