-- git.lua pure half: hashing, porcelain parsing, glob matching, path checks.

local H = require("helpers")
local Git = require("specialist_subagents.git")

H.case("fnv1a: deterministic, sensitive, well-formed", function()
  local a = Git.fnv1a("hello")
  H.eq(a, Git.fnv1a("hello"))
  H.truthy(a ~= Git.fnv1a("hellp"), "one byte changes the hash")
  H.eq(#a, 16)
  H.truthy(a:match("^[0-9a-f]+$"), "hex output")
  H.eq(Git.fnv1a(""), Git.fnv1a(""), "empty input is stable")
end)

H.case("parse_porcelain: modified, untracked, staged", function()
  local entries = Git.parse_porcelain("M  lua/a.lua\0?? notes.md\0A  spec/new.lua\0")
  H.eq(#entries, 3)
  H.eq(entries[1].path, "lua/a.lua")
  H.eq(entries[1].untracked, false)
  H.eq(entries[2].path, "notes.md")
  H.eq(entries[2].untracked, true)
  H.eq(entries[3].path, "spec/new.lua")
  H.eq(entries[3].untracked, false)
end)

H.case("parse_porcelain: renames contribute both paths", function()
  local entries = Git.parse_porcelain("R  new.lua\0old.lua\0")
  H.eq(#entries, 2)
  local paths = {}
  for _, e in ipairs(entries) do
    paths[e.path] = true
  end
  H.truthy(paths["new.lua"] and paths["old.lua"])
end)

H.case("parse_porcelain: empty and unsorted input", function()
  H.eq(#Git.parse_porcelain(""), 0)
  H.eq(#Git.parse_porcelain(nil), 0)
  local entries = Git.parse_porcelain("M  z.lua\0M  a.lua\0")
  H.eq(entries[1].path, "a.lua", "sorted output")
end)

H.case("glob_match: ** crosses separators, * does not", function()
  H.truthy(Git.glob_match("**/*.lua", "a/b/c.lua"))
  H.truthy(Git.glob_match("**/*.lua", "c.lua"))
  H.eq(Git.glob_match("*/*.lua", "a/b/c.lua"), false)
  H.truthy(Git.glob_match("*/*.lua", "a/b.lua"))
  H.truthy(Git.glob_match("spec/**", "spec/x/y.lua"))
  H.truthy(Git.glob_match("spec/**", "spec/y.lua"))
  H.eq(Git.glob_match("spec/**", "specs/x.lua"), false, "no partial segment match")
  H.truthy(Git.glob_match("?.lua", "a.lua"))
  H.eq(Git.glob_match("?.lua", "ab.lua"), false)
end)

H.case("glob_match: regex metacharacters in patterns are literal", function()
  H.truthy(Git.glob_match("a-b.lua", "a-b.lua"))
  H.truthy(Git.glob_match("x(1).lua", "x(1).lua"))
  H.eq(Git.glob_match("a(b).lua", "aab).lua"), false)
end)

H.case("validate_relpath: traversal, dashes, backslashes", function()
  H.eq(Git.validate_relpath("lua/a.lua"), "lua/a.lua")
  H.eq(Git.validate_relpath("./lua/a.lua"), "lua/a.lua")
  H.eq(Git.validate_relpath("a\\b.lua"), "a/b.lua")
  H.eq(Git.validate_relpath("../escape"), nil)
  H.eq(Git.validate_relpath("a/../../b"), nil)
  H.eq(Git.validate_relpath("-flag"), nil)
  H.eq(Git.validate_relpath(""), nil)
  H.eq(Git.validate_relpath(42), nil)
end)

H.case("compose_fingerprint: binds base, path, and payload", function()
  local base = Git.compose_fingerprint("oid", "a.lua", "p1")
  H.eq(base, Git.compose_fingerprint("oid", "a.lua", "p1"))
  H.truthy(base ~= Git.compose_fingerprint("oid2", "a.lua", "p1"))
  H.truthy(base ~= Git.compose_fingerprint("oid", "b.lua", "p1"))
  H.truthy(base ~= Git.compose_fingerprint("oid", "a.lua", "p2"))
  H.truthy(Git.compose_fingerprint(nil, "a.lua", "p") ~= nil, "works without a base commit")
end)

H.case("filter_by_globs: nil keeps everything", function()
  H.eq(#Git.filter_by_globs({ "a.lua", "b.md" }, nil), 2)
  H.eq(Git.filter_by_globs({ "a.lua", "b.md" }, { "**/*.lua" }), { "a.lua" })
end)

H.case("suggest_for_path: first catalog hint that matches", function()
  local catalog = {
    ["lua-code-reviewer"] = { name = "lua-code-reviewer", review = { files = { "lua/**/*.lua" } } },
    ["technical-writer"] = { name = "technical-writer", review = { files = { "**/*.md" } } },
  }
  local s = Git.suggest_for_path(catalog, "lua/x.lua")
  H.truthy(s)
  H.eq(s.specialist, "lua-code-reviewer")
  H.eq(Git.suggest_for_path(catalog, "x.unknown"), nil)
end)
