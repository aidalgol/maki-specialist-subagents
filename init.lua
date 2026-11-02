-- SPDX-FileCopyrightText: 2026 Aidan Gauland <aidalgol+git@fastmail.net>
--
-- SPDX-License-Identifier: MIT

-- Entry point for the vendored-config flow: maki merges this file into a
-- ~/.config/maki/init.lua, where the require line is all that is needed.
-- Pack-installed packages are entered through plugin/*.lua instead (see
-- plugin/specialist-subagents.lua); maki never runs a package's root
-- init.lua.
require("specialist_subagents")
