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
--- @field callback (fun(ctx:sia.Context?, content:string[]):nil)?
--- @field messages { on_start: string?, on_progress: string[]? }?

--- @class sia.config.Replace
--- @field timeout number?

--- @class sia.config.Instruction
--- @field role sia.config.Role
--- @field hide boolean?
--- @field description ((fun(ctx:sia.Context?):string)|string)?
--- @field content ((fun(ctx: sia.Context?):string?)|string|string[])?
--- @field kind string?
--- @field live_content (fun():string?)?
--- @field tool_calls sia.ToolCall[]?
--- @field _tool_call sia.ToolCall?

--- @class sia.config.Tool
--- @field name string
--- @field description string
--- @field system_prompt string?
--- @field is_interactive (fun(args: table):boolean)?
--- @field message string|(fun(args:table):string)?
--- @field parameters table<string, sia.ToolParameter>
--- @field required string[]?
--- @field execute fun(args:table, strategy: sia.Conversation, callback: fun(result: sia.ToolResult)):nil

--- @class sia.config.Action
--- @field system (string|sia.config.Instruction)[]?
--- @field instructions (string|sia.config.Instruction)[]
--- @field modify_instructions (fun(instructions:(string|sia.config.Instruction|(fun():sia.config.Instruction[]))[], ctx: sia.ActionContext):nil)?
--- @field tools (sia.config.Tool|string)[]?
--- @field ignore_tool_confirm boolean?
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

--- @class sia.config.AutoNaming
--- @field enabled boolean
--- @field model string

--- @class sia.config.Defaults
--- @field model string
--- @field temperature number
--- @field auto_naming sia.config.AutoNaming
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
--- @field format_messages fun(model:string, prompt:sia.Prompt[]):nil

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
    openrouter = providers.openrouter,
  },
  models = {
    ["openai/gpt-4.1"] = { "openai", "gpt-4.1", cost = { completion_tokens = 0.000008, prompt_tokens = 0.000002 } },
    ["openai/gpt-4.1-mini"] = {
      "openai",
      "gpt-4.1-mini",
      cost = { completion_tokens = 0.0000016, prompt_tokens = 0.0000004 },
    },
    ["openai/gpt-4.1-nano"] = {
      "openai",
      "gpt-4.1-nano",
      cost = { completion_tokens = 0.0000004, prompt_tokens = 0.0000001 },
    },
    ["openai/gpt-4o"] = { "openai", "gpt-4o", cost = { completion_tokens = 0.00001, prompt_tokens = 0.0000025 } },
    ["openai/gpt-4o-mini"] = {
      "openai",
      "gpt-4o-mini",
      cost = { completion_tokens = 0.00000015, prompt_tokens = 0.0000006 },
    },
    ["openai/o3"] = { "openai", "o3", reasoning_effort = "medium" },
    ["openai/o4-mini"] = { "openai", "o4-mini", reasoning_effort = "medium" },
    ["openai/o3-mini"] = {
      "openai",
      "o3-mini",
      reasoning_effort = "medium",
      cost = { completion_tokens = 0.0000044, prompt_tokens = 0.0000011 },
    },
    ["openai/o3-mini-low"] = {
      "openai",
      "o3-mini",
      reasoning_effort = "low",
      cost = { completion_tokens = 0.0000044, prompt_tokens = 0.0000011 },
    },
    ["openai/o3-mini-high"] = {
      "openai",
      "o3-mini",
      reasoning_effort = "high",
      cost = { completion_tokens = 0.0000044, prompt_tokens = 0.0000011 },
    },
    ["openai/chatgpt-4o-latest"] = { "openai", "chatgpt-4o-latest" },
    ["copilot/gpt-4o"] = { "copilot", "gpt-4o" },
    ["copilot/gpt-4.1"] = { "copilot", "gpt-4.1" },
    ["copilot/gpt-4.1-mini"] = { "copilot", "gpt-4.1-mini" },
    ["copilot/gpt-4.1-nano"] = { "copilot", "gpt-4.1-nano" },
    ["copilot/o3"] = { "copilot", "o3", reasoning_effort = "medium" },
    ["copilot/o4-mini"] = { "copilot", "o4-mini", reasoning_effort = "medium" },
    ["copilot/claude-sonnet-3.5"] = { "copilot", "claude-3.5-sonnet" },
    ["copilot/claude-sonnet-3.7"] = { "copilot", "claude-3.7-sonnet" },
    ["copilot/claude-sonnet-4"] = { "copilot", "claude-sonnet-4" },
    ["copilot/claude-sonnet-3.7-thought"] = { "copilot", "claude-3.7-sonnet-thought", reasoning_effort = "medium" },
    ["copilot/o3-mini"] = { "copilot", "o3-mini", reasoning_effort = "medium" },
    ["gemini/1.5-flash-8b"] = { "gemini", "gemini-1.5-flash-8b" },
    ["gemini/1.5-flash"] = { "gemini", "gemini-1.5-flash" },
    ["gemini/2.0-flash-exp"] = { "gemini", "gemini-2.0-flash-exp" },
    ["gemini/1.5-pro"] = { "gemini", "gemini-1.5-pro" },
    ["gemini/2.5-pro"] = { "gemini", "gemini-2.5-pro-exp-03-25" },
    ["anthropic/claude-sonnet-4"] = { "anthropic", "claude-4-sonnet-20250514" },
    ["anthropic/claude-sonnet-3.7"] = { "anthropic", "claude-3-7-sonnet-latest" },
    ["anthropic/claude-sonnet-3.5"] = { "anthropic", "claude-3-5-sonnet-latest" },
    ["openrouter/claude-sonnet-4"] = { "openrouter", "anthropic/claude-sonnet-4" },
    ["openrouter/gemini-2.5-pro"] = { "openrouter", "google/gemini-2.5-pro" },
    ["openrouter/glm-4.5"] = { "openrouter", "z-ai/glm-4.5" },
    ["openrouter/quen3-coder"] = { "openrouter", "qwen/qwen3-coder" },
    ["openrouter/kimi-k2"] = { "openrouter", "moonshotai/kimi-k2" },
  },
  instructions = {},
  --- @type sia.config.Defaults
  defaults = {
    model = "openai/gpt-4.1",
    temperature = 0.3, -- default temperature
    prefix = 1, -- prefix lines in insert
    suffix = 0, -- suffix lines in insert
    auto_naming = {
      enabled = true,
      model = "openai/gpt-4o-mini",
    },
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
        show_locations = require("sia.tools").show_locations,
        show_location = require("sia.tools").show_location,
        show_recent_changes = require("sia.tools").show_recent_changes,
        read = require("sia.tools").read,
        find_symbols = require("sia.tools").find_lsp_symbol,
        get_symbols_docs = require("sia.tools").get_lsp_symbol_docs,
        edit = require("sia.tools").edit_file,
        write = require("sia.tools").write,
        list_files = require("sia.tools").list_files,
        get_diagnostics = require("sia.tools").get_diagnostics,
        grep = require("sia.tools").grep,
        git_commit = require("sia.tools").git_commit,
        git_diff = require("sia.tools").git_diff,
        git_unstage = require("sia.tools").git_unstage,
        git_status = require("sia.tools").git_status,
        dispatch_agent = require("sia.tools").dispatch_agent,
        compact = require("sia.tools").compact_conversation,
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
          block_action = "verbatim",
        },
        system = {
          "default_system",
          "directory_structure",
          "agents_md",
        },
        instructions = {
          "current_context",
        },
        tools = {
          "grep",
          "show_location",
          "show_locations",
          "show_recent_changes",
          "edit",
          "write",
          "read",
          "list_files",
          "find_symbols",
          "get_symbols_docs",
          "get_diagnostics",
          "dispatch_agent",
          "compact",
        },
      },
    },
  },
  actions = {
    agent = {
      mode = "chat",
      temperature = 0.1,
      chat = {
        block_action = "verbatim",
      },
      system = {
        "default_system",
        "directory_structure",
        "agents_md",
      },
      instructions = {
        "current_context",
      },
      tools = {
        "grep",
        "read",
        "edit",
        "list_files",
        "get_diagnostics",
        "git_status",
        "dispatch_agent",
        "compact",
        "git_commit",
        "git_diff",
        "show_recent_changes",
      },
    },
    commit = require("sia.actions").commit(),
    review = require("sia.actions").review(),
    doc = require("sia.actions").doc(),
  },
  report_usage = true,
}

function M.setup(options)
  M.options = vim.tbl_deep_extend("force", {}, defaults, options or {})
end

return M
