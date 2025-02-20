local M = {}
local providers = require("sia.provider")

--- @alias sia.config.Role "user"|"system"|"assistant"|"tool"
--- @alias sia.config.Placement ["below"|"above", "start"|"end"|"cursor"]|"start"|"end"|"cursor"
--- @alias sia.config.ActionInput "require"|"ignore"
--- @alias sia.config.ActionMode "split"|"diff"|"insert"|"hidden"

--- @class sia.config.Insert
--- @field placement (fun():sia.config.Placement)|sia.config.Placement
--- @field cursor ("start"|"end")?
--- @field message [string, string]?

--- @class sia.config.Diff
--- @field wo [string]?
--- @field cmd string?

--- @class sia.config.Split
--- @field cmd string?
--- @field block_action (string|sia.BlockAction)?
--- @field automatic_block_action boolean?
--- @field wo table<string, any>?

--- @class sia.config.Hidden
--- @field callback (fun(ctx:sia.Context, content:string[]):nil)?
--- @field messages { on_start: string?, on_progress: string[]? }?

--- @class sia.config.Replace
--- @field highlight string
--- @field timeout number?

--- @class sia.config.Instruction
--- @field id (fun(ctx:sia.Context?):table?)|nil
--- @field role sia.config.Role
--- @field persistent boolean?
--- @field available (fun(ctx:sia.Context?):boolean)?
--- @field hide boolean?
--- @field description ((fun(ctx:sia.Context?):string)|string)?
--- @field content ((fun(ctx: sia.Context?):string)|string|string[])?
--- @field tool_calls sia.ToolCall[]?
--- @field _tool_call_id string?

--- @class sia.config.Tool
--- @field name string
--- @field description string
--- @field parameters table<string, sia.ToolParameter>
--- @field required string[]?
--- @field execute fun(args:table, strategy: sia.Strategy, callback: fun(content: string[]?, confirmation: {description: string[]}?)):nil

--- @class sia.config.Action
--- @field instructions (string|sia.config.Instruction|(fun():sia.config.Instruction[]))[]
--- @field modify_instructions (fun(instructions:(string|sia.config.Instruction|(fun():sia.config.Instruction[]))[], ctx: sia.ActionArgument):nil)?
--- @field reminder (string|sia.config.Instruction)?
--- @field tools sia.config.Tool[]?
--- @field model string?
--- @field temperature number?
--- @field input sia.config.ActionInput?
--- @field mode sia.config.ActionMode?
--- @field enabled (fun():boolean)|boolean?
--- @field capture nil|(fun(arg: sia.ActionArgument):[number, number])
--- @field range boolean?
--- @field insert sia.config.Insert?
--- @field diff sia.config.Diff?
--- @field split sia.config.Split?
--- @field hidden sia.config.Hidden?

--- @class sia.config.Defaults
--- @field model string
--- @field temperature number
--- @field actions table<"diff"|"split"|"insert", sia.config.Action>
--- @field split sia.config.Split
--- @field replace sia.config.Replace
--- @field diff sia.config.Diff
--- @field insert sia.config.Insert
--- @field hidden sia.config.Hidden

--- @alias sia.config.Models table<string, [string, string]>

--- @class sia.config.Provider
--- @field base_url string
--- @field api_key fun():string?

--- @class sia.config.Options
--- @field models sia.config.Models
--- @field instructions table<string, sia.config.Instruction|sia.config.Instruction[]>
--- @field defaults sia.config.Defaults
--- @field actions table<string, sia.config.Action>
--- @field providers table<string, sia.config.Provider>
--- @field report_usage boolean?
M.options = {}

--- @type sia.config.Options
local defaults = {
  providers = {
    openai = providers.openai,
    copilot = providers.copilot,
    gemini = providers.gemini,
  },
  models = {
    ["gpt-4o"] = { "openai", "gpt-4o", cost = { completion_tokens = 0.00001, prompt_tokens = 0.0000025 } },
    ["gpt-4o-mini"] = { "openai", "gpt-4o-mini", cost = { completion_tokens = 0.00000015, prompt_tokens = 0.0000006 } },
    ["o3-mini"] = {
      "openai",
      "o3-mini",
      reasoning_effort = "medium",
      cost = { completion_tokens = 0.0000044, prompt_tokens = 0.0000011 },
    },
    ["o3-mini-low"] = {
      "openai",
      "o3-mini",
      reasoning_effort = "low",
      cost = { completion_tokens = 0.0000044, prompt_tokens = 0.0000011 },
    },
    ["o3-mini-high"] = {
      "openai",
      "o3-mini",
      reasoning_effort = "high",
      cost = { completion_tokens = 0.0000044, prompt_tokens = 0.0000011 },
    },
    ["chatgpt-4o-latest"] = { "openai", "chatgpt-4o-latest" },
    ["copilot-gpt-4o"] = { "copilot", "gpt-4o" },
    ["copilot-sonnet-3.5"] = { "copilot", "claude-3.5-sonnet" },
    ["copilot-o3-mini"] = { "copilot", "o3-mini", reasoning_effort = "medium" },
    ["gemini-1.5-flash-8b"] = { "gemini", "gemini-1.5-flash-8b" },
    ["gemini-1.5-flash"] = { "gemini", "gemini-1.5-flash" },
    ["gemini-2.0-flash-exp"] = { "gemini", "gemini-2.0-flash-exp" },
    ["gemini-1.5-pro"] = { "gemini", "gemini-1.5-pro" },
  },
  instructions = {},
  --- @type sia.config.Defaults
  defaults = {
    model = "gpt-4o-mini", -- default
    temperature = 0.3, -- default temperature
    prefix = 1, -- prefix lines in insert
    suffix = 0, -- suffix lines in insert
    split = {
      cmd = "vsplit",
      wo = { wrap = true },
      block_action = "verbatim",
      automatic_block_action = false,
    },
    hidden = {
      messages = {},
    },
    diff = {
      cmd = "vsplit",
      wo = { "wrap", "linebreak", "breakindent", "breakindentopt", "showbreak" },
    },
    insert = {
      placement = "cursor",
    },
    replace = {
      highlight = "SiaDiffAdd",
      timeout = 300,
    },
    actions = {
      insert = {
        mode = "insert",
        temperature = 0.2,
        instructions = {
          "insert_system",
          "current_buffer",
        },
      },
      diff = {
        mode = "diff",
        temperature = 0.2,
        instructions = {
          "diff_system",
          require("sia.instructions").current_buffer({ fences = false }),
          require("sia.instructions").current_context({ fences = false }),
        },
      },
      --- @type sia.config.Action
      split = {
        mode = "split",
        temperature = 0.1,
        split = {
          block_action = "search_replace",
        },
        tools = {
          require("sia.tools").add_file,
          require("sia.tools").find_lsp_symbol,
        },
        instructions = {
          "editblock_system",
          "git_files",
          require("sia.instructions").files,
          "current_context",
        },
        reminder = "editblock_reminder",
      },
    },
  },
  actions = {
    edit = require("sia.actions").edit(),
    diagnostic = require("sia.actions").diagnostic(),
    commit = require("sia.actions").commit(),
    review = require("sia.actions").review(),
    explain = require("sia.actions").explain(),
    unittest = require("sia.actions").unittest(),
    doc = require("sia.actions").doc(),
    fix = require("sia.actions").fix(),
  },
  report_usage = true,
}

function M.setup(options)
  M.options = vim.tbl_deep_extend("force", {}, defaults, options or {})
end

return M
