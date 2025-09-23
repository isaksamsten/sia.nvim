local common = require("sia.strategy.common")

local Writer = common.Writer
local Strategy = common.Strategy

local INSERT_NS = vim.api.nvim_create_namespace("SiaInsertStrategy")

--- @class sia.InsertStrategy : sia.Strategy
--- @field conversation sia.Conversation
--- @field private _options sia.config.Insert
--- @field private _writer sia.Writer?
--- @field private _line integer
--- @field private _col integer
local InsertStrategy = setmetatable({}, { __index = Strategy })
InsertStrategy.__index = InsertStrategy

--- @param conversation sia.Conversation
--- @param options sia.config.Insert
function InsertStrategy:new(conversation, options)
  local obj = setmetatable(Strategy:new(conversation), self)
  obj._options = options
  obj._writer = nil

  return obj
end

function InsertStrategy:on_init()
  local context = self.conversation.context
  if not context or not vim.api.nvim_buf_is_loaded(context.buf) then
    return false
  end

  local line, padding_direction = self:_get_insert_placement()
  self._line = line
  self._padding_direction = padding_direction
  if padding_direction == "below" then
    self._line = line + 1
  end
  local message = self._options.message or { "Generating response...", "SiaProgress" }
  vim.api.nvim_buf_set_extmark(self.conversation.context.buf, INSERT_NS, math.max(self._line - 1, 0), 0, {
    virt_lines = { { { "🤖 ", "Normal" }, message } },
    virt_lines_above = self._line - 1 > 0,
  })
end

--- @param job number
function InsertStrategy:on_start()
  local context = self.conversation.context
  if not context or not vim.api.nvim_buf_is_loaded(context.buf) then
    return false
  end
  if self._padding_direction == "below" or self._padding_direction == "above" then
    vim.api.nvim_buf_set_lines(context.buf, self._line - 1, self._line - 1, false, { "" })
  end
  local content = vim.api.nvim_buf_get_lines(context.buf, self._line - 1, self._line, false)
  self._cal = #content
  self:set_abort_keymap(context.buf)
  return true
end

function InsertStrategy:on_error()
  local context = self.conversation.context
  if not context or not vim.api.nvim_buf_is_loaded(context.buf) then
    return false
  end
  vim.api.nvim_buf_clear_namespace(context.buf, INSERT_NS, 0, -1)
end

function InsertStrategy:on_progress(content)
  local context = self.conversation.context
  if not context or not vim.api.nvim_buf_is_loaded(context.buf) then
    return false
  end
  if self._writer then
    vim.api.nvim_buf_call(context.buf, function()
      pcall(vim.cmd.undojoin)
    end)
  else
    vim.api.nvim_buf_clear_namespace(self.conversation.context.buf, INSERT_NS, 0, -1)
    self._writer = Writer:new(nil, context.buf, self._line - 1, self._col)
  end
  self._writer:append(content)
  vim.api.nvim_buf_set_extmark(
    context.buf,
    INSERT_NS,
    math.max(0, self._writer.start_line - 1),
    self._writer.start_col,
    {
      end_line = self._writer.line,
      end_col = self._writer.column,
      hl_group = "SiaInsert",
    }
  )
  return true
end

function InsertStrategy:on_complete(control)
  local context = self.conversation.context
  if not context or not vim.api.nvim_buf_is_loaded(context.buf) then
    return false
  end

  self:del_abort_keymap(context.buf)
  self:execute_tools({
    handle_tools_completion = function(opts)
      if opts.results then
        for _, tool_result in ipairs(opts.results) do
          self.conversation:add_instruction({
            { role = "assistant", tool_calls = { tool_result.tool } },
            {
              role = "tool",
              content = tool_result.result.content,
              _tool_call = tool_result.tool,
              kind = tool_result.result.kind,
            },
          }, tool_result.result.context)
        end
      end

      if opts.cancelled then
        self:confirm_continue_after_cancelled_tool(control)
      else
        control.continue_execution()
      end
    end,
    handle_empty_toolset = function()
      if self._writer then
        self._writer = nil
      end
      vim.api.nvim_buf_clear_namespace(self.conversation.context.buf, INSERT_NS, 0, -1)
      control.finish()
    end,
  })
end

--- @return number start_line
--- @return string padding_direction
function InsertStrategy:_get_insert_placement()
  local context = self.conversation.context
  local start_line, end_line = context.pos[1], context.pos[2]
  local padding_direction
  local placement = self._options.placement
  if type(placement) == "function" then
    placement = placement()
  end

  if type(placement) == "table" then
    padding_direction = placement[1]
    if placement[2] == "cursor" then
      start_line = context.cursor[1]
    elseif placement[2] == "end" then
      start_line = end_line
    elseif type(placement[2]) == "function" then
      start_line = placement[2](start_line, end_line)
    end
  elseif placement == "cursor" then
    start_line = context.cursor[1]
  elseif placement == "end" then
    start_line = end_line
  end

  return start_line, padding_direction
end

return InsertStrategy
