local M = {}

--- @alias sia.PermissionOpts { auto_allow: integer}|{deny: boolean}|{ask: boolean}
--- @alias sia.PatternDef string|{pattern: string, negate: boolean?}

--- Helper function for consistent pattern matching with negate support
--- @param value string|any
--- @param pattern_def sia.PatternDef
--- @return boolean
local function matches_pattern(value, pattern_def)
  local pattern, negate
  if type(pattern_def) == "string" then
    pattern = pattern_def
    negate = false
  else
    pattern = pattern_def.pattern
    negate = pattern_def.negate or false
  end

  local s = value
  if s == nil then
    s = ""
  elseif type(s) ~= "string" then
    s = tostring(s)
  end

  local matches = string.match(s, pattern)
  return (negate and not matches) or (not negate and matches)
end

--- Get permission configuration for a tool and its arguments
--- @param name string Tool name
--- @param args table Tool arguments
--- @return sia.PermissionOpts?
function M.get_permission(name, args)
  local config = require("sia.config")
  local lc = config.get_local_config()

  local permission = lc and lc.permission or {}
  -- If any argument is denied
  local deny = permission.deny and permission.deny[name] or {}
  if deny.arguments then
    for key, patterns in pairs(deny.arguments) do
      local arg_value = args[key]
      for _, pattern_def in ipairs(patterns) do
        if matches_pattern(arg_value, pattern_def) then
          return { deny = true }
        end
      end
    end
  end

  -- If any argument requires user confirmation
  local ask = permission.ask and permission.ask[name] or {}
  if ask.arguments then
    for key, patterns in pairs(ask.arguments) do
      local arg_value = args[key]
      for _, pattern_def in ipairs(patterns) do
        if matches_pattern(arg_value, pattern_def) then
          return { ask = true }
        end
      end
    end
  end

  --- If all arguments allow automatic confirmation
  local allowed = permission.allow and permission.allow[name] or {}
  if not allowed.arguments or vim.tbl_isempty(allowed.arguments) then
    return nil
  end

  for key, patterns in pairs(allowed.arguments) do
    local found_match = false
    local arg_value = args[key]
    for _, pattern_def in ipairs(patterns) do
      if matches_pattern(arg_value, pattern_def) then
        found_match = true
        break
      end
    end
    if not found_match then
      return nil
    end
  end

  return { auto_allow = allowed.choice or 1 }
end

return M
