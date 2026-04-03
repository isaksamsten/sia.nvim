local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["winbar"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      package.loaded["sia.ui.winbar"] = nil
    end,
  },
})

T["winbar"]["counts queued mode changes even without queued user text"] = function()
  local winbar = require("sia.ui.winbar")
  local Conversation = require("sia.conversation")
  local conversation = Conversation.new_conversation({ temporary = true })

  local left = winbar.default_left({
    conversation = conversation,
    strategy = {
      is_busy = false,
      user_queue = {},
      next_mode = { mode = "diff" },
    },
  })

  eq(true, left:find(" 1", 1, true) ~= nil)
end

T["winbar"]["clear_status preserves newer statuses"] = function()
  local winbar = require("sia.ui.winbar")
  local Conversation = require("sia.conversation")
  local conversation = Conversation.new_conversation({ temporary = true })
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_get_current_win()

  vim.api.nvim_win_set_buf(win, buf)
  winbar.attach(buf, conversation, {
    is_busy = false,
    user_queue = {},
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

return T
