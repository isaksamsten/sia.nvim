local M = {}

local State = {
  BEFORE_FRONTMATTER = 1,
  IN_FRONTMATTER = 2,
  IN_BODY = 3,
}

--- @class sia.skill_registry.SkillDef
--- @field name string
--- @field description string
--- @field tools string[]
--- @field content string[]      -- the markdown body lines
--- @field dir string            -- absolute path to skill directory
--- @field filepath string       -- absolute path to SKILL.md

--- Parse simple YAML frontmatter (flat key-value pairs and simple lists)
--- @param lines string[]
--- @return table<string, string|string[]>
local function parse_yaml_frontmatter(lines)
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
      local key, value = line:match("^(%w[%w_]*):%s*(.*)$")
      if key then
        current_key = key
        if value ~= "" then
          result[key] = value
        end
      end
    end
  end

  return result
end

--- Parse a SKILL.md file into a skill definition
--- @param filepath string Path to SKILL.md
--- @param name string Skill name (directory name, used as fallback)
--- @return sia.skill_registry.SkillDef? skill
--- @return string|nil error
local function parse_skill_file(filepath, name)
  local file = vim.fn.readfile(filepath)
  --- @type string[]
  local frontmatter = {}
  --- @type string[]
  local body = {}
  local state = State.BEFORE_FRONTMATTER

  for _, line in ipairs(file) do
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
    return nil, "Invalid format: missing frontmatter"
  end

  if #body == 0 then
    return nil, "Missing skill content body"
  end

  local metadata = parse_yaml_frontmatter(frontmatter)

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

  local dir = vim.fn.fnamemodify(filepath, ":h")

  -- Resolve {{skill_dir}} in body lines
  local resolved_body = {}
  for _, line in ipairs(body) do
    table.insert(resolved_body, (line:gsub("{{skill_dir}}", dir)))
  end

  return {
    name = metadata.name,
    description = metadata.description,
    tools = tools or {},
    content = resolved_body,
    dir = dir,
    filepath = filepath,
  }
end

--- Get the default user-level skills directory
--- @return string
local function get_default_skills_dir()
  local config_dir = vim.env.XDG_CONFIG_HOME or vim.fs.joinpath(vim.env.HOME, ".config")
  return vim.fs.joinpath(config_dir, "sia", "skills")
end

--- Scan a directory for skill definitions (*/SKILL.md)
--- @param base_dir string Directory to scan
--- @param error_report boolean?
--- @return table<string, sia.skill_registry.SkillDef> skills Map of name to skill
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
            string.format("Failed to load skill from %s: %s", skill_file, err),
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
  local lc = config.get_local_config()
  if not lc then
    return {}, {}
  end

  local skill_names = lc.skills or {}
  local extra_paths = lc.skills_extras or {}

  return skill_names, extra_paths
end

--- Get all available skill definitions, filtered by project config
--- Skills are only included if:
--- 1. They are listed in the project's config.json `skills` array
--- 2. All their required `tools` are available in the conversation
---
--- @param conversation_tools table<string, any>? Map of tool name → truthy (e.g., conversation.tool_fn)
--- @param error_report boolean?
--- @return sia.skill_registry.SkillDef[] skills
function M.get_skills(conversation_tools, error_report)
  local enabled_names, extra_paths = get_skills_config()

  if #enabled_names == 0 then
    return {}
  end

  -- Build lookup set for enabled skill names
  local enabled_set = {}
  for _, name in ipairs(enabled_names) do
    enabled_set[name] = true
  end

  -- Scan all search paths. First match wins on name collision.
  --- @type table<string, sia.skill_registry.SkillDef>
  local all_skills = {}

  -- Default location first
  local default_dir = get_default_skills_dir()
  for name, skill in pairs(scan_skills_dir(default_dir, error_report)) do
    if enabled_set[name] and not all_skills[name] then
      all_skills[name] = skill
    end
  end

  -- Then extras
  for _, extra_dir in ipairs(extra_paths) do
    -- Expand ~ in paths
    local expanded = vim.fn.expand(extra_dir)
    for name, skill in pairs(scan_skills_dir(expanded, error_report)) do
      if enabled_set[name] and not all_skills[name] then
        all_skills[name] = skill
      end
    end
  end

  -- Filter by tool availability
  local result = {}
  for _, skill in pairs(all_skills) do
    local tools_met = true
    if conversation_tools then
      for _, required_tool in ipairs(skill.tools) do
        if not conversation_tools[required_tool] then
          tools_met = false
          break
        end
      end
    end

    if tools_met then
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
--- Searches default dir + extras from config
--- @param name string
--- @return sia.skill_registry.SkillDef?
function M.get_skill(name)
  local _, extra_paths = get_skills_config()

  local default_dir = get_default_skills_dir()
  local skill_file = vim.fs.joinpath(default_dir, name, "SKILL.md")
  local stat = vim.uv.fs_stat(skill_file)
  if stat and stat.type == "file" then
    local skill = parse_skill_file(skill_file, name)
    return skill
  end

  for _, extra_dir in ipairs(extra_paths) do
    local expanded = vim.fn.expand(extra_dir)
    skill_file = vim.fs.joinpath(expanded, name, "SKILL.md")
    stat = vim.uv.fs_stat(skill_file)
    if stat and stat.type == "file" then
      local skill = parse_skill_file(skill_file, name)
      return skill
    end
  end

  return nil
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
  local default_dir = get_default_skills_dir()
  for _, name in ipairs(enabled_names) do
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

return M
