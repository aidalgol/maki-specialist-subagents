-- git.lua pure half: hashing, porcelain parsing, glob matching, path checks.

local lu = require("luaunit")

local TestGit = {}
local Git = require("specialist_subagents.git")

function TestGit:test_fnv1a_deterministic_sensitive_well_formed()
  local a = Git.fnv1a("hello")
  lu.assertEquals(a, Git.fnv1a("hello"))
  lu.assertTrue(a ~= Git.fnv1a("hellp"), "one byte changes the hash")
  lu.assertEquals(#a, 16)
  lu.assertTrue(a:match("^[0-9a-f]+$") ~= nil, "hex output")
  lu.assertEquals(Git.fnv1a(""), Git.fnv1a(""), "empty input is stable")
end

function TestGit:test_parse_porcelain_modified_untracked_staged()
  local entries = Git.parse_porcelain("M  lua/a.lua\0?? notes.md\0A  spec/new.lua\0")
  lu.assertEquals(#entries, 3)
  lu.assertEquals(entries[1].path, "lua/a.lua")
  lu.assertEquals(entries[1].untracked, false)
  lu.assertEquals(entries[2].path, "notes.md")
  lu.assertEquals(entries[2].untracked, true)
  lu.assertEquals(entries[3].path, "spec/new.lua")
  lu.assertEquals(entries[3].untracked, false)
end

function TestGit:test_parse_porcelain_renames_contribute_both_paths()
  local entries = Git.parse_porcelain("R  new.lua\0old.lua\0")
  lu.assertEquals(#entries, 2)
  local paths = {}
  for _, e in ipairs(entries) do
    paths[e.path] = true
  end
  lu.assertTrue(paths["new.lua"] and paths["old.lua"])
end

function TestGit:test_parse_porcelain_empty_and_unsorted_input()
  lu.assertEquals(#Git.parse_porcelain(""), 0)
  lu.assertEquals(#Git.parse_porcelain(nil), 0)
  local entries = Git.parse_porcelain("M  z.lua\0M  a.lua\0")
  lu.assertEquals(entries[1].path, "a.lua", "sorted output")
end

function TestGit:test_glob_match_crosses_separators_does_not()
  lu.assertTrue(Git.glob_match("**/*.lua", "a/b/c.lua"))
  lu.assertTrue(Git.glob_match("**/*.lua", "c.lua"))
  lu.assertEquals(Git.glob_match("*/*.lua", "a/b/c.lua"), false)
  lu.assertTrue(Git.glob_match("*/*.lua", "a/b.lua"))
  lu.assertTrue(Git.glob_match("spec/**", "spec/x/y.lua"))
  lu.assertTrue(Git.glob_match("spec/**", "spec/y.lua"))
  lu.assertEquals(Git.glob_match("spec/**", "specs/x.lua"), false, "no partial segment match")
  lu.assertTrue(Git.glob_match("?.lua", "a.lua"))
  lu.assertEquals(Git.glob_match("?.lua", "ab.lua"), false)
end

function TestGit:test_glob_match_regex_metacharacters_in_patterns_are_literal()
  lu.assertTrue(Git.glob_match("a-b.lua", "a-b.lua"))
  lu.assertTrue(Git.glob_match("x(1).lua", "x(1).lua"))
  lu.assertEquals(Git.glob_match("a(b).lua", "aab).lua"), false)
end

function TestGit:test_validate_relpath_traversal_dashes_backslashes()
  lu.assertEquals(Git.validate_relpath("lua/a.lua"), "lua/a.lua")
  lu.assertEquals(Git.validate_relpath("./lua/a.lua"), "lua/a.lua")
  lu.assertEquals(Git.validate_relpath("a\\b.lua"), "a/b.lua")
  lu.assertEquals(Git.validate_relpath("../escape"), nil)
  lu.assertEquals(Git.validate_relpath("a/../../b"), nil)
  lu.assertEquals(Git.validate_relpath("-flag"), nil)
  lu.assertEquals(Git.validate_relpath(""), nil)
  lu.assertEquals(Git.validate_relpath(42), nil)
end

function TestGit:test_compose_fingerprint_binds_base_path_and_payload()
  local base = Git.compose_fingerprint("oid", "a.lua", "p1")
  lu.assertEquals(base, Git.compose_fingerprint("oid", "a.lua", "p1"))
  lu.assertTrue(base ~= Git.compose_fingerprint("oid2", "a.lua", "p1"))
  lu.assertTrue(base ~= Git.compose_fingerprint("oid", "b.lua", "p1"))
  lu.assertTrue(base ~= Git.compose_fingerprint("oid", "a.lua", "p2"))
  lu.assertTrue(Git.compose_fingerprint(nil, "a.lua", "p") ~= nil, "works without a base commit")
end

function TestGit:test_filter_by_globs_nil_keeps_everything()
  lu.assertEquals(#Git.filter_by_globs({ "a.lua", "b.md" }, nil), 2)
  lu.assertEquals(Git.filter_by_globs({ "a.lua", "b.md" }, { "**/*.lua" }), { "a.lua" })
end

function TestGit:test_suggest_for_path_first_catalog_hint_that_matches()
  local catalog = {
    ["lua-code-reviewer"] = { name = "lua-code-reviewer", review = { files = { "lua/**/*.lua" } } },
    ["technical-writer"] = { name = "technical-writer", review = { files = { "**/*.md" } } },
  }
  local s = Git.suggest_for_path(catalog, "lua/x.lua")
  lu.assertTrue(s ~= nil)
  lu.assertEquals(s.specialist, "lua-code-reviewer")
  lu.assertEquals(Git.suggest_for_path(catalog, "x.unknown"), nil)
end

return TestGit
