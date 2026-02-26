local M = {}

local split = require("sia.ui.split")

local panel = split.new("todos")

--- Open/close/toggle the todos panel for the current chat.
--- @param action? "open"|"close"|"toggle"
function M.toggle(action)
  action = action or "toggle"

  local chat = require("sia.strategy").ChatStrategy.by_buf()
  if not chat then
    return
  end

  if action == "close" then
    panel:close(chat.buf)
    return
  end

  if action == "toggle" and panel:is_open(chat.buf) then
    panel:close(chat.buf)
    return
  end

  local todos_buf = chat.conversation.todos and chat.conversation.todos.buf
  if not todos_buf or not vim.api.nvim_buf_is_valid(todos_buf) then
    if not chat.conversation.todos or #chat.conversation.todos.items == 0 then
      return
    end
    return
  end

  panel:open(chat.buf, todos_buf)
end

return M
