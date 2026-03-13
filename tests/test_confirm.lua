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

T["sia.ui.confirm"] = MiniTest.new_set()

T["sia.ui.confirm"]["notifier shows the next approval and remaining count"] = function()
  child.lua([[
    package.loaded["sia.ui.confirm"] = nil
    local config = require("sia.config")
    local seen = {}
    config.options.settings.ui.confirm.async.enable = true
    config.options.settings.ui.confirm.async.notifier = {
      show = function(args)
        table.insert(seen, vim.deepcopy(args))
      end,
      clear = function()
        table.insert(seen, { cleared = true })
      end,
    }

    local confirm = require("sia.ui.confirm")
    local conversation = { id = 1, name = "chat" }

    confirm.show(conversation, "View a.lua", {
      level = "info",
      tool_name = "view",
      kind = "input",
      on_accept = function() end,
      on_cancel = function() end,
      on_prompt = function() end,
    })

    confirm.show(conversation, "View b.lua", {
      level = "info",
      tool_name = "view",
      kind = "input",
      on_accept = function() end,
      on_cancel = function() end,
      on_prompt = function() end,
    })

    _G.confirm_seen = seen
    _G.confirm_count = confirm.count()
  ]])

  local seen = child.lua_get("_G.confirm_seen")
  local count = child.lua_get("_G.confirm_count")
  local last = seen[#seen]

  eq(2, count)
  eq("chat", last.name)
  eq("View a.lua", last.message)
  eq(2, last.total)
  eq(1, last.groups)
end

T["sia.ui.confirm"]["accept processes every request in a batchable group"] = function()
  child.lua([[
    package.loaded["sia.ui.confirm"] = nil
    local config = require("sia.config")
    config.options.settings.ui.confirm.async.enable = true
    config.options.settings.ui.confirm.async.notifier = {
      show = function() end,
      clear = function() end,
    }

    local confirm = require("sia.ui.confirm")
    local conversation = { id = 7, name = "chat" }
    local accepted = 0

    local function request(prompt)
      confirm.show(conversation, prompt, {
        level = "info",
        tool_name = "view",
        kind = "input",
        on_accept = function()
          accepted = accepted + 1
        end,
        on_cancel = function() end,
        on_prompt = function() end,
      })
    end

    request("View a.lua")
    request("View b.lua")
    confirm.accept()

    _G.accepted = accepted
    _G.remaining = confirm.count()
  ]])

  eq(2, child.lua_get("_G.accepted"))
  eq(0, child.lua_get("_G.remaining"))
end

T["sia.ui.confirm"]["expand opens a top window with horizontal groups and hints"] = function()
  child.lua([[
    package.loaded["sia.ui.confirm"] = nil
    local config = require("sia.config")
    config.options.settings.ui.confirm.async.enable = true
    config.options.settings.ui.confirm.async.notifier = {
      show = function() end,
      clear = function() end,
    }

    local confirm = require("sia.ui.confirm")
    local conversation = { id = 11, name = "chat" }
    local agent = { id = 12, name = "review-agent" }

    confirm.show(conversation, "View a.lua", {
      level = "info",
      tool_name = "view",
      kind = "input",
      on_accept = function() end,
      on_cancel = function() end,
      on_prompt = function() end,
    })
    confirm.show(conversation, "View b.lua", {
      level = "info",
      tool_name = "view",
      kind = "input",
      on_accept = function() end,
      on_cancel = function() end,
      on_prompt = function() end,
    })
    confirm.show(agent, "Run git status", {
      level = "warn",
      tool_name = "bash",
      kind = "input",
      on_accept = function() end,
      on_cancel = function() end,
      on_prompt = function() end,
    })

    confirm.expand()

    local detail_lines = nil
    local detail_config = nil
    local detail_highlight = nil
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local cfg = vim.api.nvim_win_get_config(win)
      if cfg.relative == "editor" and cfg.focusable then
        detail_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
        detail_config = cfg
        detail_highlight = vim.wo[win].winhighlight
        break
      end
    end

    _G.detail_lines = detail_lines
    _G.detail_row = detail_config.row
    _G.detail_col = detail_config.col
    _G.detail_highlight = detail_highlight
  ]])

  local lines = child.lua_get("_G.detail_lines")
  eq(true, lines[1]:match("%[chat%].+%[review%-agent%]") ~= nil)
  eq(true, lines[2]:match("%[view %(2%)%].+%[bash%]") ~= nil)
  eq("> 1. View a.lua", lines[3])
  eq("  2. View b.lua", lines[4])
  eq(0, child.lua_get("_G.detail_row"))
  eq(0, child.lua_get("_G.detail_col"))
  eq("SiaConfirm:SiaConfirm", child.lua_get("_G.detail_highlight"))
end

T["sia.ui.confirm"]["expanded UI shows mappings in cursor-relative floating help"] = function()
  child.lua([[
    package.loaded["sia.ui.confirm"] = nil
    local config = require("sia.config")
    config.options.settings.ui.confirm.async.enable = true
    config.options.settings.ui.confirm.async.notifier = {
      show = function() end,
      clear = function() end,
    }

    local confirm = require("sia.ui.confirm")
    local conversation = { id = 41, name = "chat" }

    confirm.show(conversation, "View a.lua", {
      level = "info",
      tool_name = "view",
      kind = "input",
      on_accept = function() end,
      on_cancel = function() end,
      on_prompt = function() end,
    })

    confirm.expand()
    vim.api.nvim_feedkeys("g?", "xt", false)
    vim.wait(50)

    local help_lines = nil
    local help_config = nil
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local cfg = vim.api.nvim_win_get_config(win)
      if cfg.relative == "cursor" then
        help_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
        help_config = cfg
        break
      end
    end

    _G.help_lines = help_lines
    _G.help_relative = help_config and help_config.relative or nil
    _G.help_row = help_config and help_config.row or nil
    _G.help_col = help_config and help_config.col or nil
  ]])

  eq("Confirm mappings", child.lua_get("_G.help_lines")[1])
  eq("h/l   move between groups", child.lua_get("_G.help_lines")[3])
  eq("q     close approvals", child.lua_get("_G.help_lines")[10])
  eq("cursor", child.lua_get("_G.help_relative"))
  eq(1, child.lua_get("_G.help_row")[false])
  eq(2, child.lua_get("_G.help_col")[false])
end

T["sia.ui.confirm"]["expand clusters multiple tool groups under one conversation header"] = function()
  child.lua([[
    package.loaded["sia.ui.confirm"] = nil
    local config = require("sia.config")
    config.options.settings.ui.confirm.async.enable = true
    config.options.settings.ui.confirm.async.notifier = {
      show = function() end,
      clear = function() end,
    }

    local confirm = require("sia.ui.confirm")
    local chat = { id = 31, name = "chat" }
    local agent = { id = 32, name = "review-agent" }

    confirm.show(chat, "View a.lua", {
      level = "info",
      tool_name = "view",
      kind = "input",
      on_accept = function() end,
      on_cancel = function() end,
      on_prompt = function() end,
    })
    confirm.show(agent, "Run git status", {
      level = "warn",
      tool_name = "bash",
      kind = "input",
      on_accept = function() end,
      on_cancel = function() end,
      on_prompt = function() end,
    })
    confirm.show(chat, "Search TODO", {
      level = "info",
      tool_name = "grep",
      kind = "input",
      on_accept = function() end,
      on_cancel = function() end,
      on_prompt = function() end,
    })

    confirm.expand()

    local detail_lines = nil
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local cfg = vim.api.nvim_win_get_config(win)
      if cfg.relative == "editor" and cfg.focusable then
        detail_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
        break
      end
    end

    _G.clustered_lines = detail_lines
  ]])

  local lines = child.lua_get("_G.clustered_lines")
  eq(true, lines[1]:match("%[chat%].+%[review%-agent%]") ~= nil)
  eq(true, lines[2]:match("%[view%] %[%a+%].+%[bash%]") ~= nil)
end

T["sia.ui.confirm"]["expanded UI keybindings navigate groups and accept selected group"] = function()
  child.lua([[
    package.loaded["sia.ui.confirm"] = nil
    local config = require("sia.config")
    config.options.settings.ui.confirm.async.enable = true
    config.options.settings.ui.confirm.async.notifier = {
      show = function() end,
      clear = function() end,
    }

    local confirm = require("sia.ui.confirm")
    local conversation = { id = 21, name = "chat" }
    local agent = { id = 22, name = "review-agent" }
    local accepted = 0

    local function add_request(conv, prompt, tool)
      confirm.show(conv, prompt, {
        level = tool == "bash" and "warn" or "info",
        tool_name = tool,
        kind = "input",
        on_accept = function()
          accepted = accepted + 1
        end,
        on_cancel = function() end,
        on_prompt = function() end,
      })
    end

    add_request(conversation, "View a.lua", "view")
    add_request(conversation, "View b.lua", "view")
    add_request(agent, "Run git status", "bash")

    confirm.expand()
    vim.api.nvim_feedkeys("l", "xt", false)
    vim.wait(50)
    vim.api.nvim_feedkeys("A", "xt", false)
    vim.wait(50)

    local detail_lines = nil
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local cfg = vim.api.nvim_win_get_config(win)
      if cfg.relative == "editor" and cfg.focusable then
        detail_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
        break
      end
    end

    _G.accepted = accepted
    _G.remaining = confirm.count()
    _G.detail_lines_after = detail_lines
  ]])

  eq(1, child.lua_get("_G.accepted"))
  eq(2, child.lua_get("_G.remaining"))
  eq(true, child.lua_get("_G.detail_lines_after")[1]:match("%[chat%]") ~= nil)
  eq("[view (2)]", child.lua_get("_G.detail_lines_after")[2])
end

return T

