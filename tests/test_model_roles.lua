local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local fails = MiniTest.expect.error
local model_config = require("sia.config.model")

local function with_config(settings, local_config, fn)
  local config = require("sia.config")
  local saved = config._raw_options.settings
  local get_local = config.get_local_config
  config._raw_options.settings = settings
  config.get_local_config = function()
    return local_config
  end
  local ok, err = pcall(fn, config)
  config._raw_options.settings = saved
  config.get_local_config = get_local
  if not ok then
    error(err)
  end
end

T["string shorthands cover every tier"] = function()
  local roles = model_config.normalize("openai/gpt-4.1")
  for tier in pairs(model_config.tiers) do
    eq(roles.default[tier].name, "openai/gpt-4.1")
  end
  roles =
    model_config.normalize({ default = "openai/gpt-4.1", vision = "openai/gpt-5.2" })
  eq(roles.vision.mini.name, "openai/gpt-5.2")
  eq(roles.vision.pro.name, "openai/gpt-5.2")
  roles =
    model_config.normalize({ name = "openai/gpt-5.2", options = { temperature = 0.3 } })
  for tier in pairs(model_config.tiers) do
    eq(roles.default[tier].name, "openai/gpt-5.2")
    eq(roles.default[tier].options.temperature, 0.3)
  end
end

T["tier entries preserve concrete options"] = function()
  local roles = model_config.normalize({
    default = {
      default = "openai/gpt-4.1",
      pro = { name = "openai/gpt-5.2", options = { temperature = 0.5 } },
    },
  })
  eq(roles.default.mini, nil)
  eq(roles.default.pro.options.temperature, 0.5)
end

T["invalid tiers and malformed leaves are rejected"] = function()
  fails(function()
    model_config.normalize({ default = { typo = "openai/gpt-4.1" } })
  end, "not a valid tier")
  fails(function()
    model_config.normalize({ vision = { mini = 5 } })
  end, "model.vision.mini")
  fails(function()
    model_config.normalize({
      default = { default = { name = "openai/gpt-4.1", options = false } },
    })
  end, "options must be a table")
end

T["role fallbacks use the default tier before the default model"] = function()
  with_config(
    {
      model = {
        default = { default = "openai/gpt-5.2", mini = "openai/gpt-4.1" },
        coding = { default = "deepseek/deepseek-chat", pro = "openai/gpt-5.2" },
      },
    },
    nil,
    function()
      local models = require("sia.model")
      eq(models.resolve_role("coding", "default").name, "deepseek/deepseek-chat")
      eq(models.resolve_role("coding", "mini").name, "openai/gpt-4.1")
      eq(models.resolve_role("unknown", "mini").name, "openai/gpt-4.1")
      eq(models.resolve_role("unknown", "pro").name, "openai/gpt-5.2")
      eq(models.resolve().name, "openai/gpt-5.2")
      fails(function()
        models.resolve_role("coding", "typo")
      end, "tier must be")
    end
  )
end

T["local configuration merges tiers and replaces concrete leaves"] = function()
  local settings = {
    model = {
      default = {
        default = { name = "openai/gpt-5.2", options = { temperature = 0.5 } },
        mini = "openai/gpt-4.1",
      },
      vision = "openai/gpt-4.1",
    },
  }
  with_config(
    settings,
    { model = { default = { default = "deepseek/deepseek-chat" } } },
    function(config)
      local roles = config.options.settings.model
      eq(roles.default.default.name, "deepseek/deepseek-chat")
      eq(roles.default.default.options, nil)
      eq(roles.default.mini.name, "openai/gpt-4.1")
      eq(roles.vision.pro.name, "openai/gpt-4.1")
      eq(settings.model.default.default.options.temperature, 0.5)
    end
  )
  with_config(settings, { model = "deepseek/deepseek-chat" }, function(config)
    eq(config.options.settings.model.default.mini.name, "deepseek/deepseek-chat")
    eq(config.options.settings.model.default.pro.name, "deepseek/deepseek-chat")
  end)
end

T["setup merges normalized layers without leaking options"] = function()
  with_config(
    {
      model = {
        default = {
          default = { name = "openai/gpt-5.2", options = { temperature = 0.5 } },
          mini = "openai/gpt-4.1",
        },
      },
    },
    nil,
    function(config)
      config.setup({
        settings = {
          model = {
            default = { default = "deepseek/deepseek-chat" },
            vision = "openai/gpt-4.1",
          },
        },
      })
      eq(config.options.settings.model.default.default.options, nil)
      eq(config.options.settings.model.default.mini.name, "openai/gpt-4.1")
      config.setup({ settings = { model = "openai/gpt-5.2" } })
      eq(config.options.settings.model.default.mini.name, "openai/gpt-5.2")
      eq(config.options.settings.model.vision.default.name, "openai/gpt-4.1")
    end
  )
end

T["role models resolve aliases and retain options"] = function()
  with_config({ model = { default = "openai/gpt-4.1", vision = "visual" } }, {
    aliases = { visual = { name = "openai/gpt-5.2", options = { temperature = 0.2 } } },
  }, function()
    local model = require("sia.model").resolve_role("vision", "mini", { "image" })
    eq(model.name, "visual")
    eq(model.options.temperature, 0.2)
  end)
end

T["vision requirements reject an incapable fallback"] = function()
  with_config({ model = "deepseek/deepseek-chat" }, nil, function()
    fails(function()
      require("sia.model").resolve_role("vision", "default", { "image" })
    end, "does not support 'image'")
  end)
end

T["actions use roles and tiers while invocation overrides remain concrete"] = function()
  with_config(
    {
      model = {
        default = { default = "openai/gpt-5.2", mini = "openai/gpt-4.1" },
        coding = { default = "openai/gpt-4.1", pro = "deepseek/deepseek-chat" },
      },
    },
    nil,
    function()
      local from_action = require("sia.conversation").from_action
      local action = {
        mode = "chat",
        model = { role = "coding", tier = "pro" },
        system = {},
        agents = {},
        skills = {},
      }
      local invocation = { input = {}, context = {} }
      eq(from_action(action, invocation).model.name, "deepseek/deepseek-chat")
      eq(
        from_action(action, invocation, { model = "openai/gpt-4.1" }).model.name,
        "openai/gpt-4.1"
      )
      action.model = { role = "unknown", tier = "mini" }
      eq(from_action(action, invocation).model.name, "openai/gpt-4.1")
      action.model = { role = "coding" }
      eq(from_action(action, invocation).model.name, "openai/gpt-4.1")
      action.model = "coding"
      eq(from_action(action, invocation).model.name, "openai/gpt-4.1")
      action.model = "default"
      eq(from_action(action, invocation).model.name, "openai/gpt-5.2")
      action.model = "unknown"
      eq(from_action(action, invocation).model.name, "openai/gpt-5.2")
      action.model = "openai/gpt-4.1"
      eq(from_action(action, invocation).model.name, "openai/gpt-5.2")
      action.model = { tier = "mini" }
      eq(from_action(action, invocation).model.name, "openai/gpt-4.1")
      action.model = nil
      eq(from_action(action, invocation).model.name, "openai/gpt-5.2")
      for _, invalid in ipairs({
        "",
        false,
        { name = "openai/gpt-4.1" },
        { tier = "typo" },
      }) do
        action.model = invalid
        fails(function()
          from_action(action, invocation)
        end, "action.model")
      end
    end
  )
end

T["bundled commit action uses the commit role with the default tier"] = function()
  local actions = require("sia.actions")
  local action = actions.commit()
  eq(action.model, "commit")
  local selection = { role = "coding", tier = "pro" }
  eq(actions.commit(selection).model, selection)
  action.user = {}
  with_config(
    { model = { default = "openai/gpt-4.1", commit = "openai/gpt-5.2" } },
    nil,
    function()
      eq(
        require("sia.conversation").from_action(action, {}).model.name,
        "openai/gpt-5.2"
      )
    end
  )
  with_config({ model = "openai/gpt-4.1" }, nil, function()
    eq(require("sia.conversation").from_action(action, {}).model.name, "openai/gpt-4.1")
  end)
end

T["agents select independent models and reject incapable fallbacks before starting"] = function()
  with_config(
    {
      model = {
        default = { default = "deepseek/deepseek-chat", mini = "openai/gpt-4.1" },
        vision = { default = "openai/gpt-5.2", mini = "deepseek/deepseek-chat" },
      },
    },
    nil,
    function()
      local registry = require("sia.agent.registry")
      local assistant = require("sia.assistant")
      local strategy = require("sia.strategy")
      local saved_get, saved_execute, saved_hidden =
        registry.get, assistant.execute_strategy, strategy.new_hidden
      local definitions = {
        vision = {
          model = { role = "vision", tier = "default" },
          requires = { "image" },
          tools = {},
          system_prompt = {},
        },
        fallback = {
          model = { role = "unknown", tier = "default" },
          requires = { "image" },
          tools = {},
          system_prompt = {},
        },
        shorthand = {
          model = "vision",
          requires = { "image" },
          tools = {},
          system_prompt = {},
        },
        default_shorthand = { model = "default", tools = {}, system_prompt = {} },
        implicit = { tools = {}, system_prompt = {} },
      }
      local started = 0
      registry.get = function(name)
        return definitions[name]
      end
      assistant.execute_strategy = function()
        started = started + 1
      end
      strategy.new_hidden = function()
        return {}
      end
      local ok, err = pcall(function()
        local runtime = require("sia.agent").new_runtime()
        local agent = runtime:spawn("vision", "Describe this image")
        eq(agent.conversation.model.name, "openai/gpt-5.2")
        local failed, reason = runtime:spawn("fallback", "Describe this image")
        eq(failed, nil)
        eq(reason:find("does not support 'image'", 1, true) ~= nil, true)
        eq(started, 1)
        eq(#runtime.items, 1)
        eq(
          runtime:spawn("implicit", "Explore").conversation.model.name,
          "openai/gpt-4.1"
        )
        eq(
          runtime:spawn("shorthand", "Describe this image").conversation.model.name,
          "openai/gpt-5.2"
        )
        eq(
          runtime:spawn("default_shorthand", "Explore").conversation.model.name,
          "deepseek/deepseek-chat"
        )
        eq(started, 4)
      end)
      registry.get, assistant.execute_strategy, strategy.new_hidden =
        saved_get, saved_execute, saved_hidden
      if not ok then
        error(err)
      end
    end
  )
end

return T
