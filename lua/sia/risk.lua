local M = {}

--- @alias sia.RiskLevel "safe"|"info"|"warn"
--- @alias sia.RiskPatternDef {pattern: string, level: sia.RiskLevel}

--- Risk level ordering for comparison
local RISK_ORDER = {
  safe = 1,
  info = 2,
  warn = 3,
}

--- Compare two risk levels and return the higher one
--- @param level1 sia.RiskLevel
--- @param level2 sia.RiskLevel
--- @return sia.RiskLevel
local function max_risk_level(level1, level2)
  if RISK_ORDER[level1] > RISK_ORDER[level2] then
    return level1
  end
  return level2
end

--- Check if a value matches a pattern
--- @param value any
--- @param pattern string
--- @return boolean
local function matches_pattern(value, pattern)
  local s = value
  if s == nil then
    s = ""
  elseif type(s) ~= "string" then
    s = tostring(s)
  end

  return string.match(s, pattern) ~= nil
end

--- Get the risk level for a tool execution based on user configuration
--- @param tool_name string
--- @param args table
--- @param default_level sia.RiskLevel
--- @return sia.RiskLevel
function M.get_risk_level(tool_name, args, default_level)
  local config = require("sia.config")
  local lc = config.get_local_config()

  if not lc or not lc.risk or not lc.risk[tool_name] then
    return default_level
  end

  local risk_config = lc.risk[tool_name]
  if not risk_config.arguments then
    return default_level
  end

  local matched_level = nil

  for arg_name, pattern_defs in pairs(risk_config.arguments) do
    local arg_value = args[arg_name]

    for _, pattern_def in ipairs(pattern_defs) do
      if matches_pattern(arg_value, pattern_def.pattern) then
        if matched_level == nil then
          matched_level = pattern_def.level
        else
          matched_level = max_risk_level(matched_level, pattern_def.level)
        end
      end
    end
  end

  return matched_level or default_level
end

--- Check if a risk level allows auto-confirmation
--- @param level sia.RiskLevel
--- @return boolean
function M.allows_auto_confirm(level)
  return RISK_ORDER[level] <= RISK_ORDER.info
end

return M
