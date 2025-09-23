local utils = require("sia.tools.utils")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["permissions (nil treated as empty)"] = MiniTest.new_set()

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

local function create_dummy_tool(name, read_only, runner)
  return utils.new_tool({
    name = name,
    description = "dummy",
    read_only = read_only,
    required = {},
    parameters = {},
  }, function(args, conversation, callback, opts)
    runner(args, conversation, callback, opts)
  end)
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
    tool.execute({}, { auto_confirm_tools = {} }, function(res)
      result = res
    end)

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
    tool.execute({ foo = false }, { auto_confirm_tools = {} }, function(res)
      result = res
    end)

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

    local can_parallel = tool.allow_parallel({ ignore_tool_confirm = false, auto_confirm_tools = {} }, {})
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
    local original_ui_flag = config.options.defaults.ui.use_vim_ui
    config.options.defaults.ui.use_vim_ui = true

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
    tool.execute({}, { auto_confirm_tools = { dummy = 1 } }, function(res)
      result = res
    end)

    eq(true, prompt_called)
    eq("ok", result.kind)

    vim.ui.input = original_vim_ui_input
    config.options.defaults.ui.use_vim_ui = original_ui_flag
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

    local ok1 = tool.allow_parallel({ ignore_tool_confirm = false, auto_confirm_tools = {} }, { foo = "foo" })
    local ok2 = tool.allow_parallel({ ignore_tool_confirm = false, auto_confirm_tools = {} }, { foo = "bar" })
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

    local ok1 = tool.allow_parallel({ ignore_tool_confirm = false, auto_confirm_tools = {} }, { n = 123 })
    local ok2 = tool.allow_parallel({ ignore_tool_confirm = false, auto_confirm_tools = {} }, { n = "abc" })
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

    local ok1 = tool.allow_parallel({ ignore_tool_confirm = false, auto_confirm_tools = {} }, { a = "x", b = "y" })
    local ok2 = tool.allow_parallel({ ignore_tool_confirm = false, auto_confirm_tools = {} }, { a = "x", b = "nope" })
    eq(true, ok1)
    eq(false, ok2)
  end)
end

T["permissions (nil treated as empty)"]["ask triggers on negate pattern when not matching 'safe'"] = function()
  with_mock_local_config({
    permission = {
      ask = {
        dummy = { arguments = { action = { { pattern = "^safe", negate = true } } } },
      },
    },
  }, function()
    local config = require("sia.config")
    local original_ui_flag = config.options.defaults.ui.use_vim_ui
    config.options.defaults.ui.use_vim_ui = true

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
    tool.execute({ action = "rm -rf" }, { auto_confirm_tools = { dummy = 1 } }, function(res)
      result = res
    end)

    eq(true, prompt_called)
    eq("ok", result.kind)

    -- now with a matching 'safe' value, the negate pattern should NOT trigger ask
    prompt_called = false
    tool.execute({ action = "safe run" }, { auto_confirm_tools = { dummy = 1 } }, function(res)
      result = res
    end)
    eq(false, prompt_called)

    vim.ui.input = original_vim_ui_input
    config.options.defaults.ui.use_vim_ui = original_ui_flag
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
    tool.execute({ cmd = "rm -rf /" }, { auto_confirm_tools = {} }, function(res)
      result = res
    end)

    eq(false, executed)
    eq("OPERATION BLOCKED BY LOCAL CONFIGURATION", result.content[1])
  end)
end

T["permissions (nil treated as empty)"]["deny blocks on object pattern (negate=false)"] = function()
  with_mock_local_config({
    permission = {
      deny = {
        dummy = { arguments = { value = { { pattern = "^bad", negate = false } } } },
      },
    },
  }, function()
    local executed = false
    local tool = create_dummy_tool("dummy", true, function(_, _, _, _)
      executed = true
    end)

    local result
    tool.execute({ value = "badstuff" }, { auto_confirm_tools = {} }, function(res)
      result = res
    end)

    eq(false, executed)
    eq("OPERATION BLOCKED BY LOCAL CONFIGURATION", result.content[1])
  end)
end

return T
