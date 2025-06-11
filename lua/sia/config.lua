local M = {}
local providers = require("sia.provider")

--- @alias sia.config.Role "user"|"system"|"assistant"|"tool"
--- @alias sia.config.Placement ["below"|"above", "start"|"end"|"cursor"]|"start"|"end"|"cursor"
--- @alias sia.config.ActionInput "require"|"ignore"
--- @alias sia.config.ActionMode "chat"|"diff"|"insert"|"hidden"

--- @class sia.config.Insert
--- @field placement (fun():sia.config.Placement)|sia.config.Placement
--- @field cursor ("start"|"end")?
--- @field message [string, string]?

--- @class sia.config.Diff
--- @field wo [string]?
--- @field cmd string?

--- @class sia.config.Chat
--- @field cmd string?
--- @field block_action (string|sia.BlockAction)?
--- @field automatic_block_action boolean?
--- @field wo table<string, any>?

--- @class sia.config.Hidden
--- @field callback (fun(ctx:sia.Context, content:string[]):nil)?
--- @field messages { on_start: string?, on_progress: string[]? }?

--- @class sia.config.Replace
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
--- @field _tool_call sia.ToolCall?
--- @field group integer?

--- @class sia.config.Tool
--- @field name string
--- @field description string
--- @field parameters table<string, sia.ToolParameter>
--- @field required string[]?
--- @field execute fun(args:table, strategy: sia.Conversation, callback: fun(content: string[]?, confirmation: {description: string[]}?)):nil

--- @class sia.config.Action
--- @field system (string|sia.config.Instruction|(fun(i:sia.Conversation?):sia.config.Instruction[]))[]?
--- @field examples (string|sia.config.Instruction|(fun(i:sia.Conversation?):sia.config.Instruction[]))[]?
--- @field instructions (string|sia.config.Instruction|(fun(i:sia.Conversation?):sia.config.Instruction[]))[]
--- @field modify_instructions (fun(instructions:(string|sia.config.Instruction|(fun():sia.config.Instruction[]))[], ctx: sia.ActionContext):nil)?
--- @field reminder (string|sia.config.Instruction)?
--- @field tools sia.config.Tool[]?
--- @field model string?
--- @field temperature number?
--- @field input sia.config.ActionInput?
--- @field mode sia.config.ActionMode?
--- @field enabled (fun():boolean)|boolean?
--- @field capture nil|(fun(arg: sia.ActionContext):[number, number])
--- @field range boolean?
--- @field insert sia.config.Insert?
--- @field diff sia.config.Diff?
--- @field chat sia.config.Chat?
--- @field hidden sia.config.Hidden?

--- @class sia.config.Defaults
--- @field model string
--- @field temperature number
--- @field actions table<"diff"|"chat"|"insert", sia.config.Action>
--- @field chat sia.config.Chat
--- @field replace sia.config.Replace
--- @field diff sia.config.Diff
--- @field insert sia.config.Insert
--- @field hidden sia.config.Hidden
--- @field tools { enable: boolean, choices: table<string, sia.config.Tool[]?>}

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
    anthropic = providers.anthropic,
    ollama = providers.ollama,
  },
  models = {
    ["gpt-4.1"] = { "openai", "gpt-4.1", cost = { completion_tokens = 0.000008, prompt_tokens = 0.000002 } },
    ["gpt-4.1-mini"] = {
      "openai",
      "gpt-4.1-mini",
      cost = { completion_tokens = 0.0000016, prompt_tokens = 0.0000004 },
    },
    ["gpt-4.1-nano"] = { "openai", "gpt-4.1-nano", cost = { completion_tokens = 0.0000004, prompt_tokens = 0.0000001 } },
    ["gpt-4o"] = { "openai", "gpt-4o", cost = { completion_tokens = 0.00001, prompt_tokens = 0.0000025 } },
    ["gpt-4o-mini"] = { "openai", "gpt-4o-mini", cost = { completion_tokens = 0.00000015, prompt_tokens = 0.0000006 } },
    ["o3"] = { "openai", "o3", reasoning_effort = "medium" },
    ["o4-mini"] = { "openai", "o4-mini", reasoning_effort = "medium" },
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
    ["copilot-gpt-4.1"] = { "copilot", "gpt-4.1" },
    ["copilot-gpt-4.1-mini"] = { "copilot", "gpt-4.1-mini" },
    ["copilot-gpt-4.1-nano"] = { "copilot", "gpt-4.1-nano" },
    ["copilot-o3"] = { "copilot", "o3", reasoning_effort = "medium" },
    ["copilot-o4-mini"] = { "copilot", "o4-mini", reasoning_effort = "medium" },
    ["copilot-3-5-sonnet"] = { "copilot", "claude-3.5-sonnet" },
    ["copilot-3-7-sonnet"] = { "copilot", "claude-3.7-sonnet" },
    ["copilot-4-0-sonnet"] = { "copilot", "claude-sonnet-4" },
    ["copilot-3-7-sonnet-thought"] = { "copilot", "claude-3.7-sonnet-thought", reasoning_effort = "medium" },
    ["copilot-o3-mini"] = { "copilot", "o3-mini", reasoning_effort = "medium" },
    ["gemini-1.5-flash-8b"] = { "gemini", "gemini-1.5-flash-8b" },
    ["gemini-1.5-flash"] = { "gemini", "gemini-1.5-flash" },
    ["gemini-2.0-flash-exp"] = { "gemini", "gemini-2.0-flash-exp" },
    ["gemini-1.5-pro"] = { "gemini", "gemini-1.5-pro" },
    ["gemini-2.5-pro"] = { "gemini", "gemini-2.5-pro-exp-03-25" },
    ["claude-4-0-sonnet"] = { "anthropic", "claude-4-sonnet-20250514" },
    ["claude-3-7-sonnet"] = { "anthropic", "claude-3-7-sonnet-latest" },
    ["claude-3-5-sonnet"] = { "anthropic", "claude-3-5-sonnet-latest" },
  },
  instructions = {},
  --- @type sia.config.Defaults
  defaults = {
    model = "gpt-4.1", -- default
    temperature = 0.3, -- default temperature
    prefix = 1, -- prefix lines in insert
    suffix = 0, -- suffix lines in insert
    chat = {
      cmd = "vnew",
      wo = { wrap = true },
      block_action = "search_replace",
      automatic_block_action = false,
    },
    hidden = {
      messages = {},
    },
    diff = {
      cmd = "vnew",
      wo = { "wrap", "linebreak", "breakindent", "breakindentopt", "showbreak" },
    },
    insert = {
      placement = "cursor",
    },
    replace = {
      timeout = 300,
    },
    tools = {
      enable = true,
      choices = {
        file = require("sia.tools").add_file,
        files = require("sia.tools").add_files_glob,
        lsp_symbol = require("sia.tools").find_lsp_symbol,
        lsp_docs = require("sia.tools").documentation,
        grep = require("sia.tools").grep,
      },
    },
    actions = {
      insert = {
        mode = "insert",
        input = "require",
        temperature = 0.2,
        system = { "insert_system" },
        instructions = {
          "current_buffer",
        },
      },
      diff = {
        mode = "diff",
        input = "require",
        temperature = 0.2,
        system = { "diff_system" },
        instructions = {
          require("sia.instructions").current_buffer({ fences = false }),
          require("sia.instructions").current_context({ fences = false }),
        },
      },
      --- @type sia.config.Action
      chat = {
        mode = "chat",
        temperature = 0.1,
        chat = {
          block_action = "search_replace",
        },
        system = {
          "editblock_system",
          "git_files",
        },
        instructions = {
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
    replace = require("sia.actions").replace(),
  },
  report_usage = true,
}

function M.setup(options)
  M.options = vim.tbl_deep_extend("force", {}, defaults, options or {})
end

return M
