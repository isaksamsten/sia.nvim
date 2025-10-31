--- Simple templating engine for Sia
--- Supports variable substitution and conditional blocks
---
--- Syntax:
---   {{variable}}           - Variable substitution
---   {% if condition %}     - Conditional start
---   {% elseif condition %} - Conditional branch
---   {% else %}             - Conditional fallback
---   {% end %}              - Conditional end
---
--- Variables can be:
---   - Simple values: {{name}}
---   - Table access: {{user.name}}
---   - Function calls: {{get_tools()}}
---
--- Conditions support:
---   - Boolean expressions: {% if has_tools %}
---   - Comparisons: {% if count > 0 %}
---   - Logical operators: {% if has_tools and count > 0 %}
---   - Helper functions: {% if contains(tools, "read") %}

local M = {}

--- Helper function available in templates for checking if a table contains a value
--- @param tbl table
--- @param value any
--- @return boolean
local function contains(tbl, value)
  if type(tbl) ~= "table" then
    return false
  end
  for _, v in ipairs(tbl) do
    if v == value then
      return true
    end
  end
  return false
end

--- Helper function to check if a table contains a value matching a pattern
--- @param tbl table
--- @param pattern string
--- @return boolean
local function contains_pattern(tbl, pattern)
  if type(tbl) ~= "table" then
    return false
  end
  for _, v in ipairs(tbl) do
    if type(v) == "string" and v:match(pattern) then
      return true
    end
  end
  return false
end

--- Parse template and render with context
--- @param template string Template string
--- @param context table Variables available in the template
--- @return string Rendered template
function M.render(template, context)
  if not template or type(template) ~= "string" then
    return template or ""
  end

  local env = setmetatable({
    contains = contains,
    contains_pattern = contains_pattern,
  }, {
    __index = function(_, key)
      if context[key] ~= nil then
        return context[key]
      end
      if key == "ipairs" or key == "pairs" or key == "type" or key == "tostring" then
        return _G[key]
      end
      return nil
    end,
  })

  local result = {}
  local pos = 1
  local in_block = true
  local block_stack = {}

  while pos <= #template do
    local ctrl_start, ctrl_end, ctrl_content = template:find("{%%(.-)%%}", pos)

    local var_start, var_end, var_content = template:find("{{(.-)%}%}", pos)

    local next_pos
    if ctrl_start and (not var_start or ctrl_start < var_start) then
      if in_block and ctrl_start > pos then
        table.insert(result, template:sub(pos, ctrl_start - 1))
      end

      local directive = vim.trim(ctrl_content)

      if directive:match("^if%s+") then
        local condition = directive:match("^if%s+(.+)$")
        local fn, err = load("return " .. condition, "template", "t", env)
        if not fn then
          error("Template condition error: " .. (err or "unknown"))
        end
        local ok, value = pcall(fn)
        if not ok then
          value = false
        end
        table.insert(block_stack, { any_branch_taken = value })
        in_block = value
      elseif directive:match("^elseif%s+") then
        if #block_stack == 0 then
          error("elseif without matching if")
        end
        local block_state = block_stack[#block_stack]
        if not block_state.any_branch_taken then
          local condition = directive:match("^elseif%s+(.+)$")
          local fn = load("return " .. condition, "template", "t", env)
          if fn then
            local ok, value = pcall(fn)
            if ok and value then
              in_block = true
              block_state.any_branch_taken = true
            else
              in_block = false
            end
          end
        else
          in_block = false
        end
      elseif directive == "else" then
        if #block_stack == 0 then
          error("else without matching if")
        end
        local block_state = block_stack[#block_stack]
        in_block = not block_state.any_branch_taken
      elseif directive == "end" then
        if #block_stack == 0 then
          error("end without matching if")
        end
        table.remove(block_stack)
        in_block = true
      else
        error("Unknown template directive: " .. directive)
      end

      next_pos = ctrl_end + 1
    elseif var_start then
      if in_block and var_start > pos then
        table.insert(result, template:sub(pos, var_start - 1))
      end

      if in_block then
        local var_name = vim.trim(var_content)
        local fn, err = load("return " .. var_name, "template", "t", env)
        if not fn then
          error("Template variable error: " .. (err or "unknown"))
        end
        local ok, value = pcall(fn)
        if ok and value ~= nil then
          table.insert(result, tostring(value))
        end
      end

      next_pos = var_end + 1
    else
      if in_block then
        table.insert(result, template:sub(pos))
      end
      break
    end

    pos = next_pos
  end

  return table.concat(result)
end

return M
