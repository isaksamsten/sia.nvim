local M = {}

local State = {
  BEFORE_FRONTMATTER = 1,
  IN_FRONTMATTER = 2,
  IN_SYSTEM_PROMPT = 3,
}

--- @class sia.agent_registry.AgentDef
--- @field name string
--- @field description string
--- @field require_confirmation boolean
--- @field tools string[]?
--- @field model string?
--- @field system_prompt string[]
--- @field filepath string

--- @param filepath string Path to the markdown file
--- @param name string Agent name derived from relative path
--- @return sia.agent_registry.AgentDef? agent Agent definition or nil if parsing failed
--- @return string|nil error Error message if parsing failed
local function parse_agent_file(filepath, name)
  local file = vim.fn.readfile(filepath)
  --- @type string[]
  local frontmatter = {}

  --- @type string[]
  local system_prompt = {}
  local state = State.BEFORE_FRONTMATTER

  local current = 1
  while current <= #file do
    local current_line = file[current]
    if current_line == "---" and state == State.BEFORE_FRONTMATTER then
      state = 2
    elseif current_line == "---" and state == State.IN_FRONTMATTER then
      state = 3
    else
      if state == State.IN_FRONTMATTER then
        table.insert(frontmatter, current_line)
      elseif state == State.IN_SYSTEM_PROMPT then
        table.insert(system_prompt, current_line)
      end
    end
    current = current + 1
  end

  if #frontmatter == 0 then
    return nil, "Invalid format: missing frontmatter"
  end

  if #system_prompt == 0 then
    return nil, "Missing system prompt content"
  end

  local ok, metadata = pcall(vim.json.decode, table.concat(frontmatter, " "))
  if not ok then
    return nil, "Invalid JSON in frontmatter: " .. tostring(metadata)
  end

  if not metadata.description then
    return nil, "Missing required field: description"
  end
  if not metadata.tools or type(metadata.tools) ~= "table" then
    return nil, "Missing or invalid required field: tools (must be an array)"
  end
  if
    metadata.require_confirmation ~= nil
    and type(metadata.require_confirmation) ~= "boolean"
  then
    return nil, "Invalid optional field: require_confirmation (must be boolean)"
  end

  local require_confirmation = metadata.require_confirmation
  if require_confirmation == nil then
    require_confirmation = true
  end

  return {
    name = name,
    description = metadata.description,
    require_confirmation = require_confirmation,
    tools = metadata.tools,
    model = metadata.model,
    system_prompt = system_prompt,
    filepath = filepath,
  }
end

--- Load all agent definitions from .sia/agents/ directory
--- @param error_report boolean?
--- @return table<string, sia.agent_registry.AgentDef> agents Map of agent name to agent definition
function M.get_agent_definitions(error_report)
  local project_root = vim.fs.root(0, ".sia")
  if not project_root then
    return {}
  end
  local agents_dir = vim.fs.joinpath(project_root, ".sia", "agents")

  local stat = vim.uv.fs_stat(agents_dir)
  if not stat or stat.type ~= "directory" then
    return {}
  end

  local agents = {}
  local pattern = vim.fs.joinpath(agents_dir, "**", "*.md")
  local files = vim.fn.glob(pattern, false, true)

  for _, filepath in ipairs(files) do
    local rel_path = filepath:sub(#agents_dir + 2) -- +2 to skip the trailing slash
    local agent_name = rel_path:gsub("%.md$", "")

    local agent, err = parse_agent_file(filepath, agent_name)

    if agent then
      agents[agent_name] = agent
    else
      if error_report ~= false then
        vim.notify(
          string.format("Failed to load agent from %s: %s", filepath, err),
          vim.log.levels.WARN
        )
      end
    end
  end

  return agents
end

--- @param name string
--- @return sia.agent_registry.AgentDef?
function M.get_agent_definition(name)
  local agents = M.get_agent_definitions()
  return agents[name]
end

return M
