local child = MiniTest.new_child_neovim()
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "assets/minimal.lua" })
      child.lua([[
        _G.root = vim.fn.tempname()
        vim.fn.mkdir(_G.root .. "/.sia/agents", "p")
        vim.fn.chdir(_G.root)
        vim.fn.writefile({
          "---", "description: Project chat", "tools:", "  - view!", "  - grep",
          "model: coding", "requires:", "  - image", "---",
          "Work in {{workspace}}.",
        }, _G.root .. "/.sia/agents/project.md")
      ]])
    end,
    post_case = function()
      child.lua([[vim.fn.delete(_G.root, "rf")]])
      child.stop()
    end,
  },
})
local eq = MiniTest.expect.equality

T["chat selects an existing agent without changing the default action"] = function()
  child.lua([[
    vim.fn.writefile({ '{"action":{"chat":"project"}}' }, _G.root .. "/.sia/config.json")
    local config = require("sia.config")
    local original = config.options.settings.actions.chat
    _G.system = original.system
    _G.model = original.model
    _G.requires = original.requires
    local tools, approved = original.tools({})
    _G.tools = vim.tbl_map(function(t) return t.definition.name end, tools)
    _G.approved = approved
    _G.preserves_user = original.user == nil or #original.user == #config._raw_options.settings.actions.chat.user
    _G.default_unchanged = config._raw_options.settings.actions.chat.system ~= original.system
    _G.mode = original.mode
  ]])
  eq({ "Work in {{workspace}}." }, child.lua_get("_G.system"))
  eq("coding", child.lua_get("_G.model"))
  eq({ "image" }, child.lua_get("_G.requires"))
  eq({ "view", "grep" }, child.lua_get("_G.tools"))
  eq({ view = true }, child.lua_get("_G.approved"))
  eq(true, child.lua_get("_G.default_unchanged"))
  eq(true, child.lua_get("_G.preserves_user"))
  eq("chat", child.lua_get("_G.mode"))
end

T["invalid names and types fail local config validation"] = function()
  child.lua([[
    local config = require("sia.config")
    _G.results = {}
    local notify = vim.notify
    vim.notify = function() end
    for _, value in ipairs({ "missing", false, {}, "" }) do
      vim.fn.writefile({ vim.json.encode({ action = { chat = value } }) }, _G.root .. "/.sia/config.json")
      require("sia.config.local").invalidate_local_config()
      table.insert(_G.results, config.get_local_config() == nil)
    end
    vim.notify = notify
  ]])
  eq({ true, true, true, true }, child.lua_get("_G.results"))
end

T["no chat override preserves existing defaults"] = function()
  child.lua([[
    vim.fn.writefile({ '{}' }, _G.root .. "/.sia/config.json")
    local config = require("sia.config")
    _G.unchanged = config.options.settings.actions.chat == config._raw_options.settings.actions.chat
  ]])
  eq(true, child.lua_get("_G.unchanged"))
end

T["action.chat still selects a globally configured Lua action"] = function()
  child.lua([[
    vim.fn.writefile({ '{"action":{"chat":"custom"}}' }, _G.root .. "/.sia/config.json")
    local config = require("sia.config")
    config.options.actions.custom = { mode = "chat", system = { "Custom" } }
    _G.system = config.options.settings.actions.chat.system
  ]])
  eq({ "Custom" }, child.lua_get("_G.system"))
end

T["agent definitions replace Lua actions with the same name"] = function()
  child.lua([[
    vim.fn.writefile({ '{"action":{"chat":"project"}}' }, _G.root .. "/.sia/config.json")
    local config = require("sia.config")
    config.options.actions.project = { mode = "chat", system = { "Lua" } }
    _G.system = config.options.settings.actions.chat.system
  ]])
  eq({ "Work in {{workspace}}." }, child.lua_get("_G.system"))
end

T["invalid agent definitions do not fall back to Lua actions"] = function()
  child.lua([[
    vim.fn.writefile({ "Invalid" }, _G.root .. "/.sia/agents/project.md")
    vim.fn.writefile({ '{"action":{"chat":"project"}}' }, _G.root .. "/.sia/config.json")
    local config = require("sia.config")
    config.options.actions.project = { mode = "chat", system = { "Lua" } }
    local notify = vim.notify
    vim.notify = function() end
    _G.invalid = config.get_local_config() == nil
    vim.notify = notify
    _G.error = require("sia.agent.registry").errors().project ~= nil
  ]])
  eq(true, child.lua_get("_G.invalid"))
  eq(true, child.lua_get("_G.error"))
end

T["SiaConfig saves, inspects and removes the generated chat selection"] = function()
  child.lua([[
    local command = require("sia.config.command")
    local messages = {}
    local notify = vim.notify
    vim.notify = function(message) messages[#messages + 1] = message end
    command.run({ args = "action.chat project", bang = false })
    local config = require("sia.config")
    _G.selection = config.get_local_config().action.chat
    _G.system = config.options.settings.actions.chat.system
    command.run({ args = "action.chat", bang = false })
    _G.inspection = messages[#messages]
    command.run({ args = "action.chat missing", bang = false })
    _G.after_invalid = config.get_local_config().action.chat
    command.run({ args = "action.chat", bang = true })
    _G.removed = config.get_local_config().action == nil
    vim.notify = notify
  ]])
  eq("project", child.lua_get("_G.selection"))
  eq({ "Work in {{workspace}}." }, child.lua_get("_G.system"))
  eq('action.chat = "project"', child.lua_get("_G.inspection"))
  eq("project", child.lua_get("_G.after_invalid"))
  eq(true, child.lua_get("_G.removed"))
end

return T

