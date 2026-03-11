local M = {}

local State = {
  BEFORE_FRONTMATTER = 1,
  IN_FRONTMATTER = 2,
  IN_SYSTEM_PROMPT = 3,
}

--- @class sia.agents.registry.AgentDef
--- @field name string             relative path stem, e.g. "coder" or "code/review"
--- @field description string
--- @field require_confirmation boolean
--- @field tools string[]
--- @field model string?
--- @field system_prompt string[]
--- @field filepath string

--- Derive an agent name from its filepath and the base directory it was found in.
--- The name is the path relative to base_dir with the .md extension stripped.
--- Example: base_dir=/cfg/sia/agents, filepath=/cfg/sia/agents/code/review.md → "code/review"
--- @param base_dir string
--- @param filepath string
--- @return string
local function name_from_path(base_dir, filepath)
  local prefix = base_dir:sub(-1) == "/" and base_dir or (base_dir .. "/")
  local rel = filepath:sub(#prefix + 1):gsub("%.md$", "")
  return rel
end

--- Parse a .md agent file with YAML frontmatter.
--- The frontmatter must contain:
---   description: string  (required)
---   tools:       list    (required)
---   model:       string  (optional)
---   require_confirmation: bool (optional, default true)
--- Everything after the closing --- is used as the system prompt.
--- The agent name is derived from the file path, not the frontmatter.
---
--- @param filepath string  Absolute path to the .md file
--- @param name string      Name derived from the file path (passed by caller)
--- @return sia.agents.registry.AgentDef? agent
--- @return string|nil error
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
  return {
    name = name,
    description = metadata.description,
    require_confirmation = require_confirmation,
    tools = metadata.tools,
    model = model,
    system_prompt = system_prompt,
    filepath = filepath,
  }
end

--- Get the default user-level agents directory (~/.config/sia/agents/)
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

--- Recursively scan a directory for *.md agent files.
--- Each file's name is its path relative to base_dir with .md stripped,
--- e.g. base_dir/code/review.md → name "code/review".
--- @param base_dir string
--- @param error_report boolean?
--- @return table<string, sia.agents.registry.AgentDef>
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
--- @return table<string, sia.agents.registry.AgentDef> agents
function M.get_agents(error_report)
  local enabled_names = get_agents_config()

  if #enabled_names == 0 then
    return {}
  end

  -- Build lookup set
  local enabled_set = {}
  for _, name in ipairs(enabled_names) do
    enabled_set[name] = true
  end

  --- @type table<string, sia.agents.registry.AgentDef>
  local agents = {}

  -- 1. Local project agents take highest priority
  local local_dir = get_project_agents_dir()
  if local_dir then
    for name, agent in pairs(scan_agents_dir(local_dir, error_report)) do
      if enabled_set[name] then
        agents[name] = agent
      end
    end
  end

  -- 2. Global agents fill in any gaps
  -- Use the exported function for the tests...
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
--- @return sia.agents.registry.AgentDef?
function M.get_agent(name)
  return M.get_agents()[name]
end

M._parse_agent_file = parse_agent_file
M._name_from_path = name_from_path
M._get_default_agents_dir = get_default_agents_dir

return M
