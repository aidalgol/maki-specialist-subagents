-- SPDX-FileCopyrightText: 2026 Aidan Gauland <aidalgol+git@fastmail.net>
--
-- SPDX-License-Identifier: MIT

-- Package entrypoint. maki runs every plugin/*.lua in a pack-installed
-- package; the module registers everything (delegate, specialist_reviews,
-- /specialists, the prompt hint, the permission relay) at load time.
require("specialist_subagents")
