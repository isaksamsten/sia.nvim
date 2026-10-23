local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["command saves scalars, nested options, and removes overrides"] = function()
  local config = require("sia.config")
  local local_config = require("sia.config.local")
  local saved_update = local_config.update_auto_config
  local saved_notify = vim.notify
  local json, errors = {}, {}
  local_config.update_auto_config = function(mutator)
    mutator(json)
    return json, "auto.json"
  end
  vim.notify = function(message, level)
    if level == vim.log.levels.ERROR then
      errors[#errors + 1] = message
    end
  end
  local ok, err = pcall(function()
    local command = require("sia.config.command")
    command.run({ args = "context.tools.strip_inputs false", bang = false })
    eq(json.context.tools.strip_inputs, false)
    command.run({ args = "context.tools.max_calls 12", bang = false })
    eq(json.context.tools.max_calls, 12)
    command.run({
      args = "model.default.default.options.reasoning.effort high",
      bang = false,
    })
    eq(json.model.default.default.options.reasoning.effort, "high")
    command.run({ args = "model.default.default.options.reasoning.effort", bang = true })
    eq(json.model, nil)
    command.run({ args = "model openai/gpt-4.1", bang = false })
    eq(json.model.default.mini.name, "openai/gpt-4.1")
    command.run({ args = "model.default.default.options.temperature 0.5", bang = false })
    command.run({
      args = "model.default.default.options.reasoning.effort high",
      bang = false,
    })
    command.run({ args = "model.default.default.options", bang = true })
    eq(json.model.default.default.options, nil)
    eq(json.model.default.default.name, "openai/gpt-4.1")
    command.run({ args = "model.default.default.options", bang = true })
    eq(json.model.default.default.name, "openai/gpt-4.1")
    command.run({ args = "model", bang = true })
    eq(json.model, nil)
    command.run({ args = "action.chat code/assistant", bang = false })
    eq(json.action.chat, "code/assistant")
    command.run({ args = "action.chat", bang = true })
    eq(json.action, nil)
    eq(errors, {})
    command.run({ args = "context.tools.strip_inputs wrong", bang = false })
    eq(#errors, 1)
  end)
  local_config.update_auto_config = saved_update
  vim.notify = saved_notify
  if not ok then
    error(err)
  end
end

T["command inspects model options without writing"] = function()
  local config = require("sia.config")
  local local_config = require("sia.config.local")
  local saved_notify, saved_update = vim.notify, local_config.update_auto_config
  local saved_model = config._raw_options.settings.model
  local saved_local = config.get_local_config
  local message
  local ok, err = pcall(function()
    config.get_local_config = function()
      return nil
    end
    config._raw_options.settings.model = {
      default = {
        default = { name = "openai/gpt-4.1", options = { temperature = 0.5 } },
      },
    }
    vim.notify = function(text)
      message = text
    end
    local_config.update_auto_config = function()
      error("unexpected write")
    end
    require("sia.config.command").run({
      args = "model.default.default.options",
      bang = false,
    })
    eq(
      message,
      "model.default.default.options = " .. vim.inspect({ temperature = 0.5 })
    )
  end)
  vim.notify, local_config.update_auto_config = saved_notify, saved_update
  config._raw_options.settings.model = saved_model
  config.get_local_config = saved_local
  if not ok then
    error(err)
  end
end

T["skills and agents only edit generated lists"] = function()
  local config = require("sia.config")
  local lc = require("sia.config.local")
  local saved_local, saved_update, saved_notify =
    config.get_local_config, lc.update_auto_config, vim.notify
  local json, writes, errors = {}, 0, {}
  local ok, err = pcall(function()
    config.get_local_config = function()
      return { skills = { "existing" }, agents = { "existing" } }
    end
    lc.update_auto_config = function(mutator)
      writes = writes + 1
      mutator(json)
      return json
    end
    vim.notify = function(message, level)
      if level == vim.log.levels.ERROR then
        errors[#errors + 1] = message
      end
    end
    local command = require("sia.config.command")
    for _, path in ipairs({ "skill", "agent" }) do
      local key = path == "skill" and "skills" or "agents"
      local before = writes
      command.run({ args = path .. " +existing", bang = false })
      eq(writes, before)
      command.run({ args = path .. " +new", bang = false })
      command.run({ args = path .. " +new", bang = false })
      eq(json[key], { "new" })
      command.run({ args = path .. " -existing", bang = false })
      eq(json[key], { "new" })
      command.run({ args = path .. " -new", bang = false })
      eq(json[key], nil)
      command.run({ args = path .. " +new", bang = false })
      command.run({ args = path, bang = true })
      eq(json[key], nil)
    end
    eq(errors, {})
  end)
  config.get_local_config, lc.update_auto_config, vim.notify =
    saved_local, saved_update, saved_notify
  if not ok then
    error(err)
  end
end

T["completion uses skill and agent registries"] = function()
  local skills = require("sia.skills.registry")
  local agents = require("sia.agent.registry")
  local saved_skills, saved_agents = skills.list_skill_names, agents.filter
  local ok, err = pcall(function()
    skills.list_skill_names = function()
      return { "zeta", "alpha" }
    end
    agents.filter = function()
      return { { name = "code/review" } }
    end
    local complete = require("sia.config.command").complete
    eq(complete("+a", "SiaConfig skill +a"), { "+alpha" })
    eq(complete("-z", "SiaConfig skill -z"), { "-zeta" })
    eq(complete("", "SiaConfig skill "), { "+alpha", "+zeta" })
    eq(complete("+code/", "SiaConfig agent +code/"), { "+code/review" })
    eq(complete("-code/", "SiaConfig agent -code/"), { "-code/review" })
    eq(complete("action.c", "SiaConfig action.c"), { "action.chat" })
    eq(complete("code/", "SiaConfig action.chat code/"), { "code/review" })
  end)
  skills.list_skill_names, agents.filter = saved_skills, saved_agents
  if not ok then
    error(err)
  end
end

return T
