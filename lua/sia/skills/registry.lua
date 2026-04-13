local M = {}
local markdown = require("sia.markdown")

--- @class sia.skills.registry.SkillDef
--- @field name string
--- @field description string
--- @field tools string[]
--- @field content string[]      -- the markdown body lines
--- @field dir string            -- absolute path to skill directory
--- @field filepath string       -- absolute path to SKILL.md

--- Parse a SKILL.md file into a skill definition
--- @param filepath string Path to SKILL.md
--- @param name string Skill name (directory name, used as fallback)
--- @return sia.skills.registry.SkillDef? skill
--- @return string|nil error
local function parse_skill_file(filepath, name)
  local document, err =
    markdown.read_frontmatter_file(filepath, { empty_body_error = "Missing skill content body" })
  if not document then
    return nil, err
  end

  local metadata = document.metadata
  local body = document.body

  if not metadata.name then
    return nil, "Missing required field: name"
  end

  if metadata.name ~= name then
    return nil, "name must match directory"
  end

  if not metadata.description then
    return nil, "Missing required field: description"
  end

  -- tools is optional (sia-specific extension), defaults to empty
  local tools = metadata.tools
  if tools ~= nil and type(tools) ~= "table" then
    return nil, "Invalid field: tools (must be a list)"
  end

  return {
    name = metadata.name,
    description = metadata.description,
    tools = tools or {},
    content = body,
    dir = vim.fn.fnamemodify(filepath, ":h"),
    filepath = filepath,
  }
end

--- Get the default user-level skills directory
--- @return string
local function get_default_skills_dir()
  local config_dir = vim.env.XDG_CONFIG_HOME or vim.fs.joinpath(vim.env.HOME, ".config")
  return vim.fs.joinpath(config_dir, "sia", "skills")
end

--- Get the project-local skills directory (.sia/skills/) when available.
--- @return string?
local function get_project_skills_dir()
  local project_root = vim.fs.root(0, ".sia")
  if not project_root then
    return nil
  end
  return vim.fs.joinpath(project_root, ".sia", "skills")
end

--- Scan a directory for skill definitions (*/SKILL.md)
--- @param base_dir string Directory to scan
--- @param error_report boolean?
--- @return table<string, sia.skills.registry.SkillDef> skills Map of name to skill
local function scan_skills_dir(base_dir, error_report)
  local skills = {}

  local stat = vim.uv.fs_stat(base_dir)
  if not stat or stat.type ~= "directory" then
    return skills
  end

  local handle = vim.uv.fs_scandir(base_dir)
  if not handle then
    return skills
  end

  while true do
    local entry_name, entry_type = vim.uv.fs_scandir_next(handle)
    if not entry_name then
      break
    end

    if entry_type == "directory" then
      local skill_file = vim.fs.joinpath(base_dir, entry_name, "SKILL.md")
      local skill_stat = vim.uv.fs_stat(skill_file)
      if skill_stat and skill_stat.type == "file" then
        local skill, err = parse_skill_file(skill_file, entry_name)
        if skill then
          skills[entry_name] = skill
        elseif error_report ~= false then
          vim.notify(
            string.format("sia: failed to load skill from %s: %s", skill_file, err),
            vim.log.levels.WARN
          )
        end
      end
    end
  end

  return skills
end

--- Get the list of enabled skill names and extra search paths from project config
--- @return string[] skill_names
--- @return string[] extra_paths
local function get_skills_config()
  local config = require("sia.config")
  local skill_names = config.options.settings.skills or {}
  local extra_paths = config.options.settings.skills_extras or {}

  return skill_names, extra_paths
end

--- Get every directory that may contain skills, in resolution order.
--- @return string[]
local function get_search_dirs()
  local _, extra_paths = get_skills_config()
  local dirs = {}

  local local_dir = get_project_skills_dir()
  if local_dir then
    table.insert(dirs, local_dir)
  end
  table.insert(dirs, get_default_skills_dir())

  for _, extra_dir in ipairs(extra_paths) do
    table.insert(dirs, vim.fn.expand(extra_dir))
  end

  return dirs
end

--- Collect all discovered skills, using first match wins on name collisions.
--- @param error_report boolean?
--- @return table<string, sia.skills.registry.SkillDef>
local function collect_skills(error_report)
  local all_skills = {}

  for _, dir in ipairs(get_search_dirs()) do
    for name, skill in pairs(scan_skills_dir(dir, error_report)) do
      if not all_skills[name] then
        all_skills[name] = skill
      end
    end
  end

  return all_skills
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

--- Get all available skill definitions, filtered by project config
--- Skills are only included if:
--- 1. They are listed in the project's config.json `skills` array
--- 2. All their required `tools` are available in the conversation
---
--- @param has_tool fun(name: string):boolean
--- @param error_report boolean?
--- @return sia.skills.registry.SkillDef[] skills
function M.get_skills(has_tool, error_report)
  local enabled_names = get_skills_config()

  if #enabled_names == 0 then
    return {}
  end

  local all_skills = collect_skills(error_report)

  -- Filter by tool availability
  local result = {}
  for _, name in ipairs(enabled_names) do
    local skill = all_skills[name]
    if skill and #get_missing_tools(skill, has_tool) == 0 then
      table.insert(result, skill)
    end
  end

  -- Sort by name for deterministic ordering
  table.sort(result, function(a, b)
    return a.name < b.name
  end)

  return result
end

--- Get a single skill definition by name (ignoring project config filter)
--- Searches project-local dir + default dir + extras from config
--- Resolution order (first match wins):
---   1. Local project .sia/skills/
---   2. Global ~/.config/sia/skills/
---   3. Extra paths from config
--- @param name string
--- @param error_report boolean?
--- @return sia.skills.registry.SkillDef?, string?
function M.get_skill(name, error_report)
  for _, dir in ipairs(get_search_dirs()) do
    local skill_file = vim.fs.joinpath(dir, name, "SKILL.md")
    local stat = vim.uv.fs_stat(skill_file)
    if stat and stat.type == "file" then
      return parse_skill_file(skill_file, name)
    end
  end

  if error_report then
    vim.notify("sia: skill '" .. name .. "' was not found", vim.log.levels.WARN)
  end
  return nil, "skill not found"
end

--- List all discovered skill names, regardless of project skill enablement.
--- @param error_report boolean?
--- @return string[]
function M.list_skill_names(error_report)
  local names = vim.tbl_keys(collect_skills(error_report))
  table.sort(names)
  return names
end

--- Return the required tools that are missing for a given skill.
--- @param skill sia.skills.registry.SkillDef
--- @param has_tool fun(name: string):boolean
--- @return string[]
function M.get_missing_tools(skill, has_tool)
  return get_missing_tools(skill, has_tool)
end

--- Check if a file path is inside any enabled skill directory
--- @param path string The file path to check
--- @return boolean
function M.is_skill_path(path)
  local resolved = vim.fn.resolve(vim.fn.fnamemodify(path, ":p"))

  local enabled_names, extra_paths = get_skills_config()
  if #enabled_names == 0 then
    return false
  end

  --- @param base_dir string
  --- @param name string
  --- @return boolean
  local function check_skill_dir(base_dir, name)
    local skill_dir = vim.fn.resolve(vim.fs.joinpath(base_dir, name))
    return vim.startswith(resolved, skill_dir .. "/") or resolved == skill_dir
  end

  -- Check each enabled skill name against search paths
  local local_dir = get_project_skills_dir()
  local default_dir = M._get_default_skills_dir()
  for _, name in ipairs(enabled_names) do
    if local_dir and check_skill_dir(local_dir, name) then
      return true
    end
    if check_skill_dir(default_dir, name) then
      return true
    end
    for _, extra_dir in ipairs(extra_paths) do
      if check_skill_dir(vim.fn.expand(extra_dir), name) then
        return true
      end
    end
  end

  return false
end

-- Expose for testing
M._parse_skill_file = parse_skill_file
M._get_default_skills_dir = get_default_skills_dir

return M
