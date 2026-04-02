--- Local project configuration (.sia/config.json + .sia/auto.json)
--- Handles reading, caching, validating and merging project-local config files.
local M = {}

--- @type table<string, {mtime: string, json: table}?>
local config_cache = {}

--- @param stat {mtime:{sec:integer?, nsec:integer?}}
--- @return string
local function cache_mtime(stat)
  return string.format("%s:%s", stat.mtime.sec or 0, stat.mtime.nsec or 0)
end

--- Lazy accessor for the raw options table in the main config module.
--- Avoids circular require at load time.
--- @return sia.config.Options
local function raw_options()
  return require("sia.config")._raw_options
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

      if not raw_options().actions[value] then
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
      if not raw_options().models[model_name] and not aliases[model_name] then
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

      if not raw_options().models[model_name] then
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

      if not raw_options().models[alias_def.name] then
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
    return
  end

  config_cache = {}
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
    local json, json_err = read_local_config_file(user_config_file)
    if not json then
      vim.notify("sia: " .. json_err, vim.log.levels.ERROR)
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

  local validation_ok, validation_err =
    validate_local_config_json(merged, user_config_file)
  if not validation_ok then
    vim.notify("sia: " .. validation_err, vim.log.levels.ERROR)
    return nil
  end

  merged.model = normalize_model_config(merged.model)
  merged.fast_model = normalize_model_config(merged.fast_model)
  merged.plan_model = normalize_model_config(merged.plan_model)

  config_cache[root] = { mtime = combined_mtime, json = merged }
  return merged
end

return M
