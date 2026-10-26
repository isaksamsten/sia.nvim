local common = require("sia.strategy.common")

local StreamRenderer = common.StreamRenderer
local Strategy = require("sia.strategy.inline")
local Canvas = require("sia.canvas").Canvas

local DIFF_NS = vim.api.nvim_create_namespace("SiaDiffStrategy")

--- @class sia.DiffStrategy : sia.InlineStrategy
--- @field buf number
--- @field win number
--- @field pos [integer,integer]
--- @field target_buf number
--- @field target_win number
--- @field options sia.config.Diff
--- @field private writer sia.StreamRenderer?
local DiffStrategy = setmetatable({}, { __index = Strategy })
DiffStrategy.__index = DiffStrategy

--- @param buf number
--- @param win number
--- @param pos [integer,integer]
--- @param conversation sia.Conversation
--- @param options sia.config.Diff
function DiffStrategy.new(buf, win, pos, conversation, options)
  local obj = setmetatable(Strategy.new(conversation), DiffStrategy)
  vim.cmd(options.cmd)
  obj.target_win = vim.api.nvim_get_current_win()
  obj.target_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_buf(obj.target_win, obj.target_buf)
  obj.buf = buf
  obj.win = win
  obj.options = options
  obj.pos = pos or { 1, vim.api.nvim_buf_line_count(buf) }
  return obj
end

--- @private
function DiffStrategy:buf_is_loaded()
  return vim.api.nvim_buf_is_loaded(self.buf)
    and vim.api.nvim_buf_is_loaded(self.target_buf)
end

function DiffStrategy:on_request_start()
  if not self:buf_is_loaded() then
    return false
  end
  vim.bo[self.buf].modifiable = false
  vim.bo[self.target_buf].modifiable = true
  vim.bo[self.target_buf].buftype = "nofile"
  vim.bo[self.target_buf].ft = vim.bo[self.buf].ft
  for _, wo in ipairs(self.options.wo) do
    vim.wo[self.target_win][wo] = vim.wo[self.win][wo]
  end

  if self.pos[1] > 1 then
    local before = vim.api.nvim_buf_get_lines(self.buf, 0, self.pos[1] - 1, true)
    vim.api.nvim_buf_set_lines(self.target_buf, 0, 0, false, before)
  end

  vim.api.nvim_buf_set_extmark(self.buf, DIFF_NS, self.pos[1] - 1, 0, {
    hl_group = "SiaReplace",
    end_line = self.pos[2],
  })
  self:start_activity(self.target_buf, vim.api.nvim_buf_line_count(self.target_buf) - 1)
  self.writer = StreamRenderer:new({
    canvas = Canvas:new(self.target_buf, { temporary_text_hl = "SiaInsert" }),
    line = vim.api.nvim_buf_line_count(self.target_buf) - 1,
    temporary = true,
  })
  self:set_abort_keymap(self.target_buf)
  return true
end

function DiffStrategy:on_error(error)
  self:clear_activity()
  self:del_abort_keymap(self.target_buf)
  if vim.api.nvim_buf_is_loaded(self.buf) then
    vim.api.nvim_buf_clear_namespace(self.buf, DIFF_NS, 0, -1)
    vim.bo[self.buf].modifiable = true
  end
  self.conversation:untrack_messages()
  if error then
    vim.notify(error, vim.log.levels.ERROR)
  end
end

function DiffStrategy:on_cancel()
  self:on_error()
end

function DiffStrategy:on_stream_start()
  return self:buf_is_loaded()
end

function DiffStrategy:on_round_end()
  self.conversation:add_user_message(
    "If you're ready to replace the selected text now, output ONLY the replacement text - no explanations, no 'Here's the updated code:', no 'I've made these changes:', nothing else. Your entire next response will be used verbatim as the replacement."
  )
end

--- @param ctx sia.FinishContext
function DiffStrategy:on_finish(ctx)
  self:clear_activity()
  self:del_abort_keymap(self.target_buf)
  if vim.api.nvim_buf_is_loaded(self.buf) then
    vim.api.nvim_buf_clear_namespace(self.buf, DIFF_NS, 0, -1)
    vim.bo[self.buf].modifiable = true
  end
  local content = ctx.content
  local buf_loaded = vim.api.nvim_buf_is_loaded(self.target_buf)
  local diff_win_valid = vim.api.nvim_win_is_valid(self.target_win)
  local curr_win_valid = vim.api.nvim_win_is_valid(self.win)
  if
    not (
      self:buf_is_loaded()
      and buf_loaded
      and diff_win_valid
      and curr_win_valid
      and content
    )
  then
    self.conversation:untrack_messages()
    return
  end

  local replacement = vim.split(content, "\n", { plain = true })
  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, self.pos[1] - 1, true)
  vim.list_extend(lines, replacement)
  vim.list_extend(lines, vim.api.nvim_buf_get_lines(self.buf, self.pos[2], -1, true))
  vim.api.nvim_buf_set_lines(self.target_buf, 0, -1, false, lines)
  vim.api.nvim_set_current_win(self.target_win)
  vim.cmd("diffthis")
  vim.api.nvim_set_current_win(self.win)
  vim.cmd("diffthis")
  vim.bo[self.target_buf].modifiable = false
  vim.bo[self.buf].modifiable = true
  self.conversation:untrack_messages()
end

return DiffStrategy
