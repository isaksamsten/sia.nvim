local M = {}
local markdown = require("sia.markdown")

--- @class sia.skills.registry.SkillDef
--- @field name string
--- @field description string
--- @field tools string[]
--- @field content string[]      -- the markdown body lines
--- @field dir string            -- absolute path to skill directory
--- @field filepath string       -- absolute path to SKILL.md

--- @class sia.skills.registry.Entry
--- @field definition sia.skills.registry.SkillDef?
--- @field error {path: string, message: string}?

--- @type table<string, sia.skills.registry.Entry>
local skills = {}

--- @param filepath string
--- @param name string
--- @return sia.skills.registry.SkillDef?, string?
local function parse_skill_file(filepath, name)
  local ok, document = pcall(markdown.read_frontmatter_file, filepath)
  if not ok then
    return nil
  end

  local metadata = document.metadata
  local body = document.body

  if not metadata.name or type(metadata.name) ~= "string" then
    error("Missing required field: name")
  end

  if metadata.name ~= name then
    error("name must match directory")
  end

  if not metadata.description or type(metadata.description) ~= "string" then
    error("Missing required field: description")
  end

  local tools = metadata.tools
  if tools ~= nil and type(tools) ~= "table" then
    error("Invalid field: tools (must be a list)")
  end

  local has_content = false
  for _, line in ipairs(body) do
    if line:match("%S") then
      has_content = true
      break
    end
  end
  if not has_content then
    error("Missing skill content body")
  end

  --- @type string[]
  local skill_tools = {}
  if type(tools) == "table" then
    skill_tools = tools
  end
  --- @type sia.skills.registry.SkillDef
  return {
    name = metadata.name --[[@as string]],
    description = metadata.description --[[@as string]],
    tools = skill_tools,
    content = body,
    dir = vim.fn.fnamemodify(filepath, ":h"),
    filepath = filepath,
  }
end

--- @return string
local function get_default_skills_dir()
  local config_dir = vim.env.XDG_CONFIG_HOME or vim.fs.joinpath(vim.env.HOME, ".config")
  return vim.fs.joinpath(config_dir, "sia", "skills")
end

--- @return string?
local function get_project_skills_dir()
  local project_root = vim.fs.root(0, ".sia")
  if not project_root then
    return nil
  end
  return vim.fs.joinpath(project_root, ".sia", "skills")
end

--- @param base_dir string
local function scan_dir(base_dir)
  local stat = vim.uv.fs_stat(base_dir)
  if not stat or stat.type ~= "directory" then
    return
  end

  local handle = vim.uv.fs_scandir(base_dir)
  if not handle then
    return
  end

  while true do
    local entry_name, entry_type = vim.uv.fs_scandir_next(handle)
    if not entry_name then
      break
    end

    if entry_type == "directory" then
      local filepath = vim.fs.joinpath(base_dir, entry_name, "SKILL.md")
      local skill_stat = vim.uv.fs_stat(filepath)
      if skill_stat and skill_stat.type == "file" then
        local ok, skill = pcall(parse_skill_file, filepath, entry_name)
        if ok then
          skills[entry_name] = { definition = skill }
        else
          skills[entry_name] = {
            error = {
              path = filepath,
              message = skill --[[@as string]]
                or "unknown error",
            },
          }
        end
      end
    end
  end
end

--- @param skill sia.skills.registry.SkillDef
--- @param has_tool fun(name: string):boolean
--- @return string[]
local function get_missing_tools(skill, has_tool)
  local missing = {}
  for _, required_tool in ipairs(skill.tools) do
    if not has_tool(required_tool) then
      table.insert(missing, required_tool)
    end
  end
  return missing
end

function M.scan()
  skills = {}

  local extra_paths = require("sia.config").options.settings.skills_extras or {}
  for _, extra_dir in ipairs(extra_paths) do
    scan_dir(vim.fn.expand(extra_dir))
  end

  local global_dir = get_default_skills_dir()
  if global_dir then
    scan_dir(global_dir)
  end

  local local_dir = get_project_skills_dir()
  if local_dir then
    scan_dir(local_dir)
  end
end

--- @param name string
--- @return sia.skills.registry.SkillDef?
function M.get(name)
  local entry = skills[name]
  return entry and entry.definition or nil
end

--- @return table<string, {path: string, message: string}>
function M.errors()
  local errors = {}
  for name, entry in pairs(skills) do
    if entry.error then
      errors[name] = entry.error
    end
  end

  return errors
end

--- @param f (fun(skill: sia.skills.registry.SkillDef):boolean)?
--- @return sia.skills.registry.SkillDef[]
function M.filter(f)
  local result = {}
  for _, entry in pairs(skills) do
    if entry and entry.definition and (f == nil or f(entry.definition)) then
      table.insert(result, entry.definition)
    end
  end

  return result
end

--- @return string[]
function M.list_skill_names()
  local names = {}
  for _, skill in ipairs(M.filter()) do
    table.insert(names, skill.name)
  end
  return names
end

--- @param skill sia.skills.registry.SkillDef
--- @param has_tool fun(name: string):boolean
--- @return string[]
function M.get_missing_tools(skill, has_tool)
  return get_missing_tools(skill, has_tool)
end

M.scan()

return M
