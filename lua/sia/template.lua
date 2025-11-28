--- Simple templating engine for Sia
--- Supports variable substitution, conditional blocks, and loops
---
--- Syntax:
---   {{variable}}           - Variable substitution
---   {% if condition %}     - Conditional start
---   {% elseif condition %} - Conditional branch
---   {% else %}             - Conditional fallback
---   {% end %}              - Block end (for if/for)
---   {% for item in list %} - Loop start
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
---
--- Loops support:
---   - Iterate over arrays: {% for tool in tools %}{{tool}}{% end %}
---   - Access properties: {% for user in users %}{{user.name}}{% end %}
---   - Nested loops are supported

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

local function join(tbl, delim)
  return table.concat(tbl, delim or " ")
end

--- Create environment for template evaluation
--- @param context table Base context
--- @param loop_vars table|nil Additional loop variables
--- @return table Environment metatable
local function create_env(context, loop_vars)
  local env_vars = {
    contains = contains,
    contains_pattern = contains_pattern,
    join = join,
  }

  if loop_vars then
    for k, v in pairs(loop_vars) do
      env_vars[k] = v
    end
  end

  return setmetatable(env_vars, {
    __index = function(_, key)
      if loop_vars and loop_vars[key] ~= nil then
        return loop_vars[key]
      end
      if context[key] ~= nil then
        return context[key]
      end
      if key == "ipairs" or key == "pairs" or key == "type" or key == "tostring" then
        return _G[key]
      end
      return nil
    end,
  })
end

--- @return string
local function render(template, context, loop_vars)
  local env = create_env(context, loop_vars)
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
        table.insert(block_stack, { type = "if", any_branch_taken = value })
        in_block = value
        next_pos = ctrl_end + 1
        if template:sub(next_pos, next_pos) == "\n" then
          next_pos = next_pos + 1
        end
      elseif directive:match("^elseif%s+") then
        if #block_stack == 0 or block_stack[#block_stack].type ~= "if" then
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
        next_pos = ctrl_end + 1
        if template:sub(next_pos, next_pos) == "\n" then
          next_pos = next_pos + 1
        end
      elseif directive == "else" then
        if #block_stack == 0 then
          error("else without matching if/for")
        end
        local block_state = block_stack[#block_stack]
        if block_state.type == "if" then
          in_block = not block_state.any_branch_taken
        else
          error("else not supported in for loops")
        end
        next_pos = ctrl_end + 1
        if template:sub(next_pos, next_pos) == "\n" then
          next_pos = next_pos + 1
        end
      elseif directive:match("^for%s+") then
        local var_name, list_expr = directive:match("^for%s+(%w+)%s+in%s+(.+)$")
        if not var_name or not list_expr then
          error("Invalid for loop syntax: " .. directive)
        end

        local loop_depth = 1
        local loop_start = ctrl_end + 1
        if template:sub(loop_start, loop_start) == "\n" then
          loop_start = loop_start + 1
        end
        local loop_end_pos = loop_start
        local end_tag_end = loop_start

        while end_tag_end <= #template and loop_depth > 0 do
          local next_ctrl_start, next_ctrl_end, next_ctrl_content =
            template:find("{%%(.-)%%}", end_tag_end)

          if not next_ctrl_start then
            error("Unclosed for loop")
          end

          local next_directive = vim.trim(next_ctrl_content)
          if next_directive:match("^for%s+") or next_directive:match("^if%s+") then
            loop_depth = loop_depth + 1
          elseif next_directive == "end" then
            loop_depth = loop_depth - 1
            if loop_depth == 0 then
              loop_end_pos = next_ctrl_start - 1
              end_tag_end = next_ctrl_end + 1
              if template:sub(end_tag_end, end_tag_end) == "\n" then
                end_tag_end = end_tag_end + 1
              end
              break
            end
          end

          end_tag_end = next_ctrl_end + 1
        end

        local list_fn, err = load("return " .. list_expr, "template", "t", env)
        if not list_fn then
          error("Template for loop error: " .. (err or "unknown"))
        end
        local ok, list = pcall(list_fn)
        if not ok or type(list) ~= "table" then
          list = {}
        end

        local loop_body = template:sub(loop_start, loop_end_pos)
        for _, item in ipairs(list) do
          local new_loop_vars = {}
          if loop_vars then
            for k, v in pairs(loop_vars) do
              new_loop_vars[k] = v
            end
          end
          new_loop_vars[var_name] = item
          local rendered = render(loop_body, context, new_loop_vars)
          if in_block then
            table.insert(result, rendered)
          end
        end

        next_pos = end_tag_end
      elseif directive == "end" then
        if #block_stack == 0 then
          error("end without matching if/for")
        end
        local block_state = table.remove(block_stack)
        in_block = true
        next_pos = ctrl_end + 1
        if template:sub(next_pos, next_pos) == "\n" then
          next_pos = next_pos + 1
        end
      else
        error("Unknown template directive: " .. directive)
      end
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

--- Parse template and render with context
--- @param template string Template string
--- @param context table Variables available in the template
--- @return string Rendered template
function M.render(template, context)
  if not template or type(template) ~= "string" then
    return template or ""
  end
  return render(template, context)
end

return M
