local M = {}

local local_config = require("sia.config.local")
local messages = require("sia.config.messages")

--- Normalize model config to a consistent table format
--- @param model_value string|table|nil
--- @return {name:string}?
local function normalize_model_config(model_value)
  if model_value == nil then
    return nil
  end

  if type(model_value) == "string" then
    return { name = model_value }
  elseif type(model_value) == "table" then
    return model_value
  end

  return nil
end

local action_proxy = setmetatable({}, {
  __index = function(_, mode)
    local lc = M.get_local_config()
    if lc and lc.action and lc.action[mode] then
      return M._raw_options.actions[lc.action[mode]]
    end
    return M._raw_options.settings.actions[mode]
  end,
})

local MODEL_KEYS = { model = true, fast_model = true, plan_model = true }
local LOCAL_ONLY_KEYS = {
  permission = true,
  risk = true,
  skills = true,
  skills_extras = true,
  agents = true,
  aliases = true,
  models = true,
}

--- The settings proxy. Indexing resolves local -> global automatically.
--- Accessed via config.options.settings.
--- @type sia.config.Settings
local settings_proxy = setmetatable({}, {
  __index = function(_, key)
    local lc = M.get_local_config()

    if key == "actions" then
      return action_proxy
    end

    if key == "context" then
      return vim.tbl_deep_extend(
        "force",
        {},
        M._raw_options.settings.context,
        lc and lc.context or {}
      )
    end

    if MODEL_KEYS[key] then
      if lc and lc[key] then
        return lc[key]
      end
      local default_model = normalize_model_config(M._raw_options.settings[key])
      if not default_model then
        error("default " .. key .. " is not set")
      end
      return default_model
    end

    if LOCAL_ONLY_KEYS[key] then
      return lc and lc[key]
    end

    local global_val = M._raw_options.settings[key]
    if lc and lc[key] ~= nil then
      if type(global_val) == "table" and type(lc[key]) == "table" then
        return vim.tbl_deep_extend("force", global_val, lc[key])
      end
      return lc[key]
    end

    return global_val
  end,
  __newindex = function(_, key, value)
    M._raw_options.settings[key] = value
  end,
})

--- @class sia.LocalConfig
--- @field action { insert: string?, diff: string?, chat: string?}?
--- @field model {name: string}?
--- @field fast_model {name: string}?
--- @field plan_model {name: string}?
--- @field models table<string, sia.config.ModelOptions>?
--- @field aliases table<string, {name: string, options: table<string, any>?}>?
--- @field permission { deny: table?, allow: table?, ask: table?}?
--- @field risk table?
--- @field context sia.config.Context?
--- @field skills string[]?
--- @field skills_extras string[]?
--- @field agents string[]?

--- @class sia.config.Settings.Ui
--- @field diff sia.config.Settings.Ui.Diff
--- @field confirm sia.config.Settings.Ui.Confirm

--- @class sia.config.Settings.Ui.Diff
--- @field enable boolean?
--- @field show_signs boolean?
--- @field char_diff boolean?

--- @class sia.config.Settings.Ui.Confirm.Async
--- @field enable boolean?
--- @field notifier sia.ConfirmNotifier?

--- @class sia.config.Settings.Ui.Confirm
--- @field use_vim_ui boolean?
--- @field show_preview boolean?
--- @field async sia.config.Settings.Ui.Confirm.Async?

--- @alias sia.config.insert.Placement ["below"|"above", "start"|"end"|"cursor"]|"start"|"end"|"cursor"
--- @alias sia.config.ActionInput "require"|"ignore"
--- @alias sia.config.ActionMode "chat"|"diff"|"insert"|"hidden"

--- @class sia.config.ModePermissions
--- @field deny string[]?
--- @field allow table<string, true|sia.config.ModeAllowRule>?

--- @class sia.config.ModeAllowRule
--- @field arguments table<string, string[]>

--- @class sia.config.Mode
--- @field description string?
--- @field permissions sia.config.ModePermissions?
--- @field deny_message (fun(tool_name: string, args: table, kind: "denied"|"restricted"):string[])?
--- @field enter_prompt string|fun(state: table):string
--- @field exit_prompt string|fun(state: table):string
--- @field init_state (fun(): table)?
--- @field truncate boolean?

--- @class sia.config.Insert
--- @field placement (fun():sia.config.insert.Placement)|sia.config.insert.Placement
--- @field cursor ("start"|"end")?
--- @field message [string, string]?
--- @field post_process (fun(args: { lines: string[], buf: integer, start_line: integer, start_col: integer, end_line: integer, end_col: integer }): string[])?

--- @class sia.config.Diff
--- @field wo [string]?
--- @field cmd string?

--- @class sia.config.Winbar
--- @field left (fun(data: sia.WinbarData):string)?
--- @field center (fun(data: sia.WinbarData):string)?
--- @field right (fun(data: sia.WinbarData):string)?

--- @class sia.config.Chat
--- @field cmd string?
--- @field wo table<string, any>?
--- @field winbar sia.config.Winbar?

--- @class sia.config.Hidden
--- @field callback fun(buf:number?, opts: { error: string?, content:string[]?, usage:sia.Usage?})?
--- @field notify fun(string)?

--- @alias sia.config.UserContent (fun(invocation: sia.Invocation):sia.Content?,sia.Region?)|sia.Content
--- @alias sia.config.UserMessage sia.config.UserContent|{hide: boolean, content:sia.config.UserContent}
--- @alias sia.config.SystemMessage string|fun():string

--- @class sia.config.DefaultAction
--- @field system sia.config.SystemMessage[]
--- @field user sia.config.UserMessage[]
--- @field tools (fun(model: sia.Model):sia.Tool[],true|table<string, true>?)?
--- @field model (string|{name: string})?
--- @field input sia.config.ActionInput?
--- @field enabled ((fun():boolean)|boolean)?
--- @field capture (fun(arg: sia.Invocation):sia.Capture?)?
--- @field range boolean?

--- @class sia.config.ChatAction : sia.config.DefaultAction
--- @field mode "chat"
--- @field chat sia.config.Chat?
--- @field agents table<string, true>?
--- @field modes table<string, sia.config.Mode>?

--- @class sia.config.DiffAction : sia.config.DefaultAction
--- @field mode "diff"
--- @field diff sia.config.Diff?

--- @class sia.config.InsertAction : sia.config.DefaultAction
--- @field mode "insert"
--- @field insert sia.config.Insert?

--- @class sia.config.HiddenAction : sia.config.DefaultAction
--- @field mode "hidden"
--- @field hidden sia.config.Hidden?

--- @alias sia.config.Action sia.config.ChatAction|sia.config.InsertAction|sia.config.DiffAction|sia.config.HiddenAction

--- @class sia.config.ContextTools
--- @field max_calls integer?
--- @field preserve string[]?
--- @field strip_inputs boolean?
--- @field keep_last integer?

--- @class sia.config.ContextTokensCompact
--- @field oldest_fraction number?

--- @class sia.config.ContextTokensPrune
--- @field at_fraction number?
--- @field to_fraction number?

--- @class sia.config.ContextTokens
--- @field prune sia.config.ContextTokensPrune?
--- @field compact sia.config.ContextTokensCompact?

--- @class sia.config.Context
--- @field tools sia.config.ContextTools?
--- @field tokens sia.config.ContextTokens?

--- @class sia.config.Settings
--- @field model string
--- @field fast_model string
--- @field plan_model string
--- @field icons sia.IconSet?
--- @field context sia.config.Context?
--- @field actions {diff: sia.config.DiffAction, chat: sia.config.ChatAction, insert: sia.config.InsertAction }
--- @field chat sia.config.Chat
--- @field diff sia.config.Diff
--- @field insert sia.config.Insert
--- @field hidden sia.config.Hidden
--- @field file_ops {trash: boolean?, restrict_to_project_root: boolean?, create_dirs_on_rename: boolean?}?
--- @field ui sia.config.Settings.Ui?
--- @field shell sia.config.Shell?
--- @field history { enable: boolean? }?

--- @class sia.config.Shell
--- @field command string?
--- @field args string[]|fun():string[]?
--- @field shell sia.config.Shell?

--- @class sia.config.Support
--- @field image boolean?
--- @field document boolean?
--- @field reasoning boolean?
--- @field [string] boolean?

--- @alias sia.config.ModelOptions table<string, table<string, any>>

--- @class sia.config.Options
--- @field settings sia.config.Settings
--- @field models table<string, sia.config.ModelOptions>?
--- @field actions table<string, sia.config.Action>
--- @field providers table<string, sia.provider.ProviderSpec|boolean>
M._raw_options = {
  providers = {},
  --- @type sia.config.Settings
  settings = {
    model = "openai/gpt-5.2",
    fast_model = "openai/gpt-4.1",
    plan_model = "openai/gpt-5.2",
    icons = "emoji",
    history = { enable = true },
    context = {
      tools = {
        max_calls = 200,
        keep_last = 20,
        strip_inputs = true,
        preserve = { "grep", "glob", "read_todos" },
      },
      tokens = {
        prune = {
          at_fraction = 0.85,
          to_fraction = 0.70,
        },
        compact = {
          oldest_fraction = 0.5,
        },
      },
    },
    chat = {
      cmd = "botright vnew",
      wo = { wrap = true, spell = false },
      winbar = {
        left = require("sia.ui.winbar").default_left,
        center = require("sia.ui.winbar").default_center,
        right = require("sia.ui.winbar").default_right,
      },
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
    file_ops = {
      trash = true,
      create_dirs_on_rename = true,
      restrict_to_project_root = true,
    },
    ui = {
      diff = {
        enable = true,
        show_signs = true,
        char_diff = true,
      },
      confirm = {
        use_vim_ui = false,
        show_preview = true,
        async = {
          enable = false,
        },
      },
    },
    shell = {
      command = "/bin/bash",
      args = { "-s" },
    },

    actions = {
      insert = {
        mode = "insert",
        input = "require",
        system = { messages.system.insert },
        user = {
          messages.user.buffer({
            show_line_numbers = true,
            include_cursor = true,
          }),
        },
        tools = function()
          local tools = require("sia.tools")
          return { tools.grep, tools.view, tools.glob }
        end,
      },
      diff = {
        mode = "diff",
        input = "require",
        system = { messages.system.diff },
        user = {
          messages.user.selection({
            show_line_numbers = true,
            fences = false,
          }),
        },
        tools = function()
          local tools = require("sia.tools")
          return { tools.grep, tools.view, tools.glob }
        end,
      },
      --- @type sia.config.ChatAction
      chat = {
        mode = "chat",
        system = {
          messages.system.adaptive,
        },
        modes = {
          plan = require("sia.modes").plan,
        },
        input = "require",
        user = {
          messages.user.environment,
          messages.user.file_tree,
          messages.user.agents_md,
          messages.user.visible_buffers,
          messages.user.selection(),
        },
        tools = function(model)
          local tools = require("sia.tools")
          local all = {
            tools.ask_user,
            tools.grep,
            tools.skills,
            tools.write,
            tools.insert,
            tools.view,
            tools.glob,
            tools.agent,
            tools.diagnostics,
            tools.bash,
            tools.webfetch,
            tools.websearch,
            tools.write_todos,
            tools.read_todos,
            tools.memory,
            tools.view_image,
            tools.view_document,
            tools.edit,
            tools.exit_mode,
          }
          if model.api_name:match("gpt%-5") then
            table.insert(all, tools.apply_diff)
          end
          return all
        end,
      },
    },
  },
  actions = {
    --- @type sia.config.Action
    prose = {
      mode = "chat",
      system = {
        messages.system.prose,
      },
      user = {
        messages.user.selection(),
      },
      tools = function(model)
        local tools = require("sia.tools")
        local all = {
          tools.ask_user,
          tools.grep,
          tools.skills,
          tools.write,
          tools.insert,
          tools.view,
          tools.glob,
          tools.diagnostics,
          tools.bash,
          tools.websearch,
          tools.webfetch,
          tools.write_todos,
          tools.read_todos,
          tools.memory,
          tools.view_image,
          tools.view_document,
          tools.edit,
          tools.exit_mode,
        }
        if model.api_name:match("gpt%-5") then
          table.insert(all, tools.apply_diff)
        end
        return all
      end,
    },
    commit = require("sia.actions").commit(),
    doc = require("sia.actions").doc(),
  },
}

--- Proxy for config.options that:
--- - Delegates to settings_proxy for settings access
--- - Enriches the models table with aliases from local project config
--- - Returns the settings proxy for transparent local -> global resolution
--- @type sia.config.Options
M.options = setmetatable({}, {
  __index = function(_, key)
    if key == "settings" then
      return settings_proxy
    end
    return M._raw_options[key]
  end,
  __newindex = function(_, key, value)
    M._raw_options[key] = value
  end,
})

-- Delegate local config functions
M.get_local_config = local_config.get_local_config
M.get_local_config_path = local_config.get_local_config_path
M.get_auto_config_path = local_config.get_auto_config_path
M.invalidate_local_config = local_config.invalidate_local_config
M.update_auto_config = local_config.update_auto_config

function M.setup(options)
  M._raw_options = vim.tbl_deep_extend("force", {}, M._raw_options, options or {})
  local registry = require("sia.provider")
  registry.bootstrap(M._raw_options.models, M._raw_options.providers)
end

return M
