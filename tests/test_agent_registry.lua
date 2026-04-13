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

T["sia.agent.registry"] = MiniTest.new_set()

-- ─── name_from_path ───────────────────────────────────────────────────────────

T["sia.agent.registry"]["name_from_path strips base dir and .md extension"] = function()
  child.lua([[
    local registry = require("sia.agent.registry")
    _G.r1 = registry._name_from_path("/cfg/sia/agents", "/cfg/sia/agents/coder.md")
    _G.r2 = registry._name_from_path("/cfg/sia/agents", "/cfg/sia/agents/code/review.md")
    _G.r3 = registry._name_from_path("/cfg/sia/agents/", "/cfg/sia/agents/coder.md")
  ]])

  eq("coder", child.lua_get("_G.r1"))
  eq("code/review", child.lua_get("_G.r2"))
  eq("coder", child.lua_get("_G.r3"))
end

-- ─── parse_agent_file ─────────────────────────────────────────────────────────

T["sia.agent.registry"]["parse_agent_file parses valid agent markdown"] = function()
  child.lua([[
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
    local filepath = tmpdir .. "/coder.md"
    vim.fn.writefile({
      "---",
      "description: A coding agent",
      "tools:",
      "  - bash",
      "  - view",
      "model: openai/gpt-4.1",
      "require_confirmation: false",
      "---",
      "",
      "You are a helpful coding agent.",
      "Always write clean code.",
    }, filepath)

    local registry = require("sia.agent.registry")
    local agent, err = registry._parse_agent_file(filepath, "coder")
    _G.agent = agent
    _G.err = err

    vim.fn.delete(tmpdir, "rf")
  ]])

  local agent = child.lua_get("_G.agent")
  local err = child.lua_get("_G.err")

  eq(vim.NIL, err)
  eq("coder", agent.name)
  eq("A coding agent", agent.description)
  eq({ "bash", "view" }, agent.tools)
  eq("openai/gpt-4.1", agent.model)
  eq(false, agent.require_confirmation)
  eq(3, #agent.system_prompt)
  eq("", agent.system_prompt[1])
  eq("You are a helpful coding agent.", agent.system_prompt[2])
end

T["sia.agent.registry"]["parse_agent_file uses name from parameter"] = function()
  child.lua([[
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir .. "/code", "p")
    local filepath = tmpdir .. "/code/review.md"
    vim.fn.writefile({
      "---",
      "description: Code review agent",
      "tools:",
      "  - view",
      "---",
      "Review code carefully.",
    }, filepath)

    local registry = require("sia.agent.registry")
    local agent, err = registry._parse_agent_file(filepath, "code/review")
    _G.agent = agent
    _G.err = err

    vim.fn.delete(tmpdir, "rf")
  ]])

  local agent = child.lua_get("_G.agent")
  local err = child.lua_get("_G.err")

  eq(vim.NIL, err)
  eq("code/review", agent.name)
end

T["sia.agent.registry"]["parse_agent_file defaults require_confirmation to true"] = function()
  child.lua([[
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
    local filepath = tmpdir .. "/simple.md"
    vim.fn.writefile({
      "---",
      "description: Simple agent",
      "tools:",
      "  - view",
      "---",
      "System prompt here.",
    }, filepath)

    local registry = require("sia.agent.registry")
    local agent, err = registry._parse_agent_file(filepath, "simple")
    _G.agent = agent
    _G.err = err
    _G.agent_model_is_nil = (agent.model == nil)

    vim.fn.delete(tmpdir, "rf")
  ]])

  local agent = child.lua_get("_G.agent")
  local err = child.lua_get("_G.err")
  local model_is_nil = child.lua_get("_G.agent_model_is_nil")

  eq(vim.NIL, err)
  eq(true, agent.require_confirmation)
  eq(true, model_is_nil)
end

T["sia.agent.registry"]["parse_agent_file fails on missing frontmatter"] = function()
  child.lua([[
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
    local filepath = tmpdir .. "/bad.md"
    vim.fn.writefile({
      "No frontmatter",
      "Just content",
    }, filepath)

    local registry = require("sia.agent.registry")
    local agent, err = registry._parse_agent_file(filepath, "bad")
    _G.agent = agent
    _G.err = err

    vim.fn.delete(tmpdir, "rf")
  ]])

  eq(vim.NIL, child.lua_get("_G.agent"))
  eq("Invalid format: missing frontmatter", child.lua_get("_G.err"))
end

T["sia.agent.registry"]["parse_agent_file fails on missing system prompt"] = function()
  child.lua([[
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
    local filepath = tmpdir .. "/no-prompt.md"
    vim.fn.writefile({
      "---",
      "description: Missing prompt",
      "tools:",
      "  - bash",
      "---",
    }, filepath)

    local registry = require("sia.agent.registry")
    local agent, err = registry._parse_agent_file(filepath, "no-prompt")
    _G.agent = agent
    _G.err = err

    vim.fn.delete(tmpdir, "rf")
  ]])

  eq(vim.NIL, child.lua_get("_G.agent"))
  eq("Missing system prompt content", child.lua_get("_G.err"))
end

T["sia.agent.registry"]["parse_agent_file fails on missing description"] = function()
  child.lua([[
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
    local filepath = tmpdir .. "/no-desc.md"
    vim.fn.writefile({
      "---",
      "tools:",
      "  - bash",
      "---",
      "System prompt.",
    }, filepath)

    local registry = require("sia.agent.registry")
    local agent, err = registry._parse_agent_file(filepath, "no-desc")
    _G.agent = agent
    _G.err = err

    vim.fn.delete(tmpdir, "rf")
  ]])

  eq(vim.NIL, child.lua_get("_G.agent"))
  eq("Missing required field: description", child.lua_get("_G.err"))
end

T["sia.agent.registry"]["parse_agent_file fails on missing tools"] = function()
  child.lua([[
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
    local filepath = tmpdir .. "/no-tools.md"
    vim.fn.writefile({
      "---",
      "description: No tools",
      "---",
      "System prompt.",
    }, filepath)

    local registry = require("sia.agent.registry")
    local agent, err = registry._parse_agent_file(filepath, "no-tools")
    _G.agent = agent
    _G.err = err

    vim.fn.delete(tmpdir, "rf")
  ]])

  eq(vim.NIL, child.lua_get("_G.agent"))
  eq(
    "Missing or invalid required field: tools (must be a list)",
    child.lua_get("_G.err")
  )
end

T["sia.agent.registry"]["get_agents returns empty when no agents configured"] = function()
  child.lua([[
    local config = require("sia.config")
    local orig = config.get_local_config
    config.get_local_config = function() return nil end

    local registry = require("sia.agent.registry")
    _G.result = registry.get_agents()

    config.get_local_config = orig
  ]])

  eq({}, child.lua_get("_G.result"))
end

T["sia.agent.registry"]["get_agents loads global agents by name"] = function()
  child.lua([[
    local config = require("sia.config")
    local registry = require("sia.agent.registry")
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")

    vim.fn.writefile({
      "---",
      "description: Research agent",
      "tools:",
      "  - view",
      "---",
      "You research topics.",
    }, tmpdir .. "/researcher.md")

    vim.fn.writefile({
      "---",
      "description: Code agent",
      "tools:",
      "  - bash",
      "---",
      "You write code.",
    }, tmpdir .. "/coder.md")

    registry._get_default_agents_dir = function() return tmpdir end

    local orig = config.get_local_config
    config.get_local_config = function()
      return { agents = { "researcher" } }
    end

    local orig_root = vim.fs.root
    vim.fs.root = function(_, _) return nil end

    _G.result = registry.get_agents()

    vim.fs.root = orig_root
    config.get_local_config = orig
    vim.fn.delete(tmpdir, "rf")
  ]])

  local result = child.lua_get("_G.result")
  eq(nil, result.coder)
  eq("researcher", result.researcher.name)
  eq("Research agent", result.researcher.description)
end

T["sia.agent.registry"]["get_agents supports subdirectory names"] = function()
  child.lua([[
    local config = require("sia.config")
    local registry = require("sia.agent.registry")
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir .. "/code", "p")

    vim.fn.writefile({
      "---",
      "description: Code review agent",
      "tools:",
      "  - view",
      "---",
      "Review code carefully.",
    }, tmpdir .. "/code/review.md")

    registry._get_default_agents_dir = function() return tmpdir end

    local orig = config.get_local_config
    config.get_local_config = function()
      return { agents = { "code/review" } }
    end

    local orig_root = vim.fs.root
    vim.fs.root = function(_, _) return nil end

    _G.result = registry.get_agents()

    vim.fs.root = orig_root
    config.get_local_config = orig
    vim.fn.delete(tmpdir, "rf")
  ]])

  local result = child.lua_get("_G.result")
  eq("code/review", result["code/review"].name)
  eq("Code review agent", result["code/review"].description)
end

T["sia.agent.registry"]["get_agents local overrides global"] = function()
  child.lua([[
    local config = require("sia.config")
    local registry = require("sia.agent.registry")

    local global_dir = vim.fn.tempname()
    vim.fn.mkdir(global_dir, "p")
    vim.fn.writefile({
      "---",
      "description: Global researcher",
      "tools:",
      "  - view",
      "---",
      "Global system prompt.",
    }, global_dir .. "/researcher.md")

    local project_root = vim.fn.tempname()
    local local_agents_dir = project_root .. "/.sia/agents"
    vim.fn.mkdir(local_agents_dir, "p")
    vim.fn.writefile({
      "---",
      "description: Local researcher (override)",
      "tools:",
      "  - view",
      "  - bash",
      "---",
      "Local system prompt.",
    }, local_agents_dir .. "/researcher.md")

    registry._get_default_agents_dir = function() return global_dir end

    local orig = config.get_local_config
    config.get_local_config = function()
      return { agents = { "researcher" } }
    end

    local orig_root = vim.fs.root
    vim.fs.root = function(_, _) return project_root end

    _G.result = registry.get_agents()

    vim.fs.root = orig_root
    config.get_local_config = orig
    vim.fn.delete(global_dir, "rf")
    vim.fn.delete(project_root, "rf")
  ]])

  local result = child.lua_get("_G.result")
  eq("researcher", result.researcher.name)
  eq("Local researcher (override)", result.researcher.description)
  eq({ "view", "bash" }, result.researcher.tools)
end

-- ─── utils.parse_yaml_frontmatter ─────────────────────────────────────────────

T["sia.markdown"] = MiniTest.new_set()

T["sia.markdown"]["parse_yaml_frontmatter handles boolean values"] = function()
  child.lua([[
    local markdown = require("sia.markdown")
    local result = markdown.parse_yaml_frontmatter({
      "description: my-agent",
      "require_confirmation: false",
      "active: true",
      "tools:",
      "  - bash",
    })
    _G.result = result
  ]])

  local result = child.lua_get("_G.result")
  eq("my-agent", result.description)
  eq(false, result.require_confirmation)
  eq(true, result.active)
  eq({ "bash" }, result.tools)
end

return T
