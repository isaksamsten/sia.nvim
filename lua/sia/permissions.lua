local M = {}

--- @alias sia.PermissionOpts { auto_allow: integer}|{deny: boolean}|{ask: boolean}
--- @alias sia.PermissionAllowRule { arguments: table<string, string[]>, choice: integer? }
--- @alias sia.PermissionAllowCandidate { label: string, rule: sia.PermissionAllowRule }

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

--- Get permission configuration for a tool and its arguments
--- @param name string Tool name
--- @param args table Tool arguments
--- @return sia.PermissionOpts?
function M.get_permission(name, args)
  local config = require("sia.config")
  local permission = config.options.settings.permission or {}

  for _, deny in ipairs(iter_rules(permission.deny and permission.deny[name])) do
    if rule_matches_any(deny, args) then
      return { deny = true }
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
