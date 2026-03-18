local M = {}

--- @type table<string, {mtime: string, json: table}?>
local config_cache = {}

--- @type table<string, {mtime: string, json: table}?>
local auto_config_cache = {}

--- @param stat {mtime:{sec:integer?, nsec:integer?}}
--- @return string
local function cache_mtime(stat)
  return string.format("%s:%s", stat.mtime.sec or 0, stat.mtime.nsec or 0)
end

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

    local validate_tool_perms
    validate_tool_perms = function(tool_perms, path, section_name)
      if type(tool_perms) ~= "table" then
        return false, path .. " must be an object, got " .. type(tool_perms)
      end

      if section_name == "allow" and vim.islist(tool_perms) then
        for i, rule in ipairs(tool_perms) do
          local ok, err =
            validate_tool_perms(rule, string.format("%s[%d]", path, i), section_name)
          if not ok then
            return false, err
          end
        end
        return true
      end

      if not tool_perms.arguments then
        return false, path .. " must have an 'arguments' field"
      end

      if type(tool_perms.arguments) ~= "table" then
        return false,
          path .. ".arguments must be an object, got " .. type(tool_perms.arguments)
      end

      for param_name, patterns in pairs(tool_perms.arguments) do
        local arg_path = path .. ".arguments." .. param_name
        local ok, err = validate_permission_patterns(patterns, arg_path)
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
            path .. ".choice must be a positive integer, got " .. type(
              tool_perms.choice
            )
        end
      end

      return true
    end

    for section_name, section in pairs(permission) do
      if type(section) ~= "table" then
        return false,
          "permission." .. section_name .. " must be an object, got " .. type(section)
      end

      for tool_name, tool_perms in pairs(section) do
        local path = "permission." .. section_name .. "." .. tool_name
        local ok, err = validate_tool_perms(tool_perms, path, section_name)
        if not ok then
          return false, err
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

--- @param local_config string
--- @return table?, string?
local function read_local_config_file(local_config)
  local read_ok, file_content = pcall(vim.fn.readfile, local_config)
  if not read_ok then
    return nil,
      string.format("failed to read config file %s: %s", local_config, file_content)
  end

  local content = table.concat(file_content, " ")
  local decode_ok, json = pcall(vim.json.decode, content)
  if not decode_ok then
    return nil, string.format("invalid json %s: %s", local_config, json)
  end

  if type(json) ~= "table" then
    return nil, string.format("%s expect json object, got %s", local_config, type(json))
  end

  return json
end

--- @param json table
--- @param local_config string
--- @return boolean, string?
local function validate_local_config_json(json, local_config)
  local has_failed = false
  local error_message = nil

  local function validate_with(fun, ...)
    if not has_failed then
      local ok, err = fun(...)
      if not ok then
        error_message = string.format("%s: %s", local_config, err)
        has_failed = true
      end
    end
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

  return not has_failed, error_message
end

--- @return string?
local function get_local_config_root()
  return vim.fs.root(0, ".sia")
end

--- @param root string
--- @return string
local function local_config_path(root)
  return vim.fs.joinpath(root, ".sia", "config.json")
end

--- @param root string
--- @return string
local function auto_config_path(root)
  return vim.fs.joinpath(root, ".sia", "auto.json")
end

--- @return string
function M.get_local_config_path()
  local root = get_local_config_root()
  if not root then
    root = require("sia.utils").detect_project_root(vim.fn.getcwd())
  end
  return local_config_path(root)
end

--- @return string
function M.get_auto_config_path()
  local root = get_local_config_root()
  if not root then
    root = require("sia.utils").detect_project_root(vim.fn.getcwd())
  end
  return auto_config_path(root)
end

--- @param root string?
function M.invalidate_local_config(root)
  if root then
    config_cache[root] = nil
    auto_config_cache[root] = nil
    return
  end

  config_cache = {}
  auto_config_cache = {}
end

--- @param mutator fun(json: table)
--- @return table?, string?
function M.update_auto_config(mutator)
  local auto_path = M.get_auto_config_path()
  local root = vim.fn.fnamemodify(auto_path, ":h:h")
  local json = {}
  local stat = vim.uv.fs_stat(auto_path)
  if stat then
    local existing, _ = read_local_config_file(auto_path)
    json = existing or {}
  end

  local updated = vim.deepcopy(json)
  mutator(updated)
  local ok, err = validate_local_config_json(vim.deepcopy(updated), auto_path)
  if not ok then
    return nil, err
  end

  vim.fn.mkdir(vim.fn.fnamemodify(auto_path, ":h"), "p")
  local write_ok, write_err =
    pcall(vim.fn.writefile, { vim.json.encode(updated) }, auto_path)
  if not write_ok then
    return nil,
      string.format("failed to write auto config file %s: %s", auto_path, write_err)
  end

  M.invalidate_local_config(root)
  return updated, auto_path
end

--- Merge permission.allow rules from auto.json into the local config.
--- Auto rules are appended to user rules; user deny/ask take precedence.
--- @param user_json table? The user's config.json (may be nil)
--- @param auto_json table The auto.json content
--- @return table The merged config
local function merge_auto_permissions(user_json, auto_json)
  local merged = user_json and vim.deepcopy(user_json) or {}

  local auto_perm = auto_json.permission
  if not auto_perm then
    return merged
  end

  merged.permission = merged.permission or {}

  for section_name, section in pairs(auto_perm) do
    if section_name == "allow" then
      merged.permission.allow = merged.permission.allow or {}
      for tool_name, auto_rules in pairs(section) do
        local existing = merged.permission.allow[tool_name]
        if existing == nil then
          merged.permission.allow[tool_name] = vim.deepcopy(auto_rules)
        else
          local existing_list = vim.islist(existing) and existing or { existing }
          local auto_list = vim.islist(auto_rules) and auto_rules or { auto_rules }
          for _, auto_rule in ipairs(auto_list) do
            local found = false
            for _, ex_rule in ipairs(existing_list) do
              if vim.deep_equal(ex_rule, auto_rule) then
                found = true
                break
              end
            end
            if not found then
              table.insert(existing_list, vim.deepcopy(auto_rule))
            end
          end
          merged.permission.allow[tool_name] = existing_list
        end
      end
    else
      merged.permission[section_name] = merged.permission[section_name]
        or vim.deepcopy(section)
    end
  end

  return merged
end

--- @return sia.LocalConfig?
function M.get_local_config()
  local root = get_local_config_root()
  if not root then
    return nil
  end

  local user_config_file = local_config_path(root)
  local auto_config_file = auto_config_path(root)
  local user_stat = vim.uv.fs_stat(user_config_file)
  local auto_stat = vim.uv.fs_stat(auto_config_file)

  if not user_stat and not auto_stat then
    return nil
  end

  local user_mtime = user_stat and cache_mtime(user_stat) or "nil"
  local auto_mtime = auto_stat and cache_mtime(auto_stat) or "nil"
  local combined_mtime = user_mtime .. "+" .. auto_mtime

  local cache = config_cache[root]
  if cache and combined_mtime == cache.mtime then
    return cache.json
  end

  local user_json = nil
  if user_stat then
    local json, err = read_local_config_file(user_config_file)
    if not json then
      vim.notify("sia: " .. err, vim.log.levels.ERROR)
      return nil
    end
    user_json = json
  end

  local auto_json = nil
  if auto_stat then
    auto_json, _ = read_local_config_file(auto_config_file)
  end

  local merged
  if auto_json then
    merged = merge_auto_permissions(user_json, auto_json)
  else
    merged = user_json or {}
  end

  local ok, validation_err = validate_local_config_json(merged, user_config_file)
  if not ok then
    vim.notify("sia: " .. validation_err, vim.log.levels.ERROR)
    return nil
  end

  merged.model = normalize_model_config(merged.model)
  merged.fast_model = normalize_model_config(merged.fast_model)
  merged.plan_model = normalize_model_config(merged.plan_model)

  config_cache[root] = { mtime = combined_mtime, json = merged }
  return merged
end

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

--- @alias sia.config.Role "user"|"system"|"assistant"|"tool"
--- @alias sia.config.Placement ["below"|"above", "start"|"end"|"cursor"]|"start"|"end"|"cursor"
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
--- @field exit_prompt string|fun(state: table, summary: string):string
--- @field init_state (fun(ctx: sia.Context): table)?

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
--- @field callback fun(buf:number?, opts: { error: string?, content:string[]?, usage:sia.Usage?})?
--- @field notify fun(string)?

--- @class sia.config.Instruction
--- @field role sia.config.Role
--- @field template boolean?
--- @field hide boolean?
--- @field mode "v"|"n"|nil
--- @field description ((fun(ctx:sia.Context?):string)|string)?
--- @field content ((fun(ctx: sia.Context?):string?)|string|string[]|sia.Content[])?
--- @field kind string?
--- @field ephemeral boolean?
--- @field tool_calls sia.ToolCall[]?
--- @field _tool_call sia.ToolCall?
--- @field display_content string?
--- TODO: Drop tool fields from instructions...

--- @alias sia.config.ToolExecute fun(arguments: table, conversation: sia.Conversation, callback: fun(opts: sia.ToolResult?), cancellable: sia.Cancellable?, turn_id: string?)
--- @class sia.config.Tool
--- @field name string
--- @field module string?
--- @field description string
--- @field system_prompt string?
--- @field allow_parallel (fun(conv: sia.Conversation, args: table):boolean)?
--- @field message string|(fun(args:table):string)?
--- @field parameters table<string, sia.ToolParameter>?
--- @field is_available (fun(support: sia.config.Support?):boolean)?
--- @field required string[]?
--- @field execute sia.config.ToolExecute
--- @field custom sia.config.ToolCustom? if set, this is a custom tool with non-JSON output

--- Custom tool format definition (e.g. grammar-constrained output)
--- @class sia.config.ToolCustom
--- @field format { type: string, syntax: string?, definition: string? }?

--- @class sia.config.DefaultAction
--- @field system (string|sia.config.Instruction)[]?
--- @field instructions (string|sia.config.Instruction)[]
--- @field modify_instructions (fun(instructions:(string|sia.config.Instruction|(fun():sia.config.Instruction[]))[], ctx: sia.ActionContext):nil)?
--- @field tools (fun(model: sia.Model):sia.config.Tool[])?
--- @field ignore_tool_confirm boolean?
--- @field model (string|{name: string})?
--- @field input sia.config.ActionInput?
--- @field enabled (fun():boolean)|boolean?
--- @field capture nil|(fun(arg: sia.ActionContext):[number, number])
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
--- @field prepare_messages fun(data: table, model:string, prompt:sia.PreparedMessage[])
--- @field prepare_tools fun(data: table, tools:sia.Tool[])
--- @field prepare_parameters fun(data: table, model: sia.Model)?
--- @field prepare_embedding fun(data: table, strings: string[], model: sia.Model)?
--- @field get_headers (fun(model: sia.Model, api_key:string?, messages:sia.PreparedMessage[]? ):string[])?
--- @field translate_http_error (fun(code: integer):string?)?
--- @field on_http_error (fun(code: integer):boolean)?
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
        system = { "insert_system" },
        instructions = {
          require("sia.instructions").current_buffer({
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
          return { tools.grep, tools.view, tools.glob }
        end,
      },
      --- @type sia.config.ChatAction
      chat = {
        mode = "chat",
        system = {
          "model_system",
        },
        modes = {
          plan = require("sia.modes").plan,
        },
        instructions = {
          "system_info",
          "directory_structure",
          "agents_md",
          "visible_buffers",
          "current_context",
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

function M.setup(options)
  if options and options.defaults ~= nil then
    vim.notify(
      "sia: `defaults` has been renamed to `settings`. Please update your setup() config.",
      vim.log.levels.WARN
    )
  end
  M._raw_options = vim.tbl_deep_extend("force", {}, M._raw_options, options or {})
end

return M
