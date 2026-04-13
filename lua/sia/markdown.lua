local M = {}

local State = {
  BEFORE_FRONTMATTER = 1,
  IN_FRONTMATTER = 2,
  IN_BODY = 3,
}

--- Parse simple YAML frontmatter (flat key-value pairs and simple lists).
--- Supports:
---   key: value          -> result[key] = "value"
---   key:                -> result[key] stays unset until a list item follows
---   - item              -> appended to the most recently seen list key
---   bool: true/false    -> result[key] = true/false (Lua boolean)
--- @param lines string[]
--- @return table<string, string|string[]|boolean>
function M.parse_yaml_frontmatter(lines)
  local result = {}
  local current_key = nil

  for _, line in ipairs(lines) do
    local list_item = line:match("^%s+-%s+(.+)$")
    if list_item and current_key then
      if type(result[current_key]) ~= "table" then
        result[current_key] = {}
      end
      table.insert(result[current_key], list_item)
    else
      local key, value = line:match("^(%w[%w_]*):%s*(.-)%s*$")
      if key then
        current_key = key
        if value ~= "" then
          if value == "true" then
            result[key] = true
          elseif value == "false" then
            result[key] = false
          else
            result[key] = value
          end
        end
      end
    end
  end

  return result
end

--- @class sia.markdown.Document
--- @field metadata table<string, string|string[]|boolean>
--- @field body string[]

--- Split markdown content into frontmatter and body, then parse metadata.
--- @param lines string[]
--- @return sia.markdown.Document?
function M.parse_frontmatter_document(lines)
  --- @type string[]
  local frontmatter = {}
  --- @type string[]
  local body = {}
  local state = State.BEFORE_FRONTMATTER

  for _, line in ipairs(lines) do
    if line == "---" and state == State.BEFORE_FRONTMATTER then
      state = State.IN_FRONTMATTER
    elseif line == "---" and state == State.IN_FRONTMATTER then
      state = State.IN_BODY
    elseif state == State.IN_FRONTMATTER then
      table.insert(frontmatter, line)
    elseif state == State.IN_BODY then
      table.insert(body, line)
    end
  end

  if #frontmatter == 0 then
    error("Invalid format: missing frontmatter")
  end

  if #body == 0 then
    error("Missing markdown body")
  end

  return {
    metadata = M.parse_yaml_frontmatter(frontmatter),
    body = body,
  }
end

--- @param filepath string
--- @return sia.markdown.Document?
function M.read_frontmatter_file(filepath)
  return M.parse_frontmatter_document(vim.fn.readfile(filepath))
end

return M
