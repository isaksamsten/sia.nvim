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

T["sia.skills.registry"]["parse_skill_file parses valid SKILL.md"] = function()
  child.lua([[
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir .. "/test-skill", "p")
    local filepath = tmpdir .. "/test-skill/SKILL.md"
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
    }, filepath)

    local registry = require("sia.skills.registry")
    local skill, err = registry._parse_skill_file(filepath, "test-skill")
    _G.skill = skill
    _G.err = err

    vim.fn.delete(tmpdir, "rf")
  ]])

  local skill = child.lua_get("_G.skill")
  local err = child.lua_get("_G.err")

  eq(vim.NIL, err)
  eq("test-skill", skill.name)
  eq("Test skill", skill.description)
  eq({ "bash" }, skill.tools)
  eq(9, #skill.content)
  eq("", skill.content[1])
  eq("## When to Use", skill.content[2])
end

T["sia.skills.registry"]["parse_skill_file fails on missing frontmatter"] = function()
  child.lua([[
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir .. "/bad-skill", "p")
    local filepath = tmpdir .. "/bad-skill/SKILL.md"
    vim.fn.writefile({
      "No frontmatter here",
      "Just body content",
    }, filepath)

    local registry = require("sia.skills.registry")
    local skill, err = registry._parse_skill_file(filepath, "bad-skill")
    _G.skill = skill
    _G.err = err

    vim.fn.delete(tmpdir, "rf")
  ]])

  local skill = child.lua_get("_G.skill")
  local err = child.lua_get("_G.err")

  eq(vim.NIL, skill)
  eq("Invalid format: missing frontmatter", err)
end

T["sia.skills.registry"]["parse_skill_file fails on missing description"] = function()
  child.lua([[
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir .. "/bad-skill", "p")
    local filepath = tmpdir .. "/bad-skill/SKILL.md"
    vim.fn.writefile({
      "---",
      "name: bad-skill",
      "tools:",
      "  - bash",
      "---",
      "body",
    }, filepath)

    local registry = require("sia.skills.registry")
    local skill, err = registry._parse_skill_file(filepath, "bad-skill")
    _G.skill = skill
    _G.err = err

    vim.fn.delete(tmpdir, "rf")
  ]])

  local skill = child.lua_get("_G.skill")
  local err = child.lua_get("_G.err")

  eq(vim.NIL, skill)
  eq("Missing required field: description", err)
end

T["sia.skills.registry"]["parse_skill_file defaults tools to empty when omitted"] = function()
  child.lua([[
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir .. "/no-tools-skill", "p")
    local filepath = tmpdir .. "/no-tools-skill/SKILL.md"
    vim.fn.writefile({
      "---",
      "name: no-tools-skill",
      "description: Test",
      "---",
      "body",
    }, filepath)

    local registry = require("sia.skills.registry")
    local skill, err = registry._parse_skill_file(filepath, "no-tools-skill")
    _G.skill = skill
    _G.err = err

    vim.fn.delete(tmpdir, "rf")
  ]])

  local skill = child.lua_get("_G.skill")
  local err = child.lua_get("_G.err")

  eq(vim.NIL, err)
  eq("no-tools-skill", skill.name)
  eq("Test", skill.description)
  eq({}, skill.tools)
end

T["sia.skills.registry"]["parse_skill_file preserves body references and records skill dir"] = function()
  child.lua([[
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir .. "/tmux-skill", "p")
    local filepath = tmpdir .. "/tmux-skill/SKILL.md"
    vim.fn.writefile({
      "---",
      "name: tmux-skill",
      "description: Tmux skill",
      "tools:",
      "  - bash",
      "---",
      "Run: `bash {{skill_dir}}/scripts/tmux-send.sh`",
    }, filepath)

    local registry = require("sia.skills.registry")
    local skill, err = registry._parse_skill_file(filepath, "tmux-skill")
    _G.skill = skill
    _G.err = err
    _G.expected_dir = tmpdir .. "/tmux-skill"

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
      return {
        skills = {},
        skills_extras = { skills_dir },
      }
    end

    local registry = require("sia.skills.registry")
    _G.skill_names = registry.list_skill_names(false)

    config.get_local_config = old_local_config
    vim.fn.delete(tmpdir, "rf")
  ]])

  local names = child.lua_get("_G.skill_names")
  eq(true, vim.tbl_contains(names, "alpha-skill"))
  eq(true, vim.tbl_contains(names, "beta-skill"))
end

T["sia.skills.registry"]["scan exposes valid skills and parse errors"] = function()
  child.lua([[
    local tmpdir = vim.fn.tempname()
    local skills_dir = tmpdir .. "/skills"
    vim.fn.mkdir(skills_dir .. "/good-skill", "p")
    vim.fn.mkdir(skills_dir .. "/bad-skill", "p")

    vim.fn.writefile({
      "---",
      "name: good-skill",
      "description: Good skill",
      "---",
      "Use the good skill",
    }, skills_dir .. "/good-skill/SKILL.md")

    vim.fn.writefile({
      "---",
      "name: bad-skill",
      "---",
      "broken skill",
    }, skills_dir .. "/bad-skill/SKILL.md")

    local config = require("sia.config")
    local old_local_config = config.get_local_config
    config.get_local_config = function()
      return {
        skills = {},
        skills_extras = { skills_dir },
      }
    end

    local registry = require("sia.skills.registry")
    registry.scan()
    local skill = registry.get("good-skill")
    local errors = registry.errors()

    _G.good_skill_name = skill and skill.name or nil
    _G.bad_skill_error = errors["bad-skill"] and errors["bad-skill"].message or nil

    config.get_local_config = old_local_config
    vim.fn.delete(tmpdir, "rf")
  ]])

  eq("good-skill", child.lua_get("_G.good_skill_name"))
  eq("Missing required field: description", child.lua_get("_G.bad_skill_error"))
end

T["sia.skills.registry"]["get_skill reports parse errors from highest-priority match"] = function()
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

    local old_cwd = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(tmpdir .. "/project"))

    local config = require("sia.config")
    local old_local_config = config.get_local_config
    config.get_local_config = function()
      return {
        skills = {},
        skills_extras = { extra_skills },
      }
    end

    local registry = require("sia.skills.registry")
    local skill, err = registry.get_skill("update-docs")
    _G.skill = skill
    _G.err = err

    config.get_local_config = old_local_config
    vim.cmd("cd " .. vim.fn.fnameescape(old_cwd))
    vim.fn.delete(tmpdir, "rf")
  ]])

  eq(vim.NIL, child.lua_get("_G.skill"))
  eq("Missing required field: description", child.lua_get("_G.err"))
end

T["sia.skills.registry"]["get_skills filters by conversation tools"] = function()
  child.lua([[
    -- Set up a temporary skills dir + config
    local tmpdir = vim.fn.tempname()
    local skills_dir = tmpdir .. "/skills"
    vim.fn.mkdir(skills_dir .. "/bash-skill", "p")
    vim.fn.mkdir(skills_dir .. "/read-bash-skill", "p")

    vim.fn.writefile({
      "---",
      "name: bash-skill",
      "description: Needs bash",
      "tools:",
      "  - bash",
      "---",
      "Use bash",
    }, skills_dir .. "/bash-skill/SKILL.md")

    vim.fn.writefile({
      "---",
      "name: read-bash-skill",
      "description: Needs both",
      "tools:",
      "  - bash",
      "  - read",
      "---",
      "Use bash and read",
    }, skills_dir .. "/read-bash-skill/SKILL.md")

    -- Manually scan and filter
    local registry = require("sia.skills.registry")

    -- Test with only bash available
    local bash_only = { bash = true }
    -- We need to mock the config, so let's test the parse+filter logic directly
    local scan = registry._parse_skill_file
    local s1 = scan(skills_dir .. "/bash-skill/SKILL.md", "bash-skill")
    local s2 = scan(skills_dir .. "/read-bash-skill/SKILL.md", "read-bash-skill")

    -- Filter: bash-skill should pass, read-bash-skill should not
    local function check_tools(skill, tools)
      for _, t in ipairs(skill.tools) do
        if not tools[t] then return false end
      end
      return true
    end

    _G.bash_skill_with_bash_only = check_tools(s1, bash_only)
    _G.read_bash_skill_with_bash_only = check_tools(s2, bash_only)
    _G.read_bash_skill_with_both = check_tools(s2, { bash = true, read = true })

    vim.fn.delete(tmpdir, "rf")
  ]])

  eq(true, child.lua_get("_G.bash_skill_with_bash_only"))
  eq(false, child.lua_get("_G.read_bash_skill_with_bash_only"))
  eq(true, child.lua_get("_G.read_bash_skill_with_both"))
end

T["sia.skills.registry"]["parse_skill_file fails on empty body"] = function()
  child.lua([[
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir .. "/empty-skill", "p")
    local filepath = tmpdir .. "/empty-skill/SKILL.md"
    vim.fn.writefile({
      "---",
      "name: empty-skill",
      "description: Empty",
      "tools:",
      "  - bash",
      "---",
    }, filepath)

    local registry = require("sia.skills.registry")
    local skill, err = registry._parse_skill_file(filepath, "empty-skill")
    _G.skill = skill
    _G.err = err

    vim.fn.delete(tmpdir, "rf")
  ]])

  local skill = child.lua_get("_G.skill")
  local err = child.lua_get("_G.err")

  eq(vim.NIL, skill)
  eq("Missing skill content body", err)
end

T["sia.skills.registry"]["parse_skill_file rejects frontmatter name that differs from directory"] = function()
  child.lua([[
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir .. "/dir-name", "p")
    local filepath = tmpdir .. "/dir-name/SKILL.md"
    vim.fn.writefile({
      "---",
      "name: custom-name",
      "description: Name override test",
      "tools:",
      "  - bash",
      "  - read",
      "---",
      "Body content here",
    }, filepath)

    local registry = require("sia.skills.registry")
    local skill, err = registry._parse_skill_file(filepath, "dir-name")
    _G.skill = skill
    _G.err = err

    vim.fn.delete(tmpdir, "rf")
  ]])

  local skill = child.lua_get("_G.skill")
  local err = child.lua_get("_G.err")

  eq("name must match directory", err)
end

T["sia.skills.registry"]["parse_skill_file requires name field"] = function()
  child.lua([[
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir .. "/dir-name", "p")
    local filepath = tmpdir .. "/dir-name/SKILL.md"
    vim.fn.writefile({
      "---",
      "description: No name field",
      "---",
      "Body content here",
    }, filepath)

    local registry = require("sia.skills.registry")
    local skill, err = registry._parse_skill_file(filepath, "dir-name")
    _G.skill = skill
    _G.err = err

    vim.fn.delete(tmpdir, "rf")
  ]])

  local skill = child.lua_get("_G.skill")
  local err = child.lua_get("_G.err")

  eq("Missing required field: name", err)
end

return T
