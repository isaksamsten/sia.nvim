--- Centralized icon definitions for sia.nvim
---
--- Supports multiple icon sets: "emoji" (default), "nerd" (Nerd Fonts), and "ascii".
--- Users can select which set to use via config: `defaults = { icons = "nerd" }`.

local M = {}

--- @alias sia.IconSet "emoji"|"nerd"|"ascii"

--- @class sia.Icons
--- @field error string
--- @field success string
--- @field started string
--- @field edit string
--- @field save string
--- @field delete string
--- @field insert string
--- @field replace string
--- @field rename string
--- @field search string
--- @field read string
--- @field read_bash string
--- @field read_skill string
--- @field view string
--- @field fetch string
--- @field lsp string
--- @field plan string
--- @field locations string
--- @field diagnostics string
--- @field history string
--- @field directory string
--- @field bash_exec string
--- @field bash_kill string
--- @field papers string
--- @field overloaded string

--- @type table<sia.IconSet, sia.Icons>
local icon_sets = {
  emoji = {
    error = "❌",
    success = "✅",
    started = "🚀",
    edit = "✏️",
    save = "💾",
    delete = "🗑️",
    insert = "📝",
    replace = "✂️",
    rename = "📁",
    search = "🔍",
    read = "📖",
    read_bash = "🖥️",
    read_skill = "🧩",
    view = "👁️",
    fetch = "📄",
    lsp = "🔧",
    plan = "📋",
    locations = "📝",
    diagnostics = "🩺",
    history = "📚",
    directory = "📂",
    bash_exec = "⚡",
    bash_kill = "⊘",
    papers = "📚",
    overloaded = "⏳",
  },
  nerd = {
    error = " ",
    success = " ",
    started = " ",
    edit = " ",
    save = " ",
    delete = " ",
    insert = " ",
    replace = "",
    rename = " ",
    search = " ",
    read = " ",
    read_bash = " ",
    read_skill = " ",
    view = " ",
    fetch = "󰖟 ",
    lsp = " ",
    plan = " ",
    locations = " ",
    diagnostics = " ",
    history = " ",
    directory = " ",
    bash_exec = " ",
    bash_kill = " ",
    papers = " ",
    overloaded = " ",
  },
  ascii = {
    error = "[X]",
    success = "[OK]",
    started = "[>]",
    edit = "[~]",
    save = "[S]",
    delete = "[D]",
    insert = "[+]",
    replace = "[R]",
    rename = "[MV]",
    search = "[?]",
    read = "[R]",
    read_bash = "[$]",
    read_skill = "[SK]",
    view = "[V]",
    fetch = "[F]",
    lsp = "[LSP]",
    plan = "[P]",
    locations = "[L]",
    diagnostics = "[DX]",
    history = "[H]",
    directory = "[DIR]",
    bash_exec = "[!]",
    bash_kill = "[K]",
    papers = "[PA]",
    overloaded = "[..]",
  },
}

--- The single active icon table. Mutated in-place by setup() so that
--- any module that captured a reference via `require("sia.icons").get()`
--- at require-time keeps seeing the correct values after a later setup().
--- @type sia.Icons
local active = vim.tbl_extend("force", {}, icon_sets.emoji)

--- Set the active icon set.
--- @param name sia.IconSet
function M.setup(name)
  local set = icon_sets[name]
  if not set then
    vim.notify(
      string.format("sia.icons: unknown icon set '%s', using 'emoji'", name),
      vim.log.levels.WARN
    )
    set = icon_sets.emoji
  end
  for k in pairs(active) do
    active[k] = nil
  end
  for k, v in pairs(set) do
    active[k] = v
  end
end

--- Get the currently active icon table.
--- The returned table is stable: its identity never changes, only its contents.
--- Safe to capture once at require-time: `local icons = require("sia.icons").get()`.
--- @return sia.Icons
function M.get()
  return active
end

return M
