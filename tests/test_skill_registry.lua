local child = MiniTest.new_child_neovim()
local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      child.restart({ "-u", "assets/minimal.lua" })
    end,
    post_once = function()
      child.stop()
    end,
  },
})

local eq = MiniTest.expect.equality

T["sia.skills.registry"] = MiniTest.new_set()

T["sia.skills.registry"]["scan exposes valid skills from extra dirs"] = function()
  child.lua([[
    local tmpdir = vim.fn.tempname()
    local skills_dir = tmpdir .. "/skills"
    vim.fn.mkdir(skills_dir .. "/test-skill", "p")
    vim.fn.writefile({
      "---",
      "name: test-skill",
      "description: Test skill",
      "tools:",
      "  - bash",
      "---",
      "",
      "## When to Use",
      "",
      "Use this when testing.",
      "",
      "## Technique",
      "",
      "1. Run tests",
      "2. Check output",
    }, skills_dir .. "/test-skill/SKILL.md")

    local config = require("sia.config")
    local old_local_config = config.get_local_config
    config.get_local_config = function()
      return { skills = {}, skills_extras = { skills_dir } }
    end

    local registry = require("sia.skills.registry")
    registry.scan()
    _G.skill = registry.get("test-skill")

    config.get_local_config = old_local_config
    vim.fn.delete(tmpdir, "rf")
  ]])

  local skill = child.lua_get("_G.skill")
  eq("test-skill", skill.name)
  eq("Test skill", skill.description)
  eq({ "bash" }, skill.tools)
  eq(9, #skill.content)
  eq("", skill.content[1])
  eq("## When to Use", skill.content[2])
end

T["sia.skills.registry"]["scan ignores skills with missing frontmatter"] = function()
  child.lua([[
    local tmpdir = vim.fn.tempname()
    local skills_dir = tmpdir .. "/skills"
    vim.fn.mkdir(skills_dir .. "/bad-skill", "p")
    vim.fn.writefile({
      "No frontmatter here",
      "Just body content",
    }, skills_dir .. "/bad-skill/SKILL.md")

    local config = require("sia.config")
    local old_local_config = config.get_local_config
    config.get_local_config = function()
      return { skills = {}, skills_extras = { skills_dir } }
    end

    local registry = require("sia.skills.registry")
    registry.scan()
    _G.skill = registry.get("bad-skill")
    _G.error = registry.errors()["bad-skill"]

    config.get_local_config = old_local_config
    vim.fn.delete(tmpdir, "rf")
  ]])

  eq(vim.NIL, child.lua_get("_G.skill"))
  eq(vim.NIL, child.lua_get("_G.error"))
end

T["sia.skills.registry"]["scan reports missing description as a parse error"] = function()
  child.lua([[
    local tmpdir = vim.fn.tempname()
    local skills_dir = tmpdir .. "/skills"
    vim.fn.mkdir(skills_dir .. "/bad-skill", "p")
    vim.fn.writefile({
      "---",
      "name: bad-skill",
      "tools:",
      "  - bash",
      "---",
      "body",
    }, skills_dir .. "/bad-skill/SKILL.md")

    local config = require("sia.config")
    local old_local_config = config.get_local_config
    config.get_local_config = function()
      return { skills = {}, skills_extras = { skills_dir } }
    end

    local registry = require("sia.skills.registry")
    registry.scan()
    local error_entry = registry.errors()["bad-skill"]
    _G.skill = registry.get("bad-skill")
    _G.error_message = error_entry and error_entry.message or nil

    config.get_local_config = old_local_config
    vim.fn.delete(tmpdir, "rf")
  ]])

  eq(vim.NIL, child.lua_get("_G.skill"))
  eq(false, child.lua_get("_G.error_message"):find("Missing required field: description", 1, true) ~= nil)
end

T["sia.skills.registry"]["scan defaults tools to empty when omitted"] = function()
  child.lua([[
    local tmpdir = vim.fn.tempname()
    local skills_dir = tmpdir .. "/skills"
    vim.fn.mkdir(skills_dir .. "/no-tools-skill", "p")
    vim.fn.writefile({
      "---",
      "name: no-tools-skill",
      "description: Test",
      "---",
      "body",
    }, skills_dir .. "/no-tools-skill/SKILL.md")

    local config = require("sia.config")
    local old_local_config = config.get_local_config
    config.get_local_config = function()
      return { skills = {}, skills_extras = { skills_dir } }
    end

    local registry = require("sia.skills.registry")
    registry.scan()
    _G.skill = registry.get("no-tools-skill")

    config.get_local_config = old_local_config
    vim.fn.delete(tmpdir, "rf")
  ]])

  local skill = child.lua_get("_G.skill")
  eq("no-tools-skill", skill.name)
  eq("Test", skill.description)
  eq({}, skill.tools)
end

T["sia.skills.registry"]["scan records skill directory"] = function()
  child.lua([[
    local tmpdir = vim.fn.tempname()
    local skills_dir = tmpdir .. "/skills"
    local skill_dir = skills_dir .. "/tmux-skill"
    vim.fn.mkdir(skill_dir, "p")
    vim.fn.writefile({
      "---",
      "name: tmux-skill",
      "description: Tmux skill",
      "tools:",
      "  - bash",
      "---",
      "Run: `bash {{skill_dir}}/scripts/tmux-send.sh`",
    }, skill_dir .. "/SKILL.md")

    local config = require("sia.config")
    local old_local_config = config.get_local_config
    config.get_local_config = function()
      return { skills = {}, skills_extras = { skills_dir } }
    end

    local registry = require("sia.skills.registry")
    registry.scan()
    _G.skill = registry.get("tmux-skill")
    _G.expected_dir = skill_dir

    config.get_local_config = old_local_config
    vim.fn.delete(tmpdir, "rf")
  ]])

  local skill = child.lua_get("_G.skill")
  local expected_dir = child.lua_get("_G.expected_dir")
  eq("Run: `bash {{skill_dir}}/scripts/tmux-send.sh`", skill.content[1])
  eq(expected_dir, skill.dir)
end

T["sia.skills.registry"]["list_skill_names includes skills outside enabled project config"] = function()
  child.lua([[
    local tmpdir = vim.fn.tempname()
    local skills_dir = tmpdir .. "/skills"
    vim.fn.mkdir(skills_dir .. "/alpha-skill", "p")
    vim.fn.mkdir(skills_dir .. "/beta-skill", "p")

    vim.fn.writefile({
      "---",
      "name: alpha-skill",
      "description: Alpha",
      "---",
      "Use alpha",
    }, skills_dir .. "/alpha-skill/SKILL.md")

    vim.fn.writefile({
      "---",
      "name: beta-skill",
      "description: Beta",
      "---",
      "Use beta",
    }, skills_dir .. "/beta-skill/SKILL.md")

    local config = require("sia.config")
    local old_local_config = config.get_local_config
    config.get_local_config = function()
      return { skills = {}, skills_extras = { skills_dir } }
    end

    local registry = require("sia.skills.registry")
    registry.scan()
    _G.skill_names = registry.list_skill_names(false)

    config.get_local_config = old_local_config
    vim.fn.delete(tmpdir, "rf")
  ]])

  local names = child.lua_get("_G.skill_names")
  eq(true, vim.tbl_contains(names, "alpha-skill"))
  eq(true, vim.tbl_contains(names, "beta-skill"))
end

T["sia.skills.registry"]["local parse errors override valid lower-priority skills"] = function()
  child.lua([[
    local tmpdir = vim.fn.tempname()
    local local_skills = tmpdir .. "/project/.sia/skills"
    local extra_skills = tmpdir .. "/extra"
    vim.fn.mkdir(local_skills .. "/update-docs", "p")
    vim.fn.mkdir(extra_skills .. "/update-docs", "p")

    vim.fn.writefile({
      "---",
      "name: update-docs",
      "---",
      "broken local skill",
    }, local_skills .. "/update-docs/SKILL.md")

    vim.fn.writefile({
      "---",
      "name: update-docs",
      "description: Valid fallback",
      "---",
      "valid extra skill",
    }, extra_skills .. "/update-docs/SKILL.md")

    local old_root = vim.fs.root
    vim.fs.root = function(_, _) return tmpdir .. "/project" end

    local config = require("sia.config")
    local old_local_config = config.get_local_config
    config.get_local_config = function()
      return { skills = {}, skills_extras = { extra_skills } }
    end

    local registry = require("sia.skills.registry")
    registry.scan()
    local error_entry = registry.errors()["update-docs"]
    _G.skill = registry.get("update-docs")
    _G.error_message = error_entry and error_entry.message or nil

    config.get_local_config = old_local_config
    vim.fs.root = old_root
    vim.fn.delete(tmpdir, "rf")
  ]])

  eq(vim.NIL, child.lua_get("_G.skill"))
  eq(false, child.lua_get("_G.error_message"):find("Missing required field: description", 1, true) ~= nil)
end

T["sia.skills.registry"]["get_missing_tools reports unavailable tools"] = function()
  child.lua([[
    local registry = require("sia.skills.registry")
    _G.missing = registry.get_missing_tools({ tools = { "bash", "read" } }, function(name)
      return name == "bash"
    end)
  ]])

  eq({ "read" }, child.lua_get("_G.missing"))
end

T["sia.skills.registry"]["scan reports invalid name and missing body errors"] = function()
  child.lua([[
    local tmpdir = vim.fn.tempname()
    local skills_dir = tmpdir .. "/skills"
    vim.fn.mkdir(skills_dir .. "/wrong-name", "p")
    vim.fn.mkdir(skills_dir .. "/empty-skill", "p")

    vim.fn.writefile({
      "---",
      "name: other-name",
      "description: Wrong name",
      "---",
      "Body content here",
    }, skills_dir .. "/wrong-name/SKILL.md")

    vim.fn.writefile({
      "---",
      "name: empty-skill",
      "description: Empty",
      "tools:",
      "  - bash",
      "---",
    }, skills_dir .. "/empty-skill/SKILL.md")

    local config = require("sia.config")
    local old_local_config = config.get_local_config
    config.get_local_config = function()
      return { skills = {}, skills_extras = { skills_dir } }
    end

    local registry = require("sia.skills.registry")
    registry.scan()
    local errors = registry.errors()
    _G.wrong_name_error = errors["wrong-name"] and errors["wrong-name"].message or nil
    _G.empty_error = errors["empty-skill"] and errors["empty-skill"].message or nil

    config.get_local_config = old_local_config
    vim.fn.delete(tmpdir, "rf")
  ]])

  eq(false, child.lua_get("_G.wrong_name_error"):find("name must match directory", 1, true) ~= nil)
  eq(vim.NIL, child.lua_get("_G.empty_error"))
end

return T

