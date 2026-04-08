local M = {}

local State = {
  BEFORE_FRONTMATTER = 1,
  IN_FRONTMATTER = 2,
  IN_SYSTEM_PROMPT = 3,
}

--- @class sia.agents.registry.Agent
--- @field name string
--- @field description string
--- @field require_confirmation boolean
--- @field interactive boolean
--- @field tools string[]
--- @field model string?
--- @field system_prompt string[]
--- @field filepath string

--- @param base_dir string
--- @param filepath string
--- @return string
local function name_from_path(base_dir, filepath)
  local prefix = base_dir:sub(-1) == "/" and base_dir or (base_dir .. "/")
  local rel = filepath:sub(#prefix + 1):gsub("%.md$", "")
  return rel
end

--- @param filepath string
--- @param name string
--- @return sia.agents.registry.Agent?
--- @return string|nil
local function parse_agent_file(filepath, name)
  local file = vim.fn.readfile(filepath)
  --- @type string[]
  local frontmatter = {}
  --- @type string[]
  local system_prompt = {}
  local state = State.BEFORE_FRONTMATTER

  for _, line in ipairs(file) do
    if line == "---" and state == State.BEFORE_FRONTMATTER then
      state = State.IN_FRONTMATTER
    elseif line == "---" and state == State.IN_FRONTMATTER then
      state = State.IN_SYSTEM_PROMPT
    elseif state == State.IN_FRONTMATTER then
      table.insert(frontmatter, line)
    elseif state == State.IN_SYSTEM_PROMPT then
      table.insert(system_prompt, line)
    end
  end

  if #frontmatter == 0 then
    return nil, "Invalid format: missing frontmatter"
  end

  if #system_prompt == 0 then
    return nil, "Missing system prompt content"
  end

  local metadata = require("sia.utils").parse_yaml_frontmatter(frontmatter)

  if not metadata.description or type(metadata.description) ~= "string" then
    return nil, "Missing required field: description"
  end

  if not metadata.tools or type(metadata.tools) ~= "table" then
    return nil, "Missing or invalid required field: tools (must be a list)"
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

  local model = type(metadata.model) == "string" and metadata.model or nil
  --- @type sia.agents.registry.Agent
  return {
    name = name,
    description = metadata.description --[[@as string]],
    require_confirmation = require_confirmation --[[@as boolean]],
    tools = metadata.tools --[[@as string[] ]],
    model = model --[[@as string]],
    system_prompt = system_prompt,
    filepath = filepath,
    interactive = metadata.interactive == true,
  }
end

--- @return string
local function get_default_agents_dir()
  local config_dir = vim.env.XDG_CONFIG_HOME or vim.fs.joinpath(vim.env.HOME, ".config")
  return vim.fs.joinpath(config_dir, "sia", "agents")
end

--- Get the project-local agents directory (.sia/agents/) when available.
--- @return string?
local function get_project_agents_dir()
  local project_root = vim.fs.root(0, ".sia")
  if not project_root then
    return nil
  end
  return vim.fs.joinpath(project_root, ".sia", "agents")
end

--- @param base_dir string
--- @param error_report boolean?
--- @return table<string, sia.agents.registry.Agent>
local function scan_agents_dir(base_dir, error_report)
  local agents = {}

  local stat = vim.uv.fs_stat(base_dir)
  if not stat or stat.type ~= "directory" then
    return agents
  end

  local files = vim.fn.glob(vim.fs.joinpath(base_dir, "**", "*.md"), false, true)
  for _, f in ipairs(vim.fn.glob(vim.fs.joinpath(base_dir, "*.md"), false, true)) do
    table.insert(files, f)
  end

  local seen = {}
  for _, filepath in ipairs(files) do
    if not seen[filepath] then
      seen[filepath] = true
      local name = name_from_path(base_dir, filepath)
      local agent, err = parse_agent_file(filepath, name)
      if agent then
        agents[name] = agent
      elseif error_report ~= false then
        vim.notify(
          string.format("sia: failed to load agent from %s: %s", filepath, err),
          vim.log.levels.WARN
        )
      end
    end
  end

  return agents
end

--- Get the list of enabled agent names from project config
--- @return string[] agent_names
local function get_agents_config()
  local config = require("sia.config")
  return config.options.settings.agents or {}
end

--- Load all agent definitions, filtered by the enabled names in local config.
--- Resolution order (first match wins):
---   1. Local project .sia/agents/  (overrides global for same name)
---   2. Global ~/.config/sia/agents/
---
--- An agent is included only if its name appears in the local config `agents` array.
---
--- @param error_report boolean?
--- @return table<string, sia.agents.registry.Agent> agents
function M.get_agents(error_report)
  local enabled_names = get_agents_config()

  if #enabled_names == 0 then
    return {}
  end

  local enabled_set = {}
  for _, name in ipairs(enabled_names) do
    enabled_set[name] = true
  end

  --- @type table<string, sia.agents.registry.Agent>
  local agents = {}

  local local_dir = get_project_agents_dir()
  if local_dir then
    for name, agent in pairs(scan_agents_dir(local_dir, error_report)) do
      if enabled_set[name] then
        agents[name] = agent
      end
    end
  end

  local global_dir = M._get_default_agents_dir()
  for name, agent in pairs(scan_agents_dir(global_dir, error_report)) do
    if enabled_set[name] and not agents[name] then
      agents[name] = agent
    end
  end

  return agents
end

--- Get a single agent definition by name.
--- Respects the same resolution order as get_agents.
--- @param name string
--- @return sia.agents.registry.Agent?
function M.get_agent(name)
  return M.get_agents()[name]
end

M._parse_agent_file = parse_agent_file
M._name_from_path = name_from_path
M._get_default_agents_dir = get_default_agents_dir

return M
