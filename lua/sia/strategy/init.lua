local M = {
  HiddenStrategy = require("sia.strategy.hidden"),
  ChatStrategy = require("sia.strategy.chat"),
  DiffStrategy = require("sia.strategy.diff"),
  InsertStrategy = require("sia.strategy.insert"),
}

M.get_chat = M.ChatStrategy.by_buf
M.close_chat = M.ChatStrategy.remove
M.last_chat = M.ChatStrategy.last
M.remove_chat = M.ChatStrategy.remove

M.new_chat = M.ChatStrategy.new
M.new_hidden = M.HiddenStrategy.new
M.new_diff = M.DiffStrategy.new
M.new_insert = M.InsertStrategy.new

--- @param action sia.config.Action
--- @param invocation sia.Invocation
--- @param conversation sia.Conversation
--- @return sia.Strategy
function M.from_action(action, invocation, conversation)
  local config = require("sia.config")
  if action.mode == "diff" then
    local options = vim.tbl_deep_extend(
      "force",
      config.options.settings.diff or {},
      action.diff or {}
    )
    return M.new_diff(
      invocation.buf,
      invocation.win,
      invocation.pos,
      conversation,
      options
    )
  elseif action.mode == "insert" then
    local options = vim.tbl_deep_extend(
      "force",
      config.options.settings.insert or {},
      action.insert or {}
    )
    return M.new_insert(
      invocation.buf,
      invocation.pos,
      invocation.cursor,
      conversation,
      options
    )
  elseif action.mode == "hidden" then
    local options = vim.tbl_deep_extend(
      "force",
      config.options.settings.hidden or {},
      action.hidden or {}
    )
    if not options.callback then
      error("callback is required")
    end
    return M.new_hidden(invocation.buf, conversation, options)
  else
    local options = vim.tbl_deep_extend(
      "force",
      config.options.settings.chat or {},
      action.chat or {}
    )
    return M.new_chat(conversation, options)
  end
end

return M
