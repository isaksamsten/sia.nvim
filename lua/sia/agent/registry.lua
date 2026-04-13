local M = {}
local markdown = require("sia.markdown")

--- @type table<string, {definition: sia.agents.registry.Agent?, error: string?}>
local agents = {}

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
local function parse_agent_file(filepath, name)
  local ok, document = pcall(markdown.read_frontmatter_file, filepath)
  if not document then
    return nil
  end

  local metadata = document.metadata
  local system_prompt = document.body

  if not metadata.description or type(metadata.description) ~= "string" then
    error("Missing required field: description")
  end

  if not metadata.tools or type(metadata.tools) ~= "table" then
    error("Missing or invalid required field: tools (must be a list)")
  end

  if
    metadata.require_confirmation ~= nil
    and type(metadata.require_confirmation) ~= "boolean"
  then
    error("Invalid optional field: require_confirmation (must be boolean)")
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
  local project_root = vim.fn.getcwd()
  return vim.fs.joinpath(project_root, ".sia", "agents")
end

--- @param base_dir string
local function scan_dir(base_dir)
  local stat = vim.uv.fs_stat(base_dir)
  if not stat or stat.type ~= "directory" then
    return
  end

  -- NOTE: We glob both **/*.md and *.md because some systems' ** doesn't match
  -- root-level files. The `seen` set below deduplicates.
  local files = vim.fn.glob(vim.fs.joinpath(base_dir, "**", "*.md"), false, true)
  for _, f in ipairs(vim.fn.glob(vim.fs.joinpath(base_dir, "*.md"), false, true)) do
    table.insert(files, f)
  end

  local seen = {}
  for _, filepath in ipairs(files) do
    if not seen[filepath] then
      seen[filepath] = true
      local name = name_from_path(base_dir, filepath)
      local ok, agent = pcall(parse_agent_file, filepath, name)
      if ok then
        agents[name] = { definition = agent }
      else
        agent[name] = { error = agent }
      end
    end
  end
end

function M.scan()
  local local_dir = get_project_agents_dir()
  local global_dir = M._get_default_agents_dir()
  if global_dir then
    scan_dir(global_dir)
  end
  if local_dir then
    scan_dir(local_dir)
  end
end

--- @param f (fun(agent: sia.agents.registry.Agent):boolean)?
--- @return sia.agents.registry.Agent[]
function M.filter(f)
  if f == nil then
    return agents
  end
  local filter = {}
  for _, agent in pairs(agents) do
    if not agent.error and (f == nil or f(agent.definition)) then
      table.insert(filter, agent.definition)
    end
  end
  return filter
end

--- @param name string
--- @return sia.agents.registry.Agent?
function M.get(name)
  return agents[name]
end

M._parse_agent_file = parse_agent_file
M._name_from_path = name_from_path
M._get_default_agents_dir = get_default_agents_dir

M.scan()
return M
