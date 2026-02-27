local M = {}

-- @type sia.IconSet
local icon_set = "emoji"

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

--- @type sia.Icons
M.icons = setmetatable({}, {
  __index = function(_, key)
    return icon_sets[icon_set][key]
  end,
})

--- Set the active icon set.
--- @param opts {icons: sia.IconSet?}
function M.setup(opts)
  icon_set = opts.icons or "emoji"
end

return M
