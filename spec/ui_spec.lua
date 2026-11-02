-- SPDX-FileCopyrightText: 2026 Aidan Gauland <aidalgol+git@fastmail.net>
--
-- SPDX-License-Identifier: MIT

-- The /specialists window must never claim `keys` on a focused window:
-- maki's open_win rejects `keys` unless `focus = false`, so getting this
-- wrong turns the command into a silent no-op (the thrown error is only
-- logged as a warning by the command runner).

local lu = require("luaunit")

local TestUi = {}

function TestUi:test_win_opts_claims_keys_only_on_unfocused_window()
  local Ui = require("specialist_subagents.ui")
  local opts = Ui.win_opts()
  if opts.keys and #opts.keys > 0 then
    lu.assertEquals(opts.focus, false, "claimed `keys` require `focus = false`")
  end
end

return TestUi
