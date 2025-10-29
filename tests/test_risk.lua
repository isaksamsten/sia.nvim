local risk = require("sia.risk")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

-- Helper to compile patterns to vim.regex objects like config.lua does
local function compile_risk_config(config)
  if not config or not config.risk then
    return config
  end

  for tool_name, tool_risk in pairs(config.risk) do
    if tool_risk.arguments then
      for param_name, patterns in pairs(tool_risk.arguments) do
        for i, pattern_def in ipairs(patterns) do
          local regex = vim.regex("\\v" .. pattern_def.pattern)
          -- Replace with just {level, regex}
          patterns[i] = { level = pattern_def.level, regex = regex }
        end
      end
    end
  end

  return config
end

local function with_mock_local_config(mock, fn)
  local config = require("sia.config")
  local original_get_local_config = config.get_local_config
  config.get_local_config = function()
    return compile_risk_config(mock)
  end
  local ok, err = pcall(fn)
  config.get_local_config = original_get_local_config
  if not ok then
    error(err)
  end
end

T["risk level resolution"] = MiniTest.new_set()

T["risk level resolution"]["returns default when no config"] = function()
  with_mock_local_config({}, function()
    local level = risk.get_risk_level("bash", { command = "ls" }, "info")
    eq("info", level)
  end)
end

T["risk level resolution"]["returns default when no risk config"] = function()
  with_mock_local_config({ permission = {} }, function()
    local level = risk.get_risk_level("bash", { command = "ls" }, "info")
    eq("info", level)
  end)
end

T["risk level resolution"]["returns default when tool not in config"] = function()
  with_mock_local_config({
    risk = {
      edit = {
        arguments = { target_file = { { pattern = "\\.env$", level = "warn" } } },
      },
    },
  }, function()
    local level = risk.get_risk_level("bash", { command = "ls" }, "info")
    eq("info", level)
  end)
end

T["risk level resolution"]["returns default when no arguments config"] = function()
  with_mock_local_config({
    risk = {
      bash = {},
    },
  }, function()
    local level = risk.get_risk_level("bash", { command = "ls" }, "info")
    eq("info", level)
  end)
end

T["risk level resolution"]["matches simple pattern and returns level"] = function()
  with_mock_local_config({
    risk = {
      bash = {
        arguments = {
          command = {
            { pattern = "^rm", level = "warn" },
          },
        },
      },
    },
  }, function()
    local level = risk.get_risk_level("bash", { command = "rm -rf /" }, "info")
    eq("warn", level)
  end)
end

T["risk level resolution"]["returns default when pattern doesn't match"] = function()
  with_mock_local_config({
    risk = {
      bash = {
        arguments = {
          command = {
            { pattern = "^rm", level = "warn" },
          },
        },
      },
    },
  }, function()
    local level = risk.get_risk_level("bash", { command = "ls" }, "info")
    eq("info", level)
  end)
end

T["risk level resolution"]["takes highest level when multiple patterns match"] = function()
  with_mock_local_config({
    risk = {
      bash = {
        arguments = {
          command = {
            { pattern = "git", level = "safe" },
            { pattern = "rm", level = "warn" },
          },
        },
      },
    },
  }, function()
    local level = risk.get_risk_level("bash", { command = "git rm -rf /" }, "info")
    eq("warn", level)
  end)
end

T["risk level resolution"]["escalates from default"] = function()
  with_mock_local_config({
    risk = {
      bash = {
        arguments = {
          command = {
            { pattern = "^sudo", level = "warn" },
          },
        },
      },
    },
  }, function()
    local level = risk.get_risk_level("bash", { command = "sudo rm" }, "info")
    eq("warn", level)
  end)
end

T["risk level resolution"]["de-escalates from default"] = function()
  with_mock_local_config({
    risk = {
      bash = {
        arguments = {
          command = {
            { pattern = "^ls", level = "safe" },
          },
        },
      },
    },
  }, function()
    local level = risk.get_risk_level("bash", { command = "ls -la" }, "info")
    eq("safe", level)
  end)
end

T["risk level resolution"]["user can override tool warn to safe"] = function()
  with_mock_local_config({
    risk = {
      bash = {
        arguments = {
          command = {
            { pattern = "^rm", level = "safe" },
          },
        },
      },
    },
  }, function()
    local level = risk.get_risk_level("bash", { command = "rm safe-file.txt" }, "warn")
    eq("safe", level)
  end)
end

T["risk level resolution"]["handles nil argument value"] = function()
  with_mock_local_config({
    risk = {
      bash = {
        arguments = {
          command = {
            { pattern = "^$", level = "safe" },
          },
        },
      },
    },
  }, function()
    local level = risk.get_risk_level("bash", {}, "info")
    eq("safe", level)
  end)
end

T["risk level resolution"]["handles numeric argument value"] = function()
  with_mock_local_config({
    risk = {
      dummy = {
        arguments = {
          count = {
            { pattern = "^[0-9]+$", level = "safe" },
          },
        },
      },
    },
  }, function()
    local level = risk.get_risk_level("dummy", { count = 123 }, "info")
    eq("safe", level)
  end)
end

T["risk level resolution"]["checks multiple arguments"] = function()
  with_mock_local_config({
    risk = {
      edit = {
        arguments = {
          target_file = {
            { pattern = "%.lua$", level = "safe" },
          },
          old_string = {
            { pattern = "password", level = "warn" },
          },
        },
      },
    },
  }, function()
    -- Both arguments match, highest wins
    local level = risk.get_risk_level("edit", {
      target_file = "config.lua",
      old_string = "password = 123",
    }, "info")
    eq("warn", level)
  end)
end

T["auto-confirm checks"] = MiniTest.new_set()

T["auto-confirm checks"]["safe allows auto-confirm"] = function()
  eq(true, risk.allows_auto_confirm("safe"))
end

T["auto-confirm checks"]["info allows auto-confirm"] = function()
  eq(true, risk.allows_auto_confirm("info"))
end

T["auto-confirm checks"]["warn does not allow auto-confirm"] = function()
  eq(false, risk.allows_auto_confirm("warn"))
end

return T
