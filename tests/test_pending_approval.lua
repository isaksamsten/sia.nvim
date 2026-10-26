local child = MiniTest.new_child_neovim()
local eq = MiniTest.expect.equality
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "assets/minimal.lua", "-i", "NONE", "-n" })
      child.lua([[
      local config = require("sia.config")
      _G.permission = {}
      config.get_local_config = function() return { permission = permission } end
      config.options.settings.tool_verifier = { enable = false }
      config.options.settings.ui.confirm.async.enable = true
      config.options.settings.ui.confirm.use_vim_ui = true
      config.options.settings.ui.confirm.show_preview = false
      config.options.settings.ui.confirm.async.notifier = {
        show = function() end, clear = function() end,
      }
      _G.confirm = require("sia.ui.confirm")
      _G.conversation = { id = 1, name = "chat", approved_tools = {} }
      _G.other = { id = 2, name = "other", approved_tools = {} }
      _G.accepted, _G.events = {}, {}
      _G.start = function(path, opts)
        opts = opts or {}
        local tool = require("sia.tools.utils").new_tool({
          definition = { name = opts.name or "test_pending" },
          read_only = true,
          persist_allow = opts.persist_allow,
        }, function(args, _, callback, runtime)
          runtime.user_input("Read " .. args.path, {
            level = opts.level or "info",
            on_accept = function()
              table.insert(accepted, args.path)
              callback({ content = { "ok" } })
            end,
          })
        end)
        tool.implementation.execute({ path = path }, function() end, {
          conversation = opts.conversation or conversation,
          on_confirmation = function(waiting)
            events[path] = events[path] or {}
            table.insert(events[path], waiting)
          end,
        })
      end
    ]])
    end,
    post_case = function()
      child.stop()
    end,
  },
})

T["always releases queued requests and clears their waiting state"] = function()
  child.lua([[
    start("a"); start("b"); start("c")
    confirm.always({ first = true })
    table.sort(accepted)
  ]])
  eq({ "a", "b", "c" }, child.lua_get("accepted"))
  eq(0, child.lua_get("confirm.count()"))
  eq({ true, false }, child.lua_get("events.b"))
  eq({ true, false }, child.lua_get("events.c"))
end

T["approval leaves other conversations tools explicit asks and warnings pending"] = function()
  child.lua([[
    permission.ask = {
      test_pending = { arguments = { path = { vim.regex("^ask$") } } },
    }
    start("a")
    start("b")
    start("other conversation", { conversation = other })
    start("other tool", { name = "another_tool" })
    start("ask")
    start("warning", { level = "warn" })
    confirm.always({ first = true })
    table.sort(accepted)
  ]])
  eq({ "a", "b" }, child.lua_get("accepted"))
  eq(4, child.lua_get("confirm.count()"))
end

T["persisted approval only releases requests matching the selected scope"] = function()
  child.lua([[
    local permissions = require("sia.permissions")
    permissions.persist_allow_rule = function(name, rule)
      local compiled = vim.deepcopy(rule)
      for key, patterns in pairs(compiled.arguments) do
        for i, pattern in ipairs(patterns) do
          patterns[i] = vim.regex(pattern)
        end
      end
      permission.allow = { [name] = compiled }
    end
    vim.ui.select = function(items, _, callback)
      _G.choose_scope = function() callback(items[2]) end
    end
    local opts = { persist_allow = function()
      return {
        { label = "Lua files", rule = { arguments = { path = { "\\.lua$" } } } },
        { label = "All files", rule = { arguments = { path = { ".*" } } } },
      }
    end }
    start("a.lua", opts)
    start("b.lua", opts)
    start("c.txt", opts)
    confirm.always({ first = true })
  ]])
  eq({}, child.lua_get("accepted"))
  eq(2, child.lua_get("confirm.count()"))
  child.lua("choose_scope(); table.sort(accepted)")
  eq({ "a.lua", "b.lua" }, child.lua_get("accepted"))
  eq(1, child.lua_get("confirm.count()"))
end

T["always chosen in the prompt also releases queued requests"] = function()
  child.lua([[
    vim.ui.input = function(_, callback) _G.answer = callback end
    start("a"); start("b")
    confirm.prompt({ first = true })
    answer("always")
    table.sort(accepted)
  ]])
  eq({ "a", "b" }, child.lua_get("accepted"))
  eq(0, child.lua_get("confirm.count()"))
end

T["group always tolerates requests removed by rechecking"] = function()
  child.lua([[
    start("a"); start("b"); start("c")
    confirm.always()
    table.sort(accepted)
  ]])
  eq({ "a", "b", "c" }, child.lua_get("accepted"))
  eq(0, child.lua_get("confirm.count()"))
end

T["recheck honors deny rules and mode restrictions added while waiting"] = function()
  child.lua([[
    start("a"); start("denied"); start("restricted", { name = "mode_tool" })
    permission.deny = {
      test_pending = { arguments = { path = { vim.regex("^denied$") } } },
    }
    conversation.active_mode = require("sia.permissions").create_active_mode("test", {
      permissions = { deny = { "mode_tool" } },
    })
    confirm.always({ first = true })
  ]])
  eq({ "a" }, child.lua_get("accepted"))
  eq(2, child.lua_get("confirm.count()"))
end

return T
