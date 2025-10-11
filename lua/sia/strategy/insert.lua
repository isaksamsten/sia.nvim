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
  vim.api.nvim_buf_set_extmark(
    self.conversation.context.buf,
    INSERT_NS,
    math.max(self._line - 1, 0),
    0,
    {
      virt_lines = { { { "🤖 ", "Normal" }, message } },
      virt_lines_above = self._line - 1 > 0,
    }
  )
  return true
end

--- @param job number
function InsertStrategy:on_start()
  local context = self.conversation.context
  if not context or not vim.api.nvim_buf_is_loaded(context.buf) then
    return false
  end
  if self._padding_direction == "below" or self._padding_direction == "above" then
    vim.api.nvim_buf_set_lines(
      context.buf,
      self._line - 1,
      self._line - 1,
      false,
      { "" }
    )
  end
  local content =
    vim.api.nvim_buf_get_lines(context.buf, self._line - 1, self._line, false)
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
    control.finish()
    self.conversation:untrack_messages()
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
        self:post_process()
        self._writer = nil
      end
      vim.defer_fn(function()
        vim.api.nvim_buf_clear_namespace(
          self.conversation.context.buf,
          INSERT_NS,
          0,
          -1
        )
      end, 500)
      self.conversation:untrack_messages()
      control.finish()
    end,
  })
end

--- @private
function InsertStrategy:post_process()
  local post_process = self._options and self._options.post_process
  local ctx = self.conversation.context
  if post_process and ctx and vim.api.nvim_buf_is_loaded(ctx.buf) then
    local srow, scol = self._writer.start_line, self._writer.start_col
    local erow, ecol = self._writer.line, self._writer.column
    local lines = vim.api.nvim_buf_get_text(ctx.buf, srow, scol, erow, ecol, {})
    local ok, new_lines = pcall(post_process, {
      lines = lines,
      buf = ctx.buf,
      start_line = srow,
      start_col = scol,
      end_line = erow,
      end_col = ecol,
      filetype = vim.bo[ctx.buf].filetype,
    })

    local changed = false
    if ok and type(new_lines) == "table" and #new_lines ~= #lines then
      vim.api.nvim_buf_set_text(ctx.buf, srow, scol, erow, ecol, new_lines)
      changed = true
    elseif ok and type(new_lines) == "table" then
      for i = 1, #lines do
        if lines[i] ~= new_lines[i] then
          vim.api.nvim_buf_set_text(ctx.buf, srow, scol, erow, ecol, new_lines)
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

      vim.api.nvim_buf_clear_namespace(self.conversation.context.buf, INSERT_NS, 0, -1)
      vim.api.nvim_buf_set_extmark(
        self.conversation.context.buf,
        INSERT_NS,
        math.max(0, srow - 1),
        scol,
        {
          end_line = new_erow,
          end_col = new_ecol,
          hl_group = "SiaInsertPostProcess",
        }
      )
    end
  end
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
