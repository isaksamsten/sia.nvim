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
      local global = M._raw_options.settings.context or {}
      if not lc or not lc.context then
        return global
      end

      local merged = vim.tbl_deep_extend("keep", lc.context, global)

      if lc.context.exclude and global.exclude then
        merged.exclude =
          vim.list_extend(vim.deepcopy(global.exclude or {}), lc.context.exclude)
      end
      return merged
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
--- @field model sia.config.ModelSpec?
--- @field fast_model sia.config.ModelSpec?
--- @field plan_model sia.config.ModelSpec?
--- @field models table<string, sia.config.ModelSpec>?
--- @field aliases table<string, {name: string}>?
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
--- @field tools (fun(model: sia.Model):sia.Tool[])?
--- @field ignore_tool_confirm boolean?
--- @field model (string|{name: string})?
--- @field input sia.config.ActionInput?
--- @field enabled ((fun():boolean)|boolean)?
--- @field capture (fun(arg: sia.Invocation):sia.Capture?)?
--- @field range boolean?

--- @class sia.config.ChatAction : sia.config.DefaultAction
--- @field mode "chat"
--- @field chat sia.config.Chat?
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

--- @class sia.config.Context
--- @field max_tool integer?
--- @field exclude string[]?
--- @field clear_input boolean?
--- @field keep integer?

--- @class sia.config.ContextManagement
--- @field prune_threshold number? Start pruning when context exceeds this fraction (default 0.85)
--- @field target_after_prune number? Target fraction after pruning tool calls (default 0.70)
--- @field compact_ratio number? Fraction of oldest messages to include in compaction (default 0.5)

--- @class sia.config.Settings
--- @field model string
--- @field fast_model string
--- @field plan_model string
--- @field embedding_model string?
--- @field icons sia.IconSet?
--- @field context sia.config.Context?
--- @field context_management sia.config.ContextManagement?
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

--- @class sia.config.ModelSpec
--- @field [1] string provider name
--- @field [2] string provider model api name
--- @field context_window integer?
--- @field response_format table?
--- @field pricing {input: number, output: number}?
--- @field cache_multiplier {read: number, write: number}?
--- @field support sia.config.Support?
--- @field options table<string, any>?

--- @alias sia.config.Models table<string, sia.config.ModelSpec>

--- @class sia.config.EmbeddingSpec
--- @field [1] string Provider name
--- @field [2] string API model name
--- @field context_window integer?

--- @alias sia.config.Embeddings table<string, sia.config.EmbeddingSpec>

--- @class sia.config.Provider
--- @field base_url string
--- @field chat_endpoint string
--- @field embedding_endpoint string?
--- @field api_key fun():string?
--- @field process_usage (fun(obj:table):sia.Usage?)?
--- @field process_response fun(json:table):string?
--- @field process_embeddings (fun(json:table):number[][])?
--- @field prepare_messages fun(data: table, model:string, prompt:sia.Message[])
--- @field prepare_tools fun(data: table, tools:sia.tool.Definition[])
--- @field prepare_parameters fun(data: table, model: sia.Model)?
--- @field prepare_embedding fun(data: table, strings: string[], model: sia.Model)?
--- @field get_headers (fun(model: sia.Model, api_key:string?, messages:sia.Message[]? ):string[])?
--- @field translate_http_error (fun(code: integer):string?)?
--- @field on_http_error (fun(code: integer):boolean)?
--- @field new_stream fun(strategy: sia.Strategy):sia.ProviderStream
--- @field get_stats fun(callback:fun(stats: sia.conversation.Stats), conversation: sia.Conversation)?

--- @class sia.config.Options
--- @field models sia.config.Models
--- @field embeddings sia.config.Embeddings?
--- @field settings sia.config.Settings
--- @field actions table<string, sia.config.Action>
--- @field providers table<string, sia.config.Provider>
M._raw_options = {
  providers = {},
  models = {
    ["zai/glm-4.5"] = { "zai", "GLM-4.5", context_window = 128000 },
    ["zai/glm-4.6"] = { "zai", "GLM-4.6", context_window = 128000 },
    ["openai/gpt-5.4"] = {
      "openai_responses",
      "gpt-5.4",
      context_window = 400000,
      support = { image = true, document = true, reasoning = true },
    },
    ["openai/gpt-5.2"] = {
      "openai_responses",
      "gpt-5.2",
      context_window = 400000,
      support = { image = true, document = true, reasoning = true },
    },
    ["openai/gpt-5.2-codex"] = {
      "openai_responses",
      "gpt-5.2-codex",
      context_window = 400000,
      support = { image = true, document = true, reasoning = true },
    },
    ["openai/gpt-5.1"] = {
      "openai_responses",
      "gpt-5.1",
      context_window = 400000,
      support = { image = true, document = true, reasoning = true },
    },
    ["openai/gpt-5.1-codex"] = {
      "openai_responses",
      "gpt-5.1-codex",
      context_window = 400000,
      support = { image = true, document = true, reasoning = true },
    },
    ["openai/gpt-4.1"] = { "openai", "gpt-4.1", context_window = 1047576 },
    ["codex/gpt-5.3-codex"] = {
      "codex",
      "gpt-5.3-codex",
      context_window = 400000,
      support = { document = true, reasoning = true },
    },
    ["codex/gpt-5.2-codex"] = {
      "codex",
      "gpt-5.2-codex",
      context_window = 400000,
      support = { document = true, reasoning = true },
    },
    ["codex/gpt-5.2"] = {
      "codex",
      "gpt-5.2",
      context_window = 400000,
      support = { image = true, document = true },
    },
    ["codex/gpt-5.4"] = {
      "codex",
      "gpt-5.4",
      context_window = 400000,
      support = { image = true, document = true },
    },
    ["copilot/gpt-4.1"] = { "copilot", "gpt-4.1", context_window = 128000 },
    ["copilot/gpt-5.2"] = {
      "copilot_responses",
      "gpt-5.2",
      context_window = 128000,
      support = { image = true, document = true, reasoning = true },
    },
    ["copilot/gpt-5.4"] = {
      "copilot_responses",
      "gpt-5.4",
      context_window = 128000,
      support = { image = true, document = true, reasoning = true },
    },
    ["copilot/gpt-5-mini"] = {
      "copilot",
      "gpt-5-mini",
      context_window = 128000,
      support = { image = true },
    },
    ["copilot/gpt-5.2-codex"] = {
      "copilot_responses",
      "gpt-5.2-codex",
      context_window = 128000,
      support = { document = true, reasoning = true },
    },
    ["copilot/claude-haiku-4.5"] = {
      "copilot",
      "claude-haiku-4.5",
      support = { image = true, reasoning = true },
      context_window = 128000,
    },
    ["copilot/claude-opus-4.6"] = {
      "copilot",
      "claude-opus-4.6",
      support = { image = true, reasoning = true, adaptive_thinking = true },
      context_window = 128000,
      options = {
        top_p = 1,
        max_tokens = 16000,
        thinking_budget = 4000,
        thinking = { type = "adaptive" },
        output_config = { effort = "high" },
      },
    },
    ["copilot/claude-sonnet-4.5"] = {
      "copilot",
      "claude-sonnet-4.5",
      context_window = 128000,
    },
    ["copilot/claude-sonnet-4.6"] = {
      "copilot",
      "claude-sonnet-4.6",
      context_window = 128000,
      support = { image = true, adaptive_thinking = true, reasoning = true },
      options = {
        top_p = 1,
        max_tokens = 16000,
        thinking_budget = 4000,
        thinking = { type = "adaptive" },
        output_config = { effort = "high" },
      },
    },
    ["copilot/gemini-3.1-pro"] = {
      "copilot",
      "gemini-3.1-pro-preview",
      context_window = 128000,
    },
    ["copilot/gemini-3-flash"] = {
      "copilot",
      "gemini-3-flash-preview",
      context_window = 128000,
    },
    ["copilot/grok-code-fast-1"] = {
      "copilot",
      "grok-code-fast-1",
      context_window = 109000,
    },
    ["anthropic/claude-sonnet-4.5"] = {
      "anthropic",
      "claude-4.5-sonnet",
      context_window = 200000,
    },
    ["openrouter/claude-sonnet-4"] = {
      "openrouter",
      "anthropic/claude-sonnet-4",
      pricing = { input = 3.00, output = 15.00 },
      cache_multiplier = { read = 0.1, write = 1.25 },
      context_window = 200000,
    },
    ["openrouter/claude-sonnet-4.5"] = {
      "openrouter",
      "anthropic/claude-sonnet-4.5",
      pricing = { input = 3.00, output = 15.00 },
      cache_multiplier = { read = 0.1, write = 1.25 },
      context_window = 200000,
    },
    ["openrouter/claude-sonnet-4.6"] = {
      "openrouter",
      "anthropic/claude-sonnet-4.6",
      pricing = { input = 3.00, output = 15.00 },
      cache_multiplier = { read = 0.1, write = 1.25 },
      context_window = 200000,
    },
    ["openrouter/claude-haiku-4.5"] = {
      "openrouter",
      "anthropic/claude-haiku-4.5",
      pricing = { input = 1.00, output = 5.00 },
      cache_multiplier = { read = 0.1, write = 1.25 },
      context_window = 200000,
    },
    ["openrouter/gemini-2.5-pro"] = {
      "openrouter",
      "google/gemini-2.5-pro",
      pricing = { input = 1.25, output = 5.00 },
      cache_multiplier = { read = 0.1, write = 1.25 },
      context_window = 1000000,
    },
    ["openrouter/glm-4.5"] = {
      "openrouter",
      "z-ai/glm-4.5",
      pricing = { input = 0.35, output = 2.00 },
      context_window = 128000,
    },
    ["openrouter/glm-4.6"] = {
      "openrouter",
      "z-ai/glm-4.6",
      pricing = { input = 0.45, output = 1.50 },
      context_window = 128000,
    },
    ["openrouter/qwen3-coder"] = {
      "openrouter",
      "qwen/qwen3-coder",
      pricing = { input = 0.07, output = 0.26 },
      context_window = 262144,
    },
    ["openrouter/kimi-k2"] = {
      "openrouter",
      "moonshotai/kimi-k2",
      pricing = { input = 0.40, output = 2.0 },
      context_window = 131072,
    },
  },
  embeddings = {
    ["openai/text-embedding-3-small"] = { "openai", "text-embedding-3-small" },
    ["openai/text-embedding-3-large"] = { "openai", "text-embedding-3-large" },
  },
  --- @type sia.config.Settings
  settings = {
    model = "openai/gpt-5.2",
    fast_model = "openai/gpt-4.1",
    plan_model = "openai/gpt-5.2",
    embedding_model = "openai/text-embedding-3-small",
    icons = "emoji",
    history = { enable = true },
    context = {
      max_tool = 200,
      keep = 20,
      clear_input = true,
      exclude = { "grep", "glob", "read_todos" },
    },
    context_management = {
      prune_threshold = 0.85,
      target_after_prune = 0.70,
      compact_ratio = 0.5,
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
        },
        tools = function(model)
          local tools = require("sia.tools")
          local all = {
            tools.ask_user,
            tools.grep,
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
    if key == "models" then
      local raw_models = M._raw_options.models
      local lc = M.get_local_config()
      local aliases = lc and lc.aliases or nil
      local model_overrides = lc and lc.models or nil

      if not aliases and not model_overrides then
        return raw_models
      end

      --- Resolve a model spec by applying local overrides and alias params.
      --- @param name string The model or alias name
      --- @return table? The enriched spec, or nil if unknown
      local function resolve_spec(name)
        local base_name = name
        local alias_params = nil

        if aliases and aliases[name] then
          local alias = aliases[name]
          base_name = alias.name
          alias_params = alias
        end

        local base_spec = raw_models[base_name]
        if not base_spec then
          return nil
        end

        local spec = vim.tbl_extend("force", {}, base_spec)
        if model_overrides and model_overrides[base_name] then
          local overrides = model_overrides[base_name]
          if overrides.options and spec.options then
            overrides = vim.tbl_extend("force", {}, overrides)
            overrides.options = vim.tbl_extend("force", spec.options, overrides.options)
          end
          spec = vim.tbl_extend("force", spec, overrides)
        end

        if alias_params then
          for k, v in pairs(alias_params) do
            if k == "options" and spec.options then
              spec.options = vim.tbl_extend("force", spec.options, v)
            elseif k ~= "name" then
              spec[k] = v
            end
          end
        end

        return spec
      end

      local combined = {}
      for k, _ in pairs(raw_models) do
        combined[k] = resolve_spec(k)
      end
      if aliases then
        for alias_name, _ in pairs(aliases) do
          if not combined[alias_name] then
            combined[alias_name] = resolve_spec(alias_name)
          end
        end
      end
      return combined
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
end

return M
