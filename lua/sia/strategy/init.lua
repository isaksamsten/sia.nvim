local M = {
  HiddenStrategy = require("sia.strategy.hidden"),
  ChatStrategy = require("sia.strategy.chat"),
  DiffStrategy = require("sia.strategy.diff"),
  InsertStrategy = require("sia.strategy.insert"),
}

M.get_chat = M.ChatStrategy.by_buf
M.last_chat = M.ChatStrategy.last
M.remove_chat = M.ChatStrategy.remove

M.new_chat = M.ChatStrategy.new
M.new_hidden = M.HiddenStrategy.new
M.new_diff = M.DiffStrategy.new
M.new_insert = M.InsertStrategy.new

return M
