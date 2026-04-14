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

T["sia.tools.ask_user"] = MiniTest.new_set()

T["sia.tools.ask_user"]["async confirm preview shows prompt and options"] = function()
  child.lua([[
    package.loaded["sia.ui.confirm"] = nil

    local config = require("sia.config")
    local original_async = config.options.settings.ui.confirm.async.enable
    local original_notifier = config.options.settings.ui.confirm.async.notifier

    config.options.settings.ui.confirm.async.enable = true
    config.options.settings.ui.confirm.async.notifier = {
      show = function() end,
      clear = function() end,
    }

    local captured_preview = nil
    local captured_opts = nil
    local original_preview = package.loaded["sia.preview"] or require("sia.preview")
    package.loaded["sia.preview"] = {
      show = function(content, opts)
        captured_preview = content
        captured_opts = opts
        return function() end
      end,
      clear = function() end,
    }

    local ask_user_tool = require("sia.tools.ask_user")
    local result = nil
    ask_user_tool.implementation.execute({
      prompt = "Choose the next step",
      options = {
        "Run tests",
        "Update docs",
      },
      default = 2,
    }, function(res)
      result = res
    end, {
      conversation = {
        id = 1,
        name = "chat",
        approved_tools = {},
      },
    })

    require("sia.ui.confirm").preview()
    require("sia.ui.confirm").decline()

    config.options.settings.ui.confirm.async.enable = original_async
    config.options.settings.ui.confirm.async.notifier = original_notifier
    package.loaded["sia.preview"] = original_preview
    package.loaded["sia.ui.confirm"] = nil

    _G.result = result
    _G.captured_preview = captured_preview
    _G.captured_opts = captured_opts
  ]])

  local result = child.lua_get("_G.result")
  local captured_preview = child.lua_get("_G.captured_preview")
  local captured_opts = child.lua_get("_G.captured_opts")

  eq(true, result.content:find("OPERATION DECLINED BY USER", 1, true) ~= nil)
  eq("Choose the next step", captured_preview[1])
  eq("Options:", captured_preview[3])
  eq("1. Run tests", captured_preview[4])
  eq("2. Update docs (default)", captured_preview[5])
  eq("3. Do something else (type your answer)", captured_preview[6])
  eq(true, captured_opts.focusable)
  eq(true, captured_opts.wrap)
end

return T
