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
      "  - bash!",
      "  - view",
      "model: openai/gpt-4.1",
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
  eq({ bash = true }, agent.auto_approve)
  eq("openai/gpt-4.1", agent.model)
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

T["sia.agent.registry"]["parse_agent_file defaults auto_approve to empty"] = function()
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
  eq({}, agent.auto_approve)
  eq(true, model_is_nil)
end

T["sia.agent.registry"]["parse_agent_file auto-approves all tools with ! suffix"] = function()
  child.lua([[
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
    local filepath = tmpdir .. "/fast.md"
    vim.fn.writefile({
      "---",
      "description: Fast agent",
      "tools:",
      "  - grep!",
      "  - view!",
      "  - bash!",
      "---",
      "System prompt here.",
    }, filepath)

    local registry = require("sia.agent.registry")
    local agent, err = registry._parse_agent_file(filepath, "fast")
    _G.agent = agent
    _G.err = err

    vim.fn.delete(tmpdir, "rf")
  ]])

  local agent = child.lua_get("_G.agent")
  local err = child.lua_get("_G.err")

  eq(vim.NIL, err)
  eq({ "grep", "view", "bash" }, agent.tools)
  eq({ grep = true, view = true, bash = true }, agent.auto_approve)
end

T["sia.agent.registry"]["parse_agent_file mixes approved and unapproved tools"] = function()
  child.lua([[
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
    local filepath = tmpdir .. "/mixed.md"
    vim.fn.writefile({
      "---",
      "description: Mixed agent",
      "tools:",
      "  - grep!",
      "  - view!",
      "  - bash",
      "  - edit",
      "---",
      "System prompt here.",
    }, filepath)

    local registry = require("sia.agent.registry")
    local agent, err = registry._parse_agent_file(filepath, "mixed")
    _G.agent = agent
    _G.err = err

    vim.fn.delete(tmpdir, "rf")
  ]])

  local agent = child.lua_get("_G.agent")
  local err = child.lua_get("_G.err")

  eq(vim.NIL, err)
  eq({ "grep", "view", "bash", "edit" }, agent.tools)
  eq({ grep = true, view = true }, agent.auto_approve)
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
    local ok, agent = pcall(registry._parse_agent_file, filepath, "bad")
    _G.ok = ok
    _G.agent = agent

    vim.fn.delete(tmpdir, "rf")
  ]])

  eq(true, child.lua_get("_G.ok"))
  eq(vim.NIL, child.lua_get("_G.agent"))
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
    local ok, agent = pcall(registry._parse_agent_file, filepath, "no-prompt")
    _G.ok = ok
    _G.agent = agent

    vim.fn.delete(tmpdir, "rf")
  ]])

  eq(true, child.lua_get("_G.ok"))
  eq(vim.NIL, child.lua_get("_G.agent"))
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
    local ok, agent = pcall(registry._parse_agent_file, filepath, "no-desc")
    _G.ok = ok
    _G.agent = agent

    vim.fn.delete(tmpdir, "rf")
  ]])

  eq(false, child.lua_get("_G.ok"))
  eq(true, child.lua_get("_G.agent"):find("Missing required field: description", 1, true) ~= nil)
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
    local ok, agent = pcall(registry._parse_agent_file, filepath, "no-tools")
    _G.ok = ok
    _G.agent = agent

    vim.fn.delete(tmpdir, "rf")
  ]])

  eq(false, child.lua_get("_G.ok"))
  eq(
    true,
    child.lua_get("_G.agent"):find(
      "Missing or invalid required field: tools (must be a list)",
      1,
      true
    ) ~= nil
  )
end

T["sia.agent.registry"]["get_agents returns empty when no agents configured"] = function()
  child.lua([[
    local config = require("sia.config")
    local orig = config.get_local_config
    config.get_local_config = function() return nil end

    local registry = require("sia.agent.registry")
    registry.scan()
    _G.result = registry.filter()

    config.get_local_config = orig
  ]])

  eq(0, #child.lua_get("_G.result"))
end

T["sia.agent.registry"]["get loads global agents by name"] = function()
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
      return { agents = {} }
    end

    local orig_root = vim.fs.root
    vim.fs.root = function(_, _) return nil end

    registry.scan()
    _G.result = registry.filter()

    vim.fs.root = orig_root
    config.get_local_config = orig
    vim.fn.delete(tmpdir, "rf")
  ]])

  local result = child.lua_get("_G.result")
  eq(0, #result)
end

T["sia.agent.registry"]["get supports subdirectory names"] = function()
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
      return { agents = {} }
    end

    local orig_root = vim.fs.root
    vim.fs.root = function(_, _) return nil end

    registry.scan()
    _G.result = registry.filter()

    vim.fs.root = orig_root
    config.get_local_config = orig
    vim.fn.delete(tmpdir, "rf")
  ]])

  local result = child.lua_get("_G.result")
  eq(0, #result)
end

T["sia.agent.registry"]["get local overrides global"] = function()
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
      return { agents = {} }
    end

    local orig_root = vim.fs.root
    vim.fs.root = function(_, _) return project_root end

    registry.scan()
    _G.result = registry.filter()

    vim.fs.root = orig_root
    config.get_local_config = orig
    vim.fn.delete(global_dir, "rf")
    vim.fn.delete(project_root, "rf")
  ]])

  local result = child.lua_get("_G.result")
  eq(0, #result)
end

-- ─── utils.parse_yaml_frontmatter ─────────────────────────────────────────────

T["sia.markdown"] = MiniTest.new_set()

T["sia.markdown"]["parse_yaml_frontmatter handles boolean values"] = function()
  child.lua([[
    local markdown = require("sia.markdown")
    local result = markdown.parse_yaml_frontmatter({
      "description: my-agent",
      "interactive: false",
      "active: true",
      "tools:",
      "  - bash",
    })
    _G.result = result
  ]])

  local result = child.lua_get("_G.result")
  eq("my-agent", result.description)
  eq(false, result.interactive)
  eq(true, result.active)
  eq({ "bash" }, result.tools)
end

return T
