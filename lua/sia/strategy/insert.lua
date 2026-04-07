local common = require("sia.strategy.common")

local StreamRenderer = common.StreamRenderer
local Strategy = common.Strategy
local Canvas = require("sia.canvas").Canvas

local INSERT_NS = vim.api.nvim_create_namespace("SiaInsertStrategy")

--- @class sia.InsertStrategy : sia.Strategy
--- @field cursor integer[]
--- @field buf number
--- @field pos [integer, integer]
--- @field conversation sia.Conversation
--- @field private options sia.config.Insert
--- @field private writer sia.StreamRenderer?
local InsertStrategy = setmetatable({}, { __index = Strategy })
InsertStrategy.__index = InsertStrategy

--- @param cursor integer[]
--- @param buf number
--- @param pos [integer, integer]
--- @param conversation sia.Conversation
--- @param options sia.config.Insert
function InsertStrategy.new(buf, pos, cursor, conversation, options)
  local obj = setmetatable(Strategy.new(conversation), InsertStrategy)
  obj.buf = buf
  obj.pos = pos
  obj.cursor = cursor
  obj.options = options
  obj.writer = nil
  return obj
end

function InsertStrategy:is_buf_loaded()
  return vim.api.nvim_buf_is_loaded(self.buf)
end

function InsertStrategy:on_request_start()
  if not self:is_buf_loaded() then
    return false
  end

  local start_row, padding_direction = self:compute_placement()
  self.start_row = start_row
  self.padding_direction = padding_direction
  if padding_direction == "below" then
    self.start_row = start_row + 1
  end
  if self.padding_direction == "below" or self.padding_direction == "above" then
    self.start_col = 0
    vim.api.nvim_buf_call(self.buf, function()
      pcall(vim.cmd.undojoin)
    end)
  else
    -- TODO: account for cursor column if "cursor"
    self.start_col =
      #vim.api.nvim_buf_get_lines(self.buf, start_row - 1, start_row, false)[1]
  end
  local message = self.options.message or { "Generating response...", "SiaProgress" }
  vim.api.nvim_buf_set_extmark(
    self.buf,
    INSERT_NS,
    math.max(self.start_row - 1, 0),
    0,
    {
      virt_lines = { { { "🤖 ", "Normal" }, message } },
      virt_lines_above = self.start_row - 1 > 0,
    }
  )
  self.writer = StreamRenderer:new({
    line = math.max(0, self.start_row - 2),
    col = self.start_col,
    canvas = Canvas:new(self.buf, { temporary_text_hl = "SiaInsert" }),
    temporary = true,
  })

  self:set_abort_keymap(self.buf)
  return true
end

function InsertStrategy:on_stream_start()
  if not self:is_buf_loaded() then
    return false
  end
  vim.api.nvim_buf_clear_namespace(self.buf, INSERT_NS, 0, -1)
  return true
end

function InsertStrategy:on_error()
  if not self:is_buf_loaded() then
    return false
  end
  vim.api.nvim_buf_clear_namespace(self.buf, INSERT_NS, 0, -1)
  self.writer.canvas:clear_temporary_text()
end

function InsertStrategy:on_cancel()
  self:on_error()
end

--- @param input sia.StreamDelta
function InsertStrategy:on_stream(input)
  if not self:is_buf_loaded() then
    return false
  end
  vim.api.nvim_buf_call(self.buf, function()
    pcall(vim.cmd.undojoin)
  end)
  if input.content then
    self.writer:append(input.content)
  end
  return true
end

--- @param statuses sia.engine.Status[]
function InsertStrategy:on_tool_results(statuses)
  for _, status in ipairs(statuses) do
    if status.summary then
      self.writer:append_newline()
      self.writer:append(status.summary)
      self.writer:append_newline()
    end
  end
  if not self.writer:is_empty() then
    self.writer:append_newline()
  end
end

function InsertStrategy:on_round_end()
  self.conversation:add_user_message(
    "If you're ready to replace the selected text now, output ONLY the replacement text - no explanations, no 'Here's the updated code:', no 'I've made these changes:', nothing else. Your entire next response will be used verbatim as the replacement."
  )
end

--- @param ctx sia.FinishContext
function InsertStrategy:on_finish(ctx)
  if not self:is_buf_loaded() or not ctx.content then
    self.conversation:untrack_messages()
    return
  end

  self:del_abort_keymap(self.buf)
  self.writer.canvas:clear_temporary_text()
  vim.api.nvim_buf_clear_namespace(self.buf, INSERT_NS, 0, -1)
  if self.padding_direction == "below" or self.padding_direction == "above" then
    vim.api.nvim_buf_set_lines(
      self.buf,
      self.start_row - 1,
      self.start_row - 1,
      false,
      { "" }
    )
  end
  local content = vim.split(ctx.content, "\n")
  vim.api.nvim_buf_set_text(
    self.buf,
    self.start_row - 1,
    self.start_col,
    self.start_row - 1,
    self.start_col,
    content
  )
  local end_row = self.start_row + #content - 1
  local end_col = #content[#content]
  vim.api.nvim_buf_set_extmark(
    self.buf,
    INSERT_NS,
    self.start_row - 1,
    self.start_col,
    {
      end_line = end_row - 1,
      end_col = end_col,
      hl_group = "SiaInsert",
    }
  )
  self:post_process(content, self.start_row - 1, self.start_col, end_row - 1, end_col)
  self.writer = nil
  vim.defer_fn(function()
    if not self:is_buf_loaded() then
      return
    end
    vim.api.nvim_buf_clear_namespace(self.buf, INSERT_NS, 0, -1)
  end, 500)
  self.conversation:untrack_messages()
end

--- @private
function InsertStrategy:post_process(lines, srow, scol, erow, ecol)
  local post_process = self.options and self.options.post_process
  if not (post_process and self:is_buf_loaded()) then
    return
  end
  local ok, new_lines = pcall(post_process, {
    lines = lines,
    buf = self.buf,
    start_line = srow,
    start_col = scol,
    end_line = erow,
    end_col = ecol,
  })

  local changed = false
  if ok and type(new_lines) == "table" and #new_lines ~= #lines then
    vim.api.nvim_buf_call(self.buf, function()
      pcall(vim.cmd.undojoin)
    end)
    vim.api.nvim_buf_set_text(self.buf, srow, scol, erow, ecol, new_lines)
    changed = true
  elseif ok and type(new_lines) == "table" then
    for i = 1, #lines do
      if lines[i] ~= new_lines[i] then
        vim.api.nvim_buf_call(self.buf, function()
          pcall(vim.cmd.undojoin)
        end)
        vim.api.nvim_buf_set_text(self.buf, srow, scol, erow, ecol, new_lines)
        changed = true
        break
      end
    end
  end
  if changed then
    local new_erow, new_ecol
    if #new_lines == 1 then
      new_erow = srow
      new_ecol = scol + #new_lines[1]
    else
      new_erow = srow + #new_lines - 1
      new_ecol = #new_lines[#new_lines]
    end

    vim.api.nvim_buf_clear_namespace(self.buf, INSERT_NS, 0, -1)
    vim.api.nvim_buf_set_extmark(self.buf, INSERT_NS, math.max(0, srow - 1), scol, {
      end_line = new_erow,
      end_col = new_ecol,
      hl_group = "SiaInsertPostProcess",
    })
  end
end

--- @private
--- @return number start_line
--- @return string padding_direction
function InsertStrategy:compute_placement()
  local start_line, end_line = self.pos[1], self.pos[2]
  local padding_direction
  local placement = self.options.placement
  if type(placement) == "function" then
    placement = placement()
  end

  if type(placement) == "table" then
    padding_direction = placement[1]
    if placement[2] == "cursor" then
      start_line = self.cursor[1]
    elseif placement[2] == "end" then
      start_line = end_line
    elseif type(placement[2]) == "function" then
      start_line = placement[2](start_line, end_line)
    end
  elseif placement == "cursor" then
    start_line = self.cursor[1]
  elseif placement == "end" then
    start_line = end_line
  end

  return start_line, padding_direction
end

return InsertStrategy
