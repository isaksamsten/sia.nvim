local M = {}

--- @alias sia.PermissionOpts { auto_allow: integer}|{deny: boolean, reason: string[]?}|{ask: boolean}
--- @alias sia.PermissionAllowRule { arguments: table<string, string[]>, choice: integer? }
--- @alias sia.PermissionAllowCandidate { label: string, rule: sia.PermissionAllowRule }

--- @class sia.ActiveMode
--- @field name string
--- @field definition sia.config.Mode
--- @field state table
--- @field _compiled_allow table<string, true|{arguments: table<string, vim.regex[]>}>?

--- Helper function for pattern matching
--- @param value string|any
--- @param regex vim.regex
--- @return boolean
local function matches_pattern(value, regex)
  local s = value
  if s == nil then
    s = ""
  elseif type(s) ~= "string" then
    s = tostring(s)
  end

  return regex:match_str(s) ~= nil
end

--- @param tool_perms table?
--- @return table[]
local function iter_rules(tool_perms)
  if type(tool_perms) ~= "table" then
    return {}
  end

  if vim.islist(tool_perms) then
    return tool_perms
  end

  return { tool_perms }
end

--- @param rule table
--- @param args table
--- @return boolean
local function rule_matches_any(rule, args)
  if not rule.arguments then
    return false
  end

  for key, patterns in pairs(rule.arguments) do
    local arg_value = args[key]
    for _, regex in ipairs(patterns) do
      if matches_pattern(arg_value, regex) then
        return true
      end
    end
  end

  return false
end

--- @param rule table
--- @param args table
--- @return boolean
local function rule_matches_all(rule, args)
  if not rule.arguments or vim.tbl_isempty(rule.arguments) then
    return false
  end

  for key, patterns in pairs(rule.arguments) do
    local found_match = false
    local arg_value = args[key]
    for _, regex in ipairs(patterns) do
      if matches_pattern(arg_value, regex) then
        found_match = true
        break
      end
    end
    if not found_match then
      return false
    end
  end

  return true
end

--- Generate a default deny reason message for a mode restriction.
--- @param mode_name string
--- @param tool_name string
--- @param kind "denied"|"restricted"
--- @return string[]
local function default_mode_deny_reason(mode_name, tool_name, kind)
  if kind == "denied" then
    return {
      string.format("OPERATION BLOCKED BY CURRENT MODE (%s)", mode_name),
      "",
      string.format("The tool '%s' is not available in %s mode.", tool_name, mode_name),
      "",
      "Use `exit_mode` to return to the previous mode if this tool is needed.",
    }
  else
    return {
      string.format("OPERATION RESTRICTED BY CURRENT MODE (%s)", mode_name),
      "",
      string.format(
        "The tool '%s' was called with arguments that are not permitted in %s mode.",
        tool_name,
        mode_name
      ),
      "",
      "This mode only allows specific argument patterns for this tool.",
      "Use `exit_mode` to return to the previous mode if you need unrestricted access.",
    }
  end
end

--- Build the deny reason for a mode, using the custom deny_message if defined.
--- @param mode sia.ActiveMode
--- @param tool_name string
--- @param args table
--- @param kind "denied"|"restricted"
--- @return string[]
local function mode_deny_reason(mode, tool_name, args, kind)
  if mode.definition.deny_message then
    return mode.definition.deny_message(tool_name, args, kind)
  end
  return default_mode_deny_reason(mode.name, tool_name, kind)
end

--- Compile the allow rules for a mode (lazy, cached on the mode instance).
--- Converts string patterns to vim.regex objects.
--- @param mode sia.ActiveMode
--- @return table<string, true|{arguments: table<string, vim.regex[]>}>
local function compile_mode_allow(mode)
  if mode._compiled_allow then
    return mode._compiled_allow
  end

  local compiled = {}
  local allow = mode.definition.permissions and mode.definition.permissions.allow
  if allow then
    for tool_name, rule in pairs(allow) do
      if rule == true then
        compiled[tool_name] = true
      elseif type(rule) == "table" and rule.arguments then
        local compiled_args = {}
        for param_name, patterns in pairs(rule.arguments) do
          compiled_args[param_name] = {}
          for _, pattern in ipairs(patterns) do
            table.insert(compiled_args[param_name], vim.regex("\\v" .. pattern))
          end
        end
        compiled[tool_name] = { arguments = compiled_args }
      end
    end
  end

  mode._compiled_allow = compiled
  return compiled
end

--- Check whether all argument patterns in a compiled allow rule match.
--- @param compiled_rule {arguments: table<string, vim.regex[]>}
--- @param args table
--- @return boolean
local function mode_allow_matches(compiled_rule, args)
  for param_name, regexes in pairs(compiled_rule.arguments) do
    local found = false
    local arg_value = args[param_name]
    for _, regex in ipairs(regexes) do
      if matches_pattern(arg_value, regex) then
        found = true
        break
      end
    end
    if not found then
      return false
    end
  end
  return true
end

--- Resolve permission for a tool call in the context of an active mode.
---
--- Resolution order:
---   1. Tool in deny list then deny
---   2. Tool in allow:
---      a. rule is `true` then auto_allow
---      b. args match patterns then auto_allow
---      c. args don't match then deny (restricted)
---   3. Tool not mentioned then nil and fall through to global permissions
---
--- @param mode sia.ActiveMode
--- @param tool_name string
--- @param args table
--- @return sia.PermissionOpts?
function M.resolve_mode_permission(mode, tool_name, args)
  local perms = mode.definition.permissions
  if not perms then
    return nil
  end

  if perms.deny then
    for _, denied_tool in ipairs(perms.deny) do
      if denied_tool == tool_name then
        return {
          deny = true,
          reason = mode_deny_reason(mode, tool_name, args, "denied"),
        }
      end
    end
  end

  if perms.allow and perms.allow[tool_name] ~= nil then
    local compiled = compile_mode_allow(mode)
    local rule = compiled[tool_name]

    if rule == true then
      return { auto_allow = 1 }
    end

    if rule and mode_allow_matches(rule, args) then
      return { auto_allow = 1 }
    end

    return {
      deny = true,
      reason = mode_deny_reason(mode, tool_name, args, "restricted"),
    }
  end

  return nil
end

--- Create a new active mode instance.
--- @param name string
--- @param definition sia.config.Mode
--- @param ctx sia.Context?
--- @return sia.ActiveMode
function M.create_active_mode(name, definition, ctx)
  local state = {}
  if definition.init_state and ctx then
    state = definition.init_state(ctx) or {}
  end
  return {
    name = name,
    definition = definition,
    state = state,
    _compiled_allow = nil,
  }
end

--- Get permission configuration for a tool and its arguments
--- @param name string Tool name
--- @param args table Tool arguments
--- @return sia.PermissionOpts?
function M.resolve_permissions(name, args)
  local config = require("sia.config")
  local permission = config.options.settings.permission or {}

  for _, deny in ipairs(iter_rules(permission.deny and permission.deny[name])) do
    if rule_matches_any(deny, args) then
      return {
        deny = true,
        reason = {
          "OPERATION BLOCKED BY LOCAL CONFIGURATION",
          "",
          string.format(
            "The USER's local configuration denies executing the %s operation with the provided parameters.",
            name
          ),
          "",
          "IMPORTANT: Do not proceed with alternative approaches. Instead:",
          "1. Acknowledge that this operation is denied by policy",
          "2. Ask the USER if they want to adjust permissions or choose a different approach",
          "3. Wait for their guidance before taking any further action",
        },
      }
    end
  end

  for _, ask in ipairs(iter_rules(permission.ask and permission.ask[name])) do
    if rule_matches_any(ask, args) then
      return { ask = true }
    end
  end

  for _, allowed in ipairs(iter_rules(permission.allow and permission.allow[name])) do
    if rule_matches_all(allowed, args) then
      return { auto_allow = allowed.choice or 1 }
    end
  end

  return nil
end

--- @param name string
--- @param rule sia.PermissionAllowRule
--- @return string?
function M.persist_allow_rule(name, rule)
  if type(rule) ~= "table" then
    return nil
  end

  if type(rule.arguments) ~= "table" or vim.tbl_isempty(rule.arguments) then
    return nil
  end

  local updated, path = require("sia.config").update_auto_config(function(json)
    json.permission = json.permission or {}
    json.permission.allow = json.permission.allow or {}

    local existing = json.permission.allow[name]
    local new_rule = vim.deepcopy(rule)

    if existing == nil then
      json.permission.allow[name] = new_rule
      return
    end

    if vim.islist(existing) then
      for _, candidate in ipairs(existing) do
        if vim.deep_equal(candidate, new_rule) then
          return
        end
      end
      table.insert(existing, new_rule)
      return
    end

    if vim.deep_equal(existing, new_rule) then
      return
    end

    json.permission.allow[name] = { existing, new_rule }
  end)

  if not updated then
    return nil
  end

  return path
end

return M
