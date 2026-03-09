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
--- @field view string
--- @field view_bash string
--- @field view_skill string
--- @field workspace string
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
--- @field image string
--- @field document string
--- @field agents string

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
    view = "📖",
    view_bash = "🖥️",
    view_skill = "🧩",
    workspace = "👁️",
    fetch = "📄",
    lsp = "🔧",
    plan = "📋",
    locations = "📝",
    diagnostics = "🩺",
    history = "📚",
    directory = "📂",
    bash_exec = "⚡",
    bash_kill = "⊘",
    image = "🖼️",
    document = "📑",
    agents = "🤖 ",
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
    view = " ",
    view_bash = " ",
    view_skill = " ",
    workspace = " ",
    fetch = "󰖟 ",
    lsp = " ",
    plan = " ",
    locations = " ",
    diagnostics = " ",
    history = " ",
    directory = " ",
    bash_exec = " ",
    bash_kill = " ",
    image = "󰋩 ",
    papers = " ",
    document = "󰈙 ",
    agents = " ",
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
    view = "[R]",
    view_bash = "[$]",
    view_skill = "[SK]",
    workspace = "[W]",
    fetch = "[F]",
    lsp = "[LSP]",
    plan = "[P]",
    locations = "[L]",
    diagnostics = "[DX]",
    history = "[H]",
    directory = "[DIR]",
    bash_exec = "[!]",
    bash_kill = "[K]",
    image = "[IMG]",
    document = "[DOC]",
    agents = "[A]",
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
