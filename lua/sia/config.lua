local M = {}

--- @type table<string, {mtime: integer, json: table}?>
local config_cache = {}

local validate = {
  permissions = function(permission)
    if not permission then
      return true
    end

    if type(permission) ~= "table" then
      return false, "'permission' must be an object, got " .. type(permission)
    end
    local validate_permission_patterns = function(patterns, path)
      if type(patterns) ~= "table" then
        return false, path .. " must be an array, got " .. type(patterns)
      end

      for i, pattern_def in ipairs(patterns) do
        local pattern

        if type(pattern_def) == "string" then
          pattern = pattern_def
        elseif type(pattern_def) == "table" then
          if type(pattern_def.pattern) ~= "string" then
            return false,
              path .. "[" .. i .. "].pattern must be a string, got " .. type(
                pattern_def.pattern
              )
          end
          pattern = pattern_def.pattern
        else
          return false,
            path
              .. "["
              .. i
              .. "] must be a string or object with 'pattern' field, got "
              .. type(pattern_def)
        end

        local ok, regex = pcall(vim.regex, "\\v" .. pattern)
        if not ok then
          return false,
            "invalid regex pattern in " .. path .. "[" .. i .. "]: " .. regex
        end
        patterns[i] = regex
      end
      return true
    end

    for section_name, section in pairs(permission) do
      if type(section) ~= "table" then
        return false,
          "permission." .. section_name .. " must be an object, got " .. type(section)
      end

      for tool_name, tool_perms in pairs(section) do
        if type(tool_perms) ~= "table" then
          return false,
            "permission."
              .. section_name
              .. "."
              .. tool_name
              .. " must be an object, got "
              .. type(tool_perms)
        end

        if not tool_perms.arguments then
          return false,
            "permission."
              .. section_name
              .. "."
              .. tool_name
              .. " must have an 'arguments' field"
        end

        if type(tool_perms.arguments) ~= "table" then
          return false,
            "permission."
              .. section_name
              .. "."
              .. tool_name
              .. ".arguments must be an object, got "
              .. type(tool_perms.arguments)
        end

        for param_name, patterns in pairs(tool_perms.arguments) do
          local path = "permission."
            .. section_name
            .. "."
            .. tool_name
            .. ".arguments."
            .. param_name
          local ok, err = validate_permission_patterns(patterns, path)
          if not ok then
            return false, err
          end
        end

        if section_name == "allow" and tool_perms.choice ~= nil then
          if
            type(tool_perms.choice) ~= "number"
            or tool_perms.choice < 1
            or tool_perms.choice ~= math.floor(tool_perms.choice)
          then
            return false,
              "permission."
                .. section_name
                .. "."
                .. tool_name
                .. ".choice must be a positive integer, got "
                .. type(tool_perms.choice)
          end
        end
      end
    end
    return true
  end,

  risk = function(risk)
    if not risk then
      return true
    end

    if type(risk) ~= "table" then
      return false, "'risk' must be an object, got " .. type(risk)
    end
    local validate_risk_patterns = function(patterns, path)
      if type(patterns) ~= "table" then
        return false, path .. " must be an array, got " .. type(patterns)
      end

      local valid_levels = { safe = true, info = true, warn = true }

      for i, pattern_def in ipairs(patterns) do
        if type(pattern_def) ~= "table" then
          return false,
            path
              .. "["
              .. i
              .. "] must be an object with 'pattern' and 'level' fields, got "
              .. type(pattern_def)
        end

        if type(pattern_def.pattern) ~= "string" then
          return false,
            path .. "[" .. i .. "].pattern must be a string, got " .. type(
              pattern_def.pattern
            )
        end

        if type(pattern_def.level) ~= "string" then
          return false,
            path .. "[" .. i .. "].level must be a string, got " .. type(
              pattern_def.level
            )
        end

        if not valid_levels[pattern_def.level] then
          return false,
            path
              .. "["
              .. i
              .. "].level must be one of 'safe', 'info', or 'warn', got '"
              .. pattern_def.level
              .. "'"
        end

        local ok, regex = pcall(vim.regex, "\\v" .. pattern_def.pattern)
        if not ok then
          return false,
            "invalid regex pattern in " .. path .. "[" .. i .. "]: " .. regex
        end

        patterns[i] = { level = pattern_def.level, regex = regex }
      end
      return true
    end

    for tool_name, tool_risk in pairs(risk) do
      if type(tool_risk) ~= "table" then
        return false,
          "risk." .. tool_name .. " must be an object, got " .. type(tool_risk)
      end

      if not tool_risk.arguments then
        return false, "risk." .. tool_name .. " must have an 'arguments' field"
      end

      if type(tool_risk.arguments) ~= "table" then
        return false,
          "risk." .. tool_name .. ".arguments must be an object, got " .. type(
            tool_risk.arguments
          )
      end

      for param_name, patterns in pairs(tool_risk.arguments) do
        local path = "risk." .. tool_name .. ".arguments." .. param_name
        local ok, err = validate_risk_patterns(patterns, path)
        if not ok then
          return false, err
        end
      end
    end
    return true
  end,

  context = function(context)
    if not context then
      return true
    end

    if type(context) ~= "table" then
      return false, "'context' must be an object, got " .. type(context)
    end

    if context.max_tool ~= nil then
      if
        type(context.max_tool) ~= "number"
        or context.max_tool < 0
        or context.max_tool ~= math.floor(context.max_tool)
      then
        return false,
          "context.max_tool must be a non-negative integer, got " .. type(
            context.max_tool
          )
      end
    end

    if context.exclude ~= nil then
      if type(context.exclude) ~= "table" then
        return false, "context.exclude must be an array, got " .. type(context.exclude)
      end

      for i, item in ipairs(context.exclude) do
        if type(item) ~= "string" then
          return false,
            "context.exclude[" .. i .. "] must be a string, got " .. type(item)
        end
      end
    end

    if context.clear_input ~= nil then
      if type(context.clear_input) ~= "boolean" then
        return false,
          "context.clear_input must be a boolean, got " .. type(context.clear_input)
      end
    end

    if context.keep ~= nil then
      if
        type(context.keep) ~= "number"
        or context.keep < 0
        or context.keep ~= math.floor(context.keep)
      then
        return false,
          "context.keep must be a non-negative integer, got " .. type(context.keep)
      end
    end

    return true
  end,

  skills = function(json)
    if json.skills ~= nil then
      if type(json.skills) ~= "table" then
        return false, "'skills' must be an array of strings, got " .. type(json.skills)
      end
      for i, item in ipairs(json.skills) do
        if type(item) ~= "string" then
          return false, "skills[" .. i .. "] must be a string, got " .. type(item)
        end
      end
    end

    if json.skills_extras ~= nil then
      if type(json.skills_extras) ~= "table" then
        return false,
          "'skills_extras' must be an array of strings, got " .. type(
            json.skills_extras
          )
      end
      for i, item in ipairs(json.skills_extras) do
        if type(item) ~= "string" then
          return false,
            "skills_extras[" .. i .. "] must be a string, got " .. type(item)
        end
      end
    end

    return true
  end,

  agents = function(json)
    if json.agents ~= nil then
      if type(json.agents) ~= "table" then
        return false, "'agents' must be an array of strings, got " .. type(json.agents)
      end
      for i, item in ipairs(json.agents) do
        if type(item) ~= "string" then
          return false, "agents[" .. i .. "] must be a string, got " .. type(item)
        end
      end
    end
    return true
  end,

  action = function(action)
    if not action then
      return true
    end

    if type(action) ~= "table" then
      return false, "'action' must be an object, got " .. type(action)
    end

    local allowed_fields = { insert = true, diff = true, chat = true }
    for field, value in pairs(action) do
      if allowed_fields[field] and type(value) ~= "string" then
        return false,
          string.format("action.%s must be a string, got %s", field, type(value))
      end

      if not M._raw_options.actions[value] then
        return false,
          string.format("action.%s, %s is no a defined action", field, value)
      end
    end

    return true
  end,

  model_field = function(json, field)
    if json[field] ~= nil then
      local model_value = json[field]
      local model_name

      if type(model_value) == "string" then
        model_name = model_value
      elseif type(model_value) == "table" then
        if type(model_value.name) ~= "string" then
          return false,
            string.format(
              "'%s' must be a string or table with 'name' field, got table without valid name",
              field
            )
        end
        model_name = model_value.name
      else
        return false,
          string.format(
            "'%s' must be a string or table, got %s",
            field,
            type(model_value)
          )
      end

      local aliases = json.aliases or {}
      if not M._raw_options.models[model_name] and not aliases[model_name] then
        return false,
          string.format(
            "'%s' must be one of the allowed models or aliases, got '%s'",
            field,
            tostring(model_name)
          )
      end
    end
    return true
  end,

  models_overrides = function(models)
    if not models then
      return true
    end

    if type(models) ~= "table" then
      return false, "'models' must be an object, got " .. type(models)
    end

    for model_name, overrides in pairs(models) do
      if type(model_name) ~= "string" then
        return false, "models keys must be strings (model names)"
      end

      if not M._raw_options.models[model_name] then
        return false,
          string.format(
            "models.%s: '%s' is not a valid model name",
            model_name,
            model_name
          )
      end

      if type(overrides) ~= "table" then
        return false,
          string.format(
            "models.%s must be an object with override parameters, got %s",
            model_name,
            type(overrides)
          )
      end
    end

    return true
  end,

  aliases = function(aliases)
    if not aliases then
      return true
    end

    if type(aliases) ~= "table" then
      return false, "'aliases' must be an object, got " .. type(aliases)
    end

    for alias_name, alias_def in pairs(aliases) do
      if type(alias_name) ~= "string" then
        return false, "aliases keys must be strings"
      end

      if type(alias_def) ~= "table" then
        return false,
          string.format(
            "aliases.%s must be an object with at least a 'name' field, got %s",
            alias_name,
            type(alias_def)
          )
      end

      if type(alias_def.name) ~= "string" then
        return false,
          string.format(
            "aliases.%s must have a 'name' field pointing to a valid model",
            alias_name
          )
      end

      if not M._raw_options.models[alias_def.name] then
        return false,
          string.format(
            "aliases.%s: '%s' is not a valid model name",
            alias_name,
            alias_def.name
          )
      end
    end

    return true
  end,
}

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

--- The settings proxy. Indexing resolves local → global automatically.
--- Accessed via config.options.settings.
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

    if key == "auto_continue" then
      return lc and lc.auto_continue or false
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
--- @field auto_continue boolean?
--- @field model table?
--- @field fast_model table?
--- @field plan_model table?
--- @field models table<string, table>?
--- @field aliases table<string, {name: string}>?
--- @field permission { deny: table?, allow: table?, ask: table?}?
--- @field risk table?
--- @field context sia.config.Context?
--- @field skills string[]?
--- @field skills_extras string[]?
--- @field agents string[]?

--- @return sia.LocalConfig?
function M.get_local_config()
  local root = vim.fs.root(0, ".sia")
  if not root then
    return nil
  end

  local local_config = vim.fs.joinpath(root, ".sia", "config.json")
  local stat = vim.uv.fs_stat(local_config)
  if not stat then
    return nil
  end

  local cache = config_cache[root]
  if cache and stat.mtime.sec == cache.mtime then
    return cache.json
  end

  local read_ok, file_content = pcall(vim.fn.readfile, local_config)
  if not read_ok then
    vim.notify(
      string.format(
        "Sia: Failed to read config file %s: %s",
        local_config,
        file_content
      ),
      vim.log.levels.ERROR
    )
    return nil
  end

  local has_failed = false
  local function validate_with(fun, ...)
    if not has_failed then
      local ok, err = fun(...)
      if not ok then
        vim.notify(
          string.format("Sia: Config file %s: %s", local_config, err),
          vim.log.levels.ERROR
        )
        has_failed = true
      end
    end
  end
  local content = table.concat(file_content, " ")
  local decode_ok, json = pcall(vim.json.decode, content)
  if not decode_ok then
    vim.notify(
      string.format("Sia: Invalid JSON in config file %s: %s", local_config, json),
      vim.log.levels.ERROR
    )
    has_failed = true
  end

  if not has_failed and type(json) ~= "table" then
    vim.notify(
      string.format(
        "Sia: Config file %s must contain a JSON object, got %s",
        local_config,
        type(json)
      ),
      vim.log.levels.ERROR
    )
    has_failed = true
  end

  validate_with(validate.permissions, json.permission)
  validate_with(validate.risk, json.risk)
  validate_with(validate.context, json.context)
  validate_with(validate.action, json.action)
  validate_with(validate.models_overrides, json.models)
  validate_with(validate.aliases, json.aliases)

  validate_with(validate.skills, json)
  validate_with(validate.agents, json)
  validate_with(validate.model_field, json, "model")
  validate_with(validate.model_field, json, "fast_model")
  validate_with(validate.model_field, json, "plan_model")
  validate_with(function()
    if json.auto_continue and type(json.auto_continue) ~= "boolean" then
      return false,
        string.format(
          "'%s' must be a boolean, got %s",
          json.auto_continue,
          type(json.auto_continue)
        )
    end
    return true
  end)

  if has_failed then
    return nil
  end

  json.model = normalize_model_config(json.model)
  json.fast_model = normalize_model_config(json.fast_model)
  json.plan_model = normalize_model_config(json.plan_model)

  config_cache[root] = { mtime = stat.mtime.sec, json = json }
  return json
end

--- @class sia.config.Settings.Ui
--- @field diff sia.config.Settings.Ui.Diff
--- @field approval sia.config.Settings.Ui.Approval

--- @class sia.config.Settings.Ui.Diff
--- @field enable boolean?
--- @field show_signs boolean?
--- @field char_diff boolean?

--- @class sia.config.Settings.Ui.Approval.Async
--- @field enable boolean?
--- @field notifier sia.ApprovalNotifier?

--- @class sia.config.Settings.Ui.Approval
--- @field use_vim_ui boolean?
--- @field show_preview boolean?
--- @field async sia.config.Settings.Ui.Approval.Async?

--- @alias sia.config.Role "user"|"system"|"assistant"|"tool"
--- @alias sia.config.Placement ["below"|"above", "start"|"end"|"cursor"]|"start"|"end"|"cursor"
--- @alias sia.config.ActionInput "require"|"ignore"
--- @alias sia.config.ActionMode "chat"|"diff"|"insert"|"hidden"

--- @class sia.config.Insert
--- @field placement (fun():sia.config.Placement)|sia.config.Placement
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
--- @field callback fun(ctx:sia.Context?, content:string[]?, usage:sia.Usage?)?
--- @field notify fun(string)?

--- @class sia.config.Instruction
--- @field role sia.config.Role
--- @field template boolean?
--- @field hide boolean?
--- @field mode "v"|"n"|nil
--- @field description ((fun(ctx:sia.Context?):string)|string)?
--- @field content ((fun(ctx: sia.Context?):string?)|string|string[]|sia.InstructionContent[])?
--- @field kind string?
--- @field ephemeral boolean?
--- @field tool_calls sia.ToolCall[]?
--- @field _tool_call sia.ToolCall?
--- TODO: Drop tool fields from instructions...

--- @alias sia.config.ToolExecute fun(arguments: table, conversation: sia.Conversation, callback: fun(opts: sia.ToolResult?), cancellable: sia.Cancellable?)
--- @class sia.config.Tool
--- @field name string
--- @field description string
--- @field system_prompt string?
--- @field allow_parallel (fun(conv: sia.Conversation, args: table):boolean)?
--- @field message string|(fun(args:table):string)?
--- @field parameters table<string, sia.ToolParameter>?
--- @field is_available (fun():boolean)?
--- @field required string[]?
--- @field execute sia.config.ToolExecute
--- @field custom sia.config.ToolCustom? if set, this is a custom tool with non-JSON output

--- Custom tool format definition (e.g. grammar-constrained output)
--- @class sia.config.ToolCustom
--- @field format { type: string, syntax: string?, definition: string? }?

--- @class sia.config.Action
--- @field system (string|sia.config.Instruction)[]?
--- @field instructions (string|sia.config.Instruction)[]
--- @field modify_instructions (fun(instructions:(string|sia.config.Instruction|(fun():sia.config.Instruction[]))[], ctx: sia.ActionContext):nil)?
--- @field tools (fun(model: sia.Model):sia.config.Tool[])?
--- @field ignore_tool_confirm boolean?
--- @field model (string|{name: string})?
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
--- @field temperature number
--- @field icons sia.IconSet?
--- @field context sia.config.Context?
--- @field context_management sia.config.ContextManagement?
--- @field actions table<"diff"|"chat"|"insert", sia.config.Action>
--- @field chat sia.config.Chat
--- @field diff sia.config.Diff
--- @field insert sia.config.Insert
--- @field hidden sia.config.Hidden
--- @field file_ops {trash: boolean?, restrict_to_project_root: boolean?, create_dirs_on_rename: boolean?}?
--- @field ui sia.config.Settings.Ui?
--- @field shell sia.config.Shell?

--- @class sia.config.Shell
--- @field command string?
--- @field args string[]|fun():string[]?
--- @field shell sia.config.Shell?

--- @alias sia.config.Models table<string, [string, string]>
--- @alias sia.config.Embeddings table<string, [string, string]>

--- @class sia.config.Provider
--- @field base_url string
--- @field chat_endpoint string
--- @field embedding_endpoint string?
--- @field api_key fun():string?
--- @field process_usage (fun(obj:table):sia.Usage?)?
--- @field process_response fun(json:table):string?
--- @field process_embeddings (fun(json:table):number[][])?
--- @field prepare_messages fun(data: table, model:string, prompt:sia.PreparedMessage[])
--- @field prepare_tools fun(data: table, tools:sia.Tool[])
--- @field prepare_parameters fun(data: table, model: table)?
--- @field prepare_embedding fun(data: table, strings: string[], model: sia.Model)?
--- @field get_headers (fun(api_key:string?, messages:sia.PreparedMessage[]?):string[])?
--- @field new_stream fun(strategy: sia.Strategy):sia.ProviderStream
--- @field get_stats fun(callback:fun(stats: sia.conversation.Stats), conversation: sia.Conversation)?

--- @class sia.config.Options
--- @field models sia.config.Models
--- @field embeddings sia.config.Embeddings?
--- @field instructions table<string, sia.config.Instruction|sia.config.Instruction[]>
--- @field settings sia.config.Settings
--- @field actions table<string, sia.config.Action>
--- @field providers table<string, sia.config.Provider>
M._raw_options = {
  providers = {},
  models = {
    ["zai/glm-4.5"] = { "zai", "GLM-4.5", context_window = 128000 },
    ["zai/glm-4.6"] = { "zai", "GLM-4.6", context_window = 128000 },
    ["openai/gpt-5.2"] = {
      "openai_responses",
      "gpt-5.2",
      can_reason = true,
      context_window = 400000,
    },
    ["openai/gpt-5.2-codex"] = {
      "openai_responses",
      "gpt-5.2-codex",
      can_reason = true,
      context_window = 400000,
    },
    ["openai/gpt-5.1"] = {
      "openai_responses",
      "gpt-5.1",
      can_reason = true,
      context_window = 400000,
    },
    ["openai/gpt-5.1-codex"] = {
      "openai_responses",
      "gpt-5.1-codex",
      can_reason = true,
      context_window = 400000,
    },
    ["openai/gpt-5"] = { "openai_responses", "gpt-5", context_window = 400000 },
    ["openai/gpt-5-codex"] = {
      "openai_responses",
      "gpt-5-codex",
      context_window = 400000,
    },
    ["openai/gpt-4.1"] = { "openai", "gpt-4.1", context_window = 1047576 },
    ["codex/gpt-5.3-codex"] = {
      "codex",
      "gpt-5.3-codex",
      can_reason = true,
      context_window = 400000,
    },
    ["codex/gpt-5.2-codex"] = {
      "codex",
      "gpt-5.2-codex",
      can_reason = true,
      context_window = 400000,
    },
    ["codex/gpt-5.2"] = {
      "codex",
      "gpt-5.2",
      can_reason = true,
      context_window = 400000,
    },
    ["codex/gpt-5.1-codex"] = {
      "codex",
      "gpt-5.1-codex",
      can_reason = true,
      context_window = 400000,
    },
    ["codex/gpt-5.1-codex-mini"] = {
      "codex",
      "gpt-5.1-codex-mini",
      can_reason = true,
      context_window = 400000,
    },
    ["copilot/gpt-4.1"] = { "copilot", "gpt-4.1", context_window = 128000 },
    ["copilot/gpt-5.2"] = { "copilot", "gpt-5.2", context_window = 128000 },
    ["copilot/gpt-5-mini"] = { "copilot", "gpt-5-mini", context_window = 128000 },
    ["copilot/gpt-5.2-codex"] = {
      "copilot_responses",
      "gpt-5.2-codex",
      can_reason = true,
      context_window = 128000,
    },
    ["copilot/claude-haiku-4.5"] = {
      "copilot",
      "claude-haiku-4.5",
      context_window = 128000,
    },
    ["copilot/claude-opus-4.6"] = {
      "copilot",
      "claude-opus-4.6",
      context_window = 128000,
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
    },
    ["copilot/gemini-3-pro"] = {
      "copilot",
      "gemini-3-pro-preview",
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
  instructions = {},
  --- @type sia.config.Settings
  settings = {
    model = "openai/gpt-5.2",
    fast_model = "openai/gpt-4.1",
    plan_model = "openai/gpt-5.2",
    embedding_model = "openai/text-embedding-3-small",
    icons = "emoji",
    temperature = 0.3,
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
      approval = {
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
        temperature = 0.2,
        system = { "insert_system" },
        instructions = {
          require("sia.instructions").current_buffer({
            show_line_numbers = true,
            include_cursor = true,
          }),
        },
        tools = function()
          local tools = require("sia.tools")
          return { tools.grep, tools.read, tools.glob }
        end,
      },
      diff = {
        mode = "diff",
        input = "require",
        temperature = 0.2,
        system = { "diff_system" },
        instructions = {
          require("sia.instructions").current_buffer({
            show_line_numbers = true,
            include_cursor = true,
          }),
          require("sia.instructions").current_context({
            show_line_numbers = true,
            fences = false,
          }),
        },
        tools = function()
          local tools = require("sia.tools")
          return { tools.grep, tools.read, tools.glob }
        end,
      },
      --- @type sia.config.Action
      chat = {
        mode = "chat",
        temperature = 0.1,
        system = {
          "model_system",
          "system_info",
          "directory_structure",
          "agents_md",
        },
        instructions = {
          "visible_buffers",
          "current_context",
        },
        tools = function(model)
          local tools = require("sia.tools")
          local all = {
            tools.ask_user,
            tools.grep,
            tools.edit,
            tools.write,
            tools.insert,
            tools.read,
            tools.glob,
            tools.agent,
            tools.diagnostics,
            tools.bash,
            tools.websearch,
            tools.write_todos,
            tools.read_todos,
            tools.memory,
          }
          if model:api_name():match("gpt%-5") then
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
      temperature = 0.3,
      system = {
        "prose_system",
        "system_info",
        "directory_structure",
        "agents_md",
      },
      instructions = {
        "visible_buffers",
        "current_context",
      },
      tools = function(model)
        local tools = require("sia.tools")
        local all = {
          tools.ask_user,
          tools.grep,
          tools.edit,
          tools.write,
          tools.insert,
          tools.read,
          tools.glob,
          tools.diagnostics,
          tools.bash,
          tools.websearch,
          tools.write_todos,
          tools.read_todos,
          tools.memory,
        }
        if model:api_name():match("gpt%-5") then
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
--- - Enriches the models table with aliases from local project config
--- - Returns the settings proxy for transparent local → global resolution
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
          spec = vim.tbl_extend("force", spec, model_overrides[base_name])
        end

        if alias_params then
          for k, v in pairs(alias_params) do
            if k ~= "name" then
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

function M.setup(options)
  if options and options.defaults ~= nil then
    vim.notify(
      "Sia: `defaults` has been renamed to `settings`. Please update your setup() config.",
      vim.log.levels.WARN
    )
  end
  M._raw_options = vim.tbl_deep_extend("force", {}, M._raw_options, options or {})
end

return M
