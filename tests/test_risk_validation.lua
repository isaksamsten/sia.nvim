local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["validate_risk"] = MiniTest.new_set()

-- Helper to create a temporary config file and load it
local function load_config(config_json)
  local tmpfile = vim.fn.tempname()
  local f = io.open(tmpfile, "w")
  f:write(vim.json.encode(config_json))
  f:close()

  local Config = require("sia.config")

  -- Clear any cached config
  package.loaded["sia.config"] = nil
  Config = require("sia.config")

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

T["validate_risk"]["accepts valid risk configuration"] = function()
  local config = {
    risk = {
      bash = {
        arguments = {
          command = {
            { pattern = "^rm", level = "warn" },
            { pattern = "^ls", level = "safe" },
            { pattern = "^git", level = "info" },
          },
        },
      },
      edit = {
        arguments = {
          target_file = {
            { pattern = "\\.env$", level = "warn" },
          },
        },
      },
    },
  }

  local success, result = load_config(config)
  eq(success, true)
  eq(type(result.risk), "table")
end

T["validate_risk"]["accepts empty risk configuration"] = function()
  local config = { risk = {} }
  local success, result = load_config(config)
  eq(success, true)
end

T["validate_risk"]["rejects risk that is not a table"] = function()
  local config = { risk = "invalid" }
  local success, err = load_config(config)
  eq(success, false)
  eq(err:match("'risk' must be an object") ~= nil, true)
end

T["validate_risk"]["rejects tool without arguments field"] = function()
  local config = {
    risk = {
      bash = {
        command = {},
      },
    },
  }
  local success, err = load_config(config)
  eq(success, false)
  eq(err:match("must have an 'arguments' field") ~= nil, true)
end

T["validate_risk"]["rejects arguments that is not a table"] = function()
  local config = {
    risk = {
      bash = {
        arguments = "invalid",
      },
    },
  }
  local success, err = load_config(config)
  eq(success, false)
  eq(err:match("arguments must be an object") ~= nil, true)
end

T["validate_risk"]["rejects patterns that is not an array"] = function()
  local config = {
    risk = {
      bash = {
        arguments = {
          command = "not an array",
        },
      },
    },
  }
  local success, err = load_config(config)
  eq(success, false)
  eq(err:match("must be an array") ~= nil, true)
end

T["validate_risk"]["rejects pattern entry without pattern field"] = function()
  local config = {
    risk = {
      bash = {
        arguments = {
          command = {
            { level = "warn" },
          },
        },
      },
    },
  }
  local success, err = load_config(config)
  eq(success, false)
  eq(err:match("pattern must be a string") ~= nil, true)
end

T["validate_risk"]["rejects pattern entry without level field"] = function()
  local config = {
    risk = {
      bash = {
        arguments = {
          command = {
            { pattern = "^rm" },
          },
        },
      },
    },
  }
  local success, err = load_config(config)
  eq(success, false)
  eq(err:match("level must be a string") ~= nil, true)
end

T["validate_risk"]["rejects invalid level value"] = function()
  local config = {
    risk = {
      bash = {
        arguments = {
          command = {
            { pattern = "^rm", level = "critical" },
          },
        },
      },
    },
  }
  local success, err = load_config(config)
  eq(success, false)
  eq(err:match("must be one of 'safe', 'info', or 'warn'") ~= nil, true)
end

T["validate_risk"]["rejects invalid lua pattern"] = function()
  local config = {
    risk = {
      bash = {
        arguments = {
          command = {
            { pattern = "[invalid", level = "warn" },
          },
        },
      },
    },
  }
  local success, err = load_config(config)
  eq(success, false)
  eq(err:match("invalid regex pattern") ~= nil, true)
end

T["validate_risk"]["accepts multiple tools with multiple arguments"] = function()
  local config = {
    risk = {
      bash = {
        arguments = {
          command = {
            { pattern = "^rm", level = "warn" },
          },
        },
      },
      edit = {
        arguments = {
          target_file = {
            { pattern = "\\.lua$", level = "safe" },
          },
          old_string = {
            { pattern = ".*", level = "info" },
          },
        },
      },
    },
  }

  local success, result = load_config(config)
  eq(success, true)
  eq(type(result.risk), "table")
end

return T
