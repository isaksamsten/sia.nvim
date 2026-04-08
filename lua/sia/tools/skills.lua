local tool_utils = require("sia.tools.utils")
local icons = require("sia.ui").icons
local tool_names = tool_utils.tool_names

local function format_skill(skill)
  local lines = {
    string.format("Skill `%s`", skill.name),
    string.format("Description: %s", skill.description),
    string.format("Entrypoint: %s", skill.filepath),
    string.format("Directory: %s", skill.dir),
  }

  table.insert(lines, "")
  table.insert(lines, "Content:")
  vim.list_extend(lines, skill.content)

  return table.concat(lines, "\n")
end

return tool_utils.new_tool({
  definition = {
    type = "function",
    name = tool_names.skills,
    description = "Read a skill definition by name from the configured skill directories",
    parameters = {
      name = {
        type = "string",
        description = "The skill name to read",
      },
    },
    required = { "name" },
  },
  read_only = true,
  instructions = [[Read a named skill definition from Sia's configured skill directories.
- Use this instead of viewing `SKILL.md` directly when you want to inspect a skill.
- Returns the skill metadata, entrypoint path, directory, required tools, and markdown body.
- Skills are resolved in normal priority order: project-local, global, then extra paths.]],
  summary = function(args)
    if args.name then
      return string.format("Reading skill %s...", args.name)
    end
    return "Reading skill..."
  end,
  auto_apply = function()
    return 1
  end,
}, function(args, _, callback)
  if not args.name or args.name == "" then
    callback({
      content = "Error: No skill name was provided",
      summary = icons.error .. " Failed to read skill",
      ephemeral = true,
    })
    return
  end

  local registry = require("sia.skills.registry")
  local skill, err = registry.get_skill(args.name, false)
  if not skill then
    callback({
      content = string.format(
        "Error: Could not read skill `%s`: %s",
        args.name,
        err or "unknown error"
      ),
      summary = icons.error .. " Failed to read skill",
      ephemeral = true,
    })
    return
  end

  callback({
    content = format_skill(skill),
    summary = string.format("%s Read skill %s", icons.view_skill, skill.name),
  })
end)
