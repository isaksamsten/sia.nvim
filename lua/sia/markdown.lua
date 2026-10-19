local M = {}

local State = {
  BEFORE_FRONTMATTER = 1,
  IN_FRONTMATTER = 2,
  IN_BODY = 3,
}

--- Parse the YAML subset used by frontmatter: mappings, lists, and booleans.
--- Indented mappings allow structured model selections in agent definitions.
--- @param lines string[]
--- @return table
function M.parse_yaml_frontmatter(lines)
  local result = {}
  local stack = { { indent = -1, value = result } }

  for _, line in ipairs(lines) do
    local whitespace, content = line:match("^(%s*)(%S.*)$")
    if content and content:sub(1, 1) ~= "#" then
      local indent = #whitespace
      while #stack > 1 and indent <= stack[#stack].indent do
        table.remove(stack)
      end
      local parent = stack[#stack].value
      local list_item = content:match("^%-%s+(.+)$")
      if list_item and #stack > 1 then
        table.insert(parent, list_item)
      else
        local key, value = content:match("^(%w[%w_]*):%s*(.-)%s*$")
        if key then
          if value == "" then
            parent[key] = {}
            table.insert(stack, { indent = indent, value = parent[key] })
          elseif value == "true" then
            parent[key] = true
          elseif value == "false" then
            parent[key] = false
          else
            parent[key] = value
          end
        end
      end
    end
  end

  return result
end

--- @class sia.markdown.Document
--- @field metadata table
--- @field body string[]

--- Split markdown content into frontmatter and body, then parse metadata.
--- @param lines string[]
--- @return sia.markdown.Document
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
--- @return sia.markdown.Document
function M.read_frontmatter_file(filepath)
  return M.parse_frontmatter_document(vim.fn.readfile(filepath))
end

return M
