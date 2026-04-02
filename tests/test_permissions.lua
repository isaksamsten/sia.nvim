local utils = require("sia.tools.utils")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["permissions (nil treated as empty)"] = MiniTest.new_set()

local function compile_pattern(pattern_def)
  if type(pattern_def) == "string" then
    return vim.regex("\\v" .. pattern_def)
  elseif type(pattern_def) == "table" and pattern_def.pattern then
    return vim.regex("\\v" .. pattern_def.pattern)
  else
    return pattern_def
  end
end

local function compile_permission_config(config)
  if not config or not config.permission then
    return config
  end

  for section_name, section in pairs(config.permission) do
    for tool_name, tool_perms in pairs(section) do
      local rules = vim.islist(tool_perms) and tool_perms or { tool_perms }
      for _, rule in ipairs(rules) do
        if rule.arguments then
          for param_name, patterns in pairs(rule.arguments) do
            for i, pattern_def in ipairs(patterns) do
              patterns[i] = compile_pattern(pattern_def)
            end
          end
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
    return compile_permission_config(mock)
  end
  local ok, err = pcall(fn)
  config.get_local_config = original_get_local_config
  if not ok then
    error(err)
  end
end

local function create_dummy_tool(name, read_only, runner, extra_opts)
  return utils.new_tool({
    definition = {
      name = name,
      description = "dummy",
      required = {},
      parameters = {},
    },
    read_only = read_only,
    persist_allow = extra_opts and extra_opts.persist_allow or nil,
  }, function(args, conversation, callback, opts)
    runner(args, conversation, callback, opts)
  end)
end

local function with_temp_project(initial_config, fn)
  local tmpdir = vim.fn.tempname()
  local config_dir = tmpdir .. "/.sia"
  local config_path = config_dir .. "/config.json"
  local auto_path = config_dir .. "/auto.json"
  local original_cwd = vim.fn.getcwd()
  local saved_config = package.loaded["sia.config"]
  local saved_permissions = package.loaded["sia.permissions"]

  vim.fn.mkdir(config_dir, "p")
  if initial_config ~= nil then
    vim.fn.writefile({ vim.json.encode(initial_config) }, config_path)
  end

  package.loaded["sia.config"] = nil
  package.loaded["sia.permissions"] = nil
  vim.fn.chdir(tmpdir)

  local ok, err = pcall(fn, config_path, auto_path)

  vim.fn.chdir(original_cwd)
  package.loaded["sia.config"] = saved_config
  package.loaded["sia.permissions"] = saved_permissions
  vim.fn.delete(tmpdir, "rf")

  if not ok then
    error(err)
  end
end

-- NIL/empty specific cases
T["permissions (nil treated as empty)"]["deny triggers when arg is missing (nil)"] = function()
  with_mock_local_config({
    permission = {
      deny = {
        dummy = {
          arguments = { foo = { "^$" } },
        },
      },
    },
  }, function()
    local executed = false
    local tool = create_dummy_tool("dummy", true, function(_, _, _, _)
      executed = true
    end)

    local result
    tool.implementation.execute({}, function(res)
      result = res
    end, { conversation = { auto_confirm_tools = {} } })

    eq(false, executed)
    eq("OPERATION BLOCKED BY LOCAL CONFIGURATION", result.content[1])
  end)
end

T["permissions (nil treated as empty)"]["deny does NOT trigger when arg is false (explicitly set)"] = function()
  with_mock_local_config({
    permission = {
      deny = {
        dummy = {
          arguments = { foo = { "^$" } },
        },
      },
    },
  }, function()
    local executed = false
    local tool = create_dummy_tool("dummy", true, function(_, _, callback, _)
      executed = true
      callback({ kind = "ok", content = { "ran" } })
    end)

    local result
    tool.implementation.execute({ foo = false }, function(res)
      result = res
    end, { conversation = { auto_confirm_tools = {} } })

    eq(true, executed)
    eq("ok", result.kind)
  end)
end

T["permissions (nil treated as empty)"]["allow auto-allow when arg is missing (nil)"] = function()
  with_mock_local_config({
    permission = {
      allow = {
        dummy = {
          arguments = { foo = { "^$" } },
          choice = 2,
        },
      },
    },
  }, function()
    local tool = create_dummy_tool("dummy", true, function(_, _, callback, _)
      callback({ kind = "ok", content = { "ran" } })
    end)

    local can_parallel = tool.implementation.allow_parallel(
      {},
      { ignore_tool_confirm = false, auto_confirm_tools = {} }
    )
    eq(true, can_parallel)
  end)
end

T["permissions (nil treated as empty)"]["ask on missing arg forces prompt even if auto-confirm is set"] = function()
  with_mock_local_config({
    permission = {
      ask = {
        dummy = {
          arguments = { foo = { "^$" } },
        },
      },
    },
  }, function()
    local config = require("sia.config")
    -- Force using vim.ui so we can stub it easily
    local original_ui_flag = config.options.settings.ui.use_vim_ui
    config.options.settings.ui.use_vim_ui = true

    local prompt_called = false
    local original_vim_ui_input = vim.ui.input
    vim.ui.input = function(opts, cb)
      prompt_called = true
      cb("")
    end

    local tool = create_dummy_tool("dummy", true, function(_, _, callback, opts)
      opts.user_input("Do it", {
        must_confirm = false,
        on_accept = function()
          callback({ kind = "ok", content = { "accepted" } })
        end,
      })
    end)

    local result
    tool.implementation.execute({}, function(res)
      result = res
    end, { conversation = { auto_confirm_tools = { dummy = 1 } } })

    eq(true, prompt_called)
    eq("ok", result.kind)

    vim.ui.input = original_vim_ui_input
    config.options.settings.ui.use_vim_ui = original_ui_flag
  end)
end

-- General pattern behavior tests (non-nil)
T["permissions (nil treated as empty)"]["allow with exact string pattern"] = function()
  with_mock_local_config({
    permission = {
      allow = {
        dummy = { arguments = { foo = { "^foo$" } } },
      },
    },
  }, function()
    local tool = create_dummy_tool("dummy", true, function(_, _, callback, _)
      callback({ kind = "ok", content = { "ran" } })
    end)

    local ok1 = tool.implementation.allow_parallel(
      { foo = "foo" },
      { ignore_tool_confirm = false, auto_confirm_tools = {} }
    )
    local ok2 = tool.implementation.allow_parallel(
      { foo = "bar" },
      { ignore_tool_confirm = false, auto_confirm_tools = {} }
    )
    eq(true, ok1)
    eq(false, ok2)
  end)
end

T["permissions (nil treated as empty)"]["allow with numeric coerced to string"] = function()
  with_mock_local_config({
    permission = {
      allow = {
        dummy = { arguments = { n = { "^[0-9]+$" } } },
      },
    },
  }, function()
    local tool = create_dummy_tool("dummy", true, function(_, _, callback, _)
      callback({ kind = "ok", content = { "ran" } })
    end)

    local ok1 = tool.implementation.allow_parallel(
      { n = 123 },
      { ignore_tool_confirm = false, auto_confirm_tools = {} }
    )
    local ok2 = tool.implementation.allow_parallel(
      { n = "abc" },
      { ignore_tool_confirm = false, auto_confirm_tools = {} }
    )
    eq(true, ok1)
    eq(false, ok2)
  end)
end

T["permissions (nil treated as empty)"]["allow requires all configured keys to match"] = function()
  with_mock_local_config({
    permission = {
      allow = {
        dummy = { arguments = { a = { "^x$" }, b = { "^y$" } } },
      },
    },
  }, function()
    local tool = create_dummy_tool("dummy", true, function(_, _, callback, _)
      callback({ kind = "ok", content = { "ran" } })
    end)

    local ok1 = tool.implementation.allow_parallel(
      { a = "x", b = "y" },
      { ignore_tool_confirm = false, auto_confirm_tools = {} }
    )
    local ok2 = tool.implementation.allow_parallel(
      { a = "x", b = "nope" },
      { ignore_tool_confirm = false, auto_confirm_tools = {} }
    )
    eq(true, ok1)
    eq(false, ok2)
  end)
end

T["permissions (nil treated as empty)"]["allow supports multiple persisted rules per tool"] = function()
  with_mock_local_config({
    permission = {
      allow = {
        dummy = {
          { arguments = { foo = { "^foo$" } } },
          { arguments = { foo = { "^bar$" } }, choice = 2 },
        },
      },
    },
  }, function()
    local tool = create_dummy_tool("dummy", true, function(_, _, callback, _)
      callback({ kind = "ok", content = { "ran" } })
    end)

    local foo_choice = tool.implementation.allow_parallel(
      { foo = "foo" },
      { ignore_tool_confirm = false, auto_confirm_tools = {} }
    )
    local bar_choice =
      require("sia.permissions").resolve_permissions("dummy", { foo = "bar" })
    local baz_choice = tool.implementation.allow_parallel(
      { foo = "baz" },
      { ignore_tool_confirm = false, auto_confirm_tools = {} }
    )

    eq(true, foo_choice)
    eq(2, bar_choice.auto_allow)
    eq(false, baz_choice)
  end)
end

T["permissions (nil treated as empty)"]["ask triggers on negative lookahead pattern when not matching 'safe'"] = function()
  with_mock_local_config({
    permission = {
      ask = {
        dummy = { arguments = { action = { "^(safe)@!.*" } } },
      },
    },
  }, function()
    local config = require("sia.config")
    local original_ui_flag = config.options.settings.ui.use_vim_ui
    config.options.settings.ui.use_vim_ui = true

    local prompt_called = false
    local original_vim_ui_input = vim.ui.input
    vim.ui.input = function(opts, cb)
      prompt_called = true
      cb("")
    end

    local tool = create_dummy_tool("dummy", true, function(_, _, callback, opts)
      opts.user_input("Proceed?", {
        must_confirm = false,
        on_accept = function()
          callback({ kind = "ok", content = { "accepted" } })
        end,
      })
    end)

    local result
    tool.implementation.execute({ action = "rm -rf" }, function(res)
      result = res
    end, { conversation = { auto_confirm_tools = { dummy = 1 } } })

    eq(true, prompt_called)
    eq("ok", result.kind)

    prompt_called = false
    tool.implementation.execute({ action = "safe run" }, function(res)
      result = res
    end, { conversation = { auto_confirm_tools = { dummy = 1 } } })
    eq(false, prompt_called)

    vim.ui.input = original_vim_ui_input
    config.options.settings.ui.use_vim_ui = original_ui_flag
  end)
end

T["permissions (nil treated as empty)"]["deny blocks on positive string pattern"] = function()
  with_mock_local_config({
    permission = {
      deny = {
        dummy = { arguments = { cmd = { "^rm" } } },
      },
    },
  }, function()
    local executed = false
    local tool = create_dummy_tool("dummy", true, function(_, _, _, _)
      executed = true
    end)

    local result
    tool.implementation.execute({ cmd = "rm -rf /" }, function(res)
      result = res
    end, { conversation = { auto_confirm_tools = {} } })

    eq(false, executed)
    eq("OPERATION BLOCKED BY LOCAL CONFIGURATION", result.content[1])
  end)
end

T["permissions (nil treated as empty)"]["deny blocks on simple string pattern"] = function()
  with_mock_local_config({
    permission = {
      deny = {
        dummy = { arguments = { value = { "^bad" } } },
      },
    },
  }, function()
    local executed = false
    local tool = create_dummy_tool("dummy", true, function(_, _, _, _)
      executed = true
    end)

    local result
    tool.implementation.execute({ value = "badstuff" }, function(res)
      result = res
    end, { conversation = { auto_confirm_tools = {} } })

    eq(false, executed)
    eq("OPERATION BLOCKED BY LOCAL CONFIGURATION", result.content[1])
  end)
end

T["permissions (nil treated as empty)"]["persist_allow_rule appends tool-specific rules to local config"] = function()
  with_temp_project({}, function(config_path, auto_path)
    local permissions = require("sia.permissions")

    local path = permissions.persist_allow_rule("view", {
      arguments = {
        path = { "^lua/sia/[^/]+\\.lua$" },
      },
    })
    eq(true, path ~= nil)

    local path = permissions.persist_allow_rule("view", {
      arguments = {
        path = { "^tests/[^/]+\\.lua$" },
      },
    })
    eq(true, path ~= nil)

    local path = permissions.persist_allow_rule("view", {
      arguments = {
        path = { "^tests/[^/]+\\.lua$" },
      },
    })
    eq(true, path ~= nil)

    local raw = vim.json.decode(table.concat(vim.fn.readfile(auto_path), ""))
    eq("^lua/sia/[^/]+\\.lua$", raw.permission.allow.view[1].arguments.path[1])
    eq("^tests/[^/]+\\.lua$", raw.permission.allow.view[2].arguments.path[1])

    local view_permission =
      permissions.resolve_permissions("view", { path = "tests/test_permissions.lua" })
    local miss_permission =
      permissions.resolve_permissions("view", { path = "README.md" })
    eq(1, view_permission.auto_allow)
    eq(nil, miss_permission)
  end)
end

T["permissions (nil treated as empty)"]["always persists an opt-in rule before executing"] = function()
  with_temp_project({}, function(config_path, auto_path)
    local config = require("sia.config")
    local original_ui_flag = config.options.settings.ui.use_vim_ui
    local original_vim_ui_input = vim.ui.input
    local executed = false
    local tool = create_dummy_tool("dummy", true, function(args, _, callback, opts)
      opts.user_input("Proceed?", {
        on_accept = function()
          executed = true
          callback({ kind = "ok", content = { args.path } })
        end,
      })
    end, {
      persist_allow = function(args)
        return {
          {
            label = "src/*.lua (read)",
            rule = {
              arguments = {
                path = { "^src/[^/]+\\.lua$" },
                mode = { "^read$" },
              },
              choice = args.choice,
            },
          },
        }
      end,
    })

    config.options.settings.ui.use_vim_ui = true
    vim.ui.input = function(_, on_confirm)
      on_confirm("always")
    end

    local result
    tool.implementation.execute(
      { path = "src/demo.lua", mode = "read", choice = 2 },
      function(res)
        result = res
      end,
      { conversation = { auto_confirm_tools = {} } }
    )

    config.options.settings.ui.use_vim_ui = original_ui_flag
    vim.ui.input = original_vim_ui_input

    eq(true, executed)
    eq("ok", result.kind)

    local raw = vim.json.decode(table.concat(vim.fn.readfile(auto_path), ""))
    eq("^src/[^/]+\\.lua$", raw.permission.allow.dummy.arguments.path[1])
    eq("^read$", raw.permission.allow.dummy.arguments.mode[1])
    eq(2, raw.permission.allow.dummy.choice)
  end)
end

T["permissions (nil treated as empty)"]["async confirm always persists an opt-in rule before executing"] = function()
  with_temp_project({}, function(config_path, auto_path)
    package.loaded["sia.ui.confirm"] = nil

    local config = require("sia.config")
    local original_async = config.options.settings.ui.confirm.async.enable
    local original_notifier = config.options.settings.ui.confirm.async.notifier
    local executed = false
    local tool = create_dummy_tool("dummy", true, function(args, _, callback, opts)
      opts.user_input("Proceed?", {
        on_accept = function()
          executed = true
          callback({ kind = "ok", content = { args.path } })
        end,
      })
    end, {
      persist_allow = function(args)
        return {
          {
            label = "src/*.lua (read)",
            rule = {
              arguments = {
                path = { "^src/[^/]+\\.lua$" },
                mode = { "^read$" },
              },
              choice = args.choice,
            },
          },
        }
      end,
    })

    config.options.settings.ui.confirm.async.enable = true
    config.options.settings.ui.confirm.async.notifier = {
      show = function() end,
      clear = function() end,
    }

    local result
    tool.implementation.execute(
      { path = "src/demo.lua", mode = "read", choice = 2 },
      function(res)
        result = res
      end,
      { conversation = { id = 1, name = "chat", auto_confirm_tools = {} } }
    )

    eq(false, executed)
    require("sia.ui.confirm").always()

    config.options.settings.ui.confirm.async.enable = original_async
    config.options.settings.ui.confirm.async.notifier = original_notifier
    package.loaded["sia.ui.confirm"] = nil

    eq(true, executed)
    eq("ok", result.kind)

    local raw = vim.json.decode(table.concat(vim.fn.readfile(auto_path), ""))
    eq("^src/[^/]+\\.lua$", raw.permission.allow.dummy.arguments.path[1])
    eq("^read$", raw.permission.allow.dummy.arguments.mode[1])
    eq(2, raw.permission.allow.dummy.choice)
  end)
end

T["permissions (nil treated as empty)"]["always with multiple candidates presents vim.ui.select and persists chosen rule"] = function()
  with_temp_project({}, function(config_path, auto_path)
    local config = require("sia.config")
    local original_ui_flag = config.options.settings.ui.use_vim_ui
    local original_vim_ui_input = vim.ui.input
    local original_vim_ui_select = vim.ui.select
    local executed = false
    local select_items = nil
    local tool = create_dummy_tool("dummy", true, function(args, _, callback, opts)
      opts.user_input("Proceed?", {
        on_accept = function()
          executed = true
          callback({ kind = "ok", content = { args.path } })
        end,
      })
    end, {
      persist_allow = function(_)
        return {
          {
            label = "src/demo.lua",
            rule = { arguments = { path = { "^src/demo\\.lua$" } } },
          },
          {
            label = "src/*.lua",
            rule = { arguments = { path = { "^src/[^/]+\\.lua$" } } },
          },
          { label = "**/*.lua", rule = { arguments = { path = { "[^/]+\\.lua$" } } } },
        }
      end,
    })

    config.options.settings.ui.use_vim_ui = true
    vim.ui.input = function(_, on_confirm)
      on_confirm("always")
    end
    vim.ui.select = function(items, _, on_choice)
      select_items = items
      on_choice(items[3])
    end

    local result
    tool.implementation.execute({ path = "src/demo.lua" }, function(res)
      result = res
    end, { conversation = { auto_confirm_tools = {} } })

    config.options.settings.ui.use_vim_ui = original_ui_flag
    vim.ui.input = original_vim_ui_input
    vim.ui.select = original_vim_ui_select

    eq(true, executed)
    eq("ok", result.kind)
    eq(4, #select_items)
    eq("src/demo.lua", select_items[2].label)
    eq("src/*.lua", select_items[3].label)
    eq("**/*.lua", select_items[4].label)

    local raw = vim.json.decode(table.concat(vim.fn.readfile(auto_path), ""))
    eq("^src/[^/]+\\.lua$", raw.permission.allow.dummy.arguments.path[1])
  end)
end

T["permissions (nil treated as empty)"]["always with multiple candidates falls back to session when cancelled"] = function()
  with_temp_project({}, function(config_path, auto_path)
    local config = require("sia.config")
    local original_ui_flag = config.options.settings.ui.use_vim_ui
    local original_vim_ui_input = vim.ui.input
    local original_vim_ui_select = vim.ui.select
    local executed = false
    local conversation = { auto_confirm_tools = {} }
    local tool = create_dummy_tool("dummy", true, function(args, _, callback, opts)
      opts.user_input("Proceed?", {
        on_accept = function()
          executed = true
          callback({ kind = "ok", content = { args.path } })
        end,
      })
    end, {
      persist_allow = function(_)
        return {
          {
            label = "src/demo.lua",
            rule = { arguments = { path = { "^src/demo\\.lua$" } } },
          },
          {
            label = "src/*.lua",
            rule = { arguments = { path = { "^src/[^/]+\\.lua$" } } },
          },
        }
      end,
    })

    config.options.settings.ui.use_vim_ui = true
    vim.ui.input = function(_, on_confirm)
      on_confirm("always")
    end
    vim.ui.select = function(_, _, on_choice)
      on_choice(nil)
    end

    local result
    tool.implementation.execute({ path = "src/demo.lua" }, function(res)
      result = res
    end, { conversation = conversation })

    config.options.settings.ui.use_vim_ui = original_ui_flag
    vim.ui.input = original_vim_ui_input
    vim.ui.select = original_vim_ui_select

    eq(true, executed)
    eq("ok", result.kind)
    eq(1, conversation.auto_confirm_tools["dummy"])

    -- auto.json should not have been created since select was cancelled
    eq(0, vim.fn.filereadable(auto_path))
    -- config.json should remain untouched
    local raw = vim.json.decode(table.concat(vim.fn.readfile(config_path), ""))
    eq(nil, raw.permission)
  end)
end

T["permissions (nil treated as empty)"]["path_allow_candidates returns cascade of exact, dir, and global patterns"] = function()
  local utils = require("sia.tools.utils")

  local candidates = utils.path_allow_candidates("lua/sia/config.lua")
  eq(3, #candidates)
  eq("lua/sia/config.lua", candidates[1].label)
  eq("lua/sia/*.lua", candidates[2].label)
  eq("**/*.lua", candidates[3].label)
  eq("^lua/sia/config\\.lua$", candidates[1].pattern)
  eq("^lua/sia/[^/]+\\.lua$", candidates[2].pattern)
  eq("[^/]+\\.lua$", candidates[3].pattern)
end

T["permissions (nil treated as empty)"]["path_allow_candidates for root file skips dir-level pattern"] = function()
  local utils = require("sia.tools.utils")

  local candidates = utils.path_allow_candidates("README.md")
  eq(2, #candidates)
  eq("README.md", candidates[1].label)
  eq("**/*.md", candidates[2].label)
end

T["permissions (nil treated as empty)"]["path_allow_candidates for extensionless file returns only exact match"] = function()
  local utils = require("sia.tools.utils")

  local candidates = utils.path_allow_candidates("Makefile")
  eq(1, #candidates)
  eq("Makefile", candidates[1].label)
  eq("^Makefile$", candidates[1].pattern)
end

T["permissions (nil treated as empty)"]["path_allow_candidates for dotfile returns only exact match"] = function()
  local utils = require("sia.tools.utils")

  local candidates = utils.path_allow_candidates("src/.gitignore")
  eq(1, #candidates)
  eq("src/.gitignore", candidates[1].label)
  eq("^src/\\.gitignore$", candidates[1].pattern)
end

return T
