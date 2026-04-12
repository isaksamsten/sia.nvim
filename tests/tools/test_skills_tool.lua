local skills_tool = require("sia.tools.skills")
local config = require("sia.config")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local function with_local_config(local_config, fn)
  local original = config.get_local_config
  config.get_local_config = function()
    return local_config
  end

  local ok, err = pcall(fn)
  config.get_local_config = original
  if not ok then
    error(err)
  end
end

local function create_execution_context()
  return {
    conversation = {
      approved_tools = setmetatable({}, {__index = function() return true end}),
      
    },
  }
end

T["sia.tools.skills"] = MiniTest.new_set()

T["sia.tools.skills"]["reads a named skill"] = function()
  local tmpdir = vim.fn.tempname()
  local skills_dir = tmpdir .. "/skills"
  local skill_dir = skills_dir .. "/project-skill-test"
  vim.fn.mkdir(skill_dir, "p")
  vim.fn.writefile({
    "---",
    "name: project-skill-test",
    "description: Keep docs aligned with code changes",
    "tools:",
    "  - grep",
    "  - view",
    "---",
    "# Update Docs",
    "",
    "Read the docs before changing them.",
  }, skill_dir .. "/SKILL.md")

  local result
  with_local_config({ skills = {}, skills_extras = { skills_dir } }, function()
    skills_tool.implementation.execute({ name = "project-skill-test" }, function(res)
      result = res
    end, create_execution_context())
  end)

  eq("🧩 Read skill project-skill-test", result.summary)
  eq(true, result.content:find("Skill `project%-skill%-test`") ~= nil)
  eq(
    true,
    result.content:find("Description: Keep docs aligned with code changes", 1, true)
      ~= nil
  )
  eq(true, result.content:find("# Update Docs", 1, true) ~= nil)

  vim.fn.delete(tmpdir, "rf")
end

T["sia.tools.skills"]["rejects missing skill names"] = function()
  local result
  skills_tool.implementation.execute({}, function(res)
    result = res
  end, create_execution_context())

  eq("❌ Failed to read skill", result.summary)
  eq("Error: No skill name was provided", result.content)
end

T["sia.tools.skills"]["reports lookup failures"] = function()
  local result
  with_local_config({ skills = {}, skills_extras = {} }, function()
    skills_tool.implementation.execute(
      { name = "definitely-missing-skill" },
      function(res)
        result = res
      end,
      create_execution_context()
    )
  end)

  eq("❌ Failed to read skill", result.summary)
  eq(
    "Error: Could not read skill `definitely-missing-skill`: skill not found",
    result.content
  )
end

return T
