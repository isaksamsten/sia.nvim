local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["winbar"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      package.loaded["sia.ui.winbar"] = nil
    end,
  },
})

T["winbar"]["clear_status preserves newer statuses"] = function()
  local winbar = require("sia.ui.winbar")
  local Conversation = require("sia.conversation")
  local conversation = Conversation.new({ temporary = true })
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_get_current_win()

  vim.api.nvim_win_set_buf(win, buf)
  winbar.attach(buf, conversation, {
    is_busy = false,
    next_mode = nil,
  })

  winbar.update_status(buf, { message = "Compacting", status = "info" })
  winbar.clear_status(buf, 10)
  winbar.update_status(buf, { message = "Still running", status = "warning" })

  vim.wait(100, function()
    return vim.wo[win].winbar:find("Still running", 1, true) ~= nil
  end, 10)

  eq(true, vim.wo[win].winbar:find("Still running", 1, true) ~= nil)

  winbar.detach(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["winbar"]["default_left shows pending user message count from conversation"] = function()
  local winbar = require("sia.ui.winbar")
  local Conversation = require("sia.conversation")
  local conversation = Conversation.new({ temporary = true })

  conversation:add_pending_user_message("Queued follow-up")
  conversation:add_pending_user_message("Another queued follow-up")

  local rendered = winbar.default_left({
    conversation = conversation,
    strategy = {
      is_busy = false,
      next_mode = nil,
    },
    total_usage = 0,
  })

  eq(true, rendered:find(" 2", 1, true) ~= nil)
end

T["winbar"]["running agent shows name without progress"] = function()
  local rendered = require("sia.ui.winbar").default_left({
    conversation = {
      id = 1,
      has_tool = function(_, name) return name == "agent" end,
      pending_user_message_count = function() return 0 end,
      agent_runtime = {
        list = function()
          return { { name = "code/review", status = "running", progress = "Reading files" } }
        end,
      },
    },
    strategy = { is_busy = false },
  })
  eq(rendered:find("code/review", 1, true) ~= nil, true)
  eq(rendered:find("Reading files", 1, true), nil)
end

T["winbar"]["default_left shows active and pending modes but hides default"] = function()
  local conversation = require("sia.conversation").new({ temporary = true })
  local strategy = { is_busy = false }
  local data = { conversation = conversation, strategy = strategy, total_usage = 0 }
  local winbar = require("sia.ui.winbar")
  local baseline = winbar.default_left(data)
  conversation.active_mode = { name = "plan" }
  strategy.next_mode = { mode = "code" }
  local rendered = winbar.default_left(data)
  eq(true, rendered:find("@plan", 1, true) ~= nil)
  eq(true, rendered:find("→ @code", 1, true) ~= nil)
  conversation.active_mode = { name = "default" }
  strategy.next_mode = nil
  eq(baseline, winbar.default_left(data))
end

return T
