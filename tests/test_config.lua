local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

-- Helper to create a temporary config file and load it
local function load_config(config_json)
  local tmpfile = vim.fn.tempname()
  local f = io.open(tmpfile, "w")
  f:write(vim.json.encode(config_json))
  f:close()

  -- Save the existing config module so we can restore it after the test
  local saved_config = package.loaded["sia.config"]

  -- Clear any cached config to get a fresh module
  package.loaded["sia.config"] = nil
  local Config = require("sia.config")

  local original_cwd = vim.fn.getcwd()

  -- Create a temp directory and set it as cwd
  local tmpdir = vim.fn.fnamemodify(tmpfile, ":h")
  local config_dir = tmpdir .. "/.sia"
  vim.fn.mkdir(config_dir, "p")
  vim.fn.rename(tmpfile, config_dir .. "/config.json")

  -- Capture notifications
  local notifications = {}
  local original_notify = vim.notify
  vim.notify = function(msg, level)
    table.insert(notifications, { msg = msg, level = level })
  end

  vim.fn.chdir(tmpdir)
  local result = Config.get_local_config()
  vim.fn.chdir(original_cwd)

  vim.notify = original_notify

  -- Restore the original config module so other tests are not affected
  package.loaded["sia.config"] = saved_config

  -- Clean up
  vim.fn.delete(config_dir, "rf")

  -- Check if validation failed (notification with ERROR level)
  local validation_error = nil
  for _, notif in ipairs(notifications) do
    if notif.level == vim.log.levels.ERROR then
      validation_error = notif.msg
      break
    end
  end

  if validation_error then
    return false, validation_error
  end

  return result ~= nil, result
end

local function with_mock_local_config(mock, fn)
  local config = require("sia.config")
  local original_get_local_config = config.get_local_config
  config.get_local_config = function()
    return mock
  end
  local ok, err = pcall(fn)
  config.get_local_config = original_get_local_config
  if not ok then
    error(err)
  end
end

T["validate_aliases"] = MiniTest.new_set()

T["validate_aliases"]["accepts valid alias"] = function()
  local config = {
    aliases = {
      ["fast-codex"] = {
        name = "codex/gpt-5.3-codex",
        options = { reasoning_effort = "low" },
      },
    },
  }
  local success, result = load_config(config)
  eq(success, true)
  eq(type(result.aliases), "table")
  eq(result.aliases["fast-codex"].name, "codex/gpt-5.3-codex")
  eq(result.aliases["fast-codex"].options.reasoning_effort, "low")
end

T["validate_aliases"]["accepts empty aliases"] = function()
  local config = { aliases = {} }
  local success = load_config(config)
  eq(success, true)
end

T["validate_aliases"]["accepts no aliases field"] = function()
  local config = {}
  local success = load_config(config)
  eq(success, true)
end

T["validate_aliases"]["rejects aliases that is not a table"] = function()
  local config = { aliases = "invalid" }
  local success, err = load_config(config)
  eq(success, false)
  eq(err:match("'aliases' must be an object") ~= nil, true)
end

T["validate_aliases"]["rejects alias without name field"] = function()
  local config = {
    aliases = {
      ["my-alias"] = { options = { reasoning_effort = "high" } },
    },
  }
  local success, err = load_config(config)
  eq(success, false)
  eq(err:match("must have a 'name' field") ~= nil, true)
end

T["validate_aliases"]["rejects alias with invalid model name"] = function()
  local config = {
    aliases = {
      ["my-alias"] = { name = "nonexistent/model" },
    },
  }
  local success, err = load_config(config)
  eq(success, false)
  eq(err:match("is not a valid model name") ~= nil, true)
end

T["validate_aliases"]["rejects alias that is not a table"] = function()
  local config = {
    aliases = {
      ["my-alias"] = "codex/gpt-5.3-codex",
    },
  }
  local success, err = load_config(config)
  eq(success, false)
  eq(err:match("must be an object") ~= nil, true)
end

T["validate_aliases"]["allows alias as default model"] = function()
  local config = {
    aliases = {
      ["codex-high"] = {
        name = "codex/gpt-5.3-codex",
        options = { reasoning_effort = "high" },
      },
    },
    model = "codex-high",
  }
  local success, result = load_config(config)
  eq(success, true)
  eq(result.model.name, "codex-high")
end

T["resolve_aliases"] = MiniTest.new_set()

T["resolve_aliases"]["resolves alias to real model with overrides"] = function()
  with_mock_local_config({
    aliases = {
      ["codex-high"] = {
        name = "codex/gpt-5.3-codex",
        options = { reasoning_effort = "high" },
      },
    },
  }, function()
    local model = require("sia.model")
    local m = model.resolve("codex-high")
    -- Should resolve to the underlying model's spec
    eq(m.provider_name, "codex")
    eq(m.api_name, "gpt-5.3-codex")
    -- Alias options are merged in
    eq(m.options.reasoning_effort, "high")
  end)
end

T["resolve_aliases"]["alias params are available via Model.options"] = function()
  with_mock_local_config({
    aliases = {
      ["codex-high"] = {
        name = "codex/gpt-5.3-codex",
        options = { reasoning_effort = "high" },
      },
    },
  }, function()
    local model = require("sia.model")
    local m = model.resolve("codex-high")
    eq(m.provider_name, "codex")
    eq(m.api_name, "gpt-5.3-codex")
    eq(m.options.reasoning_effort, "high")
  end)
end

T["resolve_aliases"]["non-alias model passes through unchanged"] = function()
  with_mock_local_config({
    aliases = {
      ["codex-high"] = {
        name = "codex/gpt-5.3-codex",
        options = { reasoning_effort = "high" },
      },
    },
  }, function()
    local model = require("sia.model")
    local m = model.resolve("codex/gpt-5.3-codex")
    eq(m.provider_name, "codex")
    eq(m.api_name, "gpt-5.3-codex")
    -- No alias options, no local overrides => empty options table
    eq(m.options.reasoning_effort, nil)
  end)
end

T["resolve_aliases"]["works with no local config"] = function()
  with_mock_local_config(nil, function()
    local model = require("sia.model")
    local m = model.resolve("codex/gpt-5.3-codex")
    eq(m.provider_name, "codex")
    eq(m.api_name, "gpt-5.3-codex")
  end)
end

T["resolve_aliases"]["alias combined with model overrides"] = function()
  with_mock_local_config({
    aliases = {
      ["codex-high"] = {
        name = "codex/gpt-5.3-codex",
        options = { reasoning_effort = "high" },
      },
    },
    models = {
      codex = {
        ["gpt-5.3-codex"] = { temperature = 0.5 },
      },
    },
  }, function()
    local model = require("sia.model")
    local m = model.resolve("codex-high")
    eq(m.provider_name, "codex")
    eq(m.api_name, "gpt-5.3-codex")
    eq(m.options.reasoning_effort, "high")
    eq(m.options.temperature, 0.5)
  end)
end

T["resolve_aliases"]["alias params take precedence over local model overrides"] = function()
  with_mock_local_config({
    aliases = {
      ["codex-high"] = {
        name = "codex/gpt-5.3-codex",
        options = { reasoning_effort = "high" },
      },
    },
    models = {
      codex = {
        ["gpt-5.3-codex"] = {
          reasoning_effort = "low", temperature = 0.5,
        },
      },
    },
  }, function()
    local model = require("sia.model")
    -- Alias pins reasoning_effort = "high", overriding the local override "low"
    local m = model.resolve("codex-high")
    eq(m.options.reasoning_effort, "high")
    eq(m.options.temperature, 0.5)

    -- Non-alias access gets the local override
    local base = model.resolve("codex/gpt-5.3-codex")
    eq(base.options.reasoning_effort, "low")
    eq(base.options.temperature, 0.5)
  end)
end

T["override_action"] = MiniTest.new_set()

T["override_action"]["get correct chat action with override"] = function()
  with_mock_local_config({
    action = { chat = "test" },
  }, function()
    local config = require("sia.config")
    config.options.actions["test"] = { test = 1 }
    local test = config.options.settings.actions["chat"]
    eq(test.test, 1)
  end)
end

T["validate_permissions"] = MiniTest.new_set()

T["validate_permissions"]["accepts multiple allow rules for a single tool"] = function()
  local success, result = load_config({
    permission = {
      allow = {
        view = {
          {
            arguments = {
              path = { "^lua/sia/[^/]+\\.lua$" },
            },
          },
          {
            arguments = {
              path = { "^tests/[^/]+\\.lua$" },
            },
          },
        },
      },
    },
  })

  eq(success, true)
  eq(type(result.permission.allow.view), "table")
end

return T
