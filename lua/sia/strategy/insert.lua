local common = require("sia.strategy.common")

local StreamRenderer = common.StreamRenderer
local Strategy = common.Strategy
local Canvas = require("sia.canvas").Canvas

local INSERT_NS = vim.api.nvim_create_namespace("SiaInsertStrategy")

--- @class sia.InsertStrategy : sia.Strategy
--- @field conversation sia.Conversation
--- @field private context sia.Context
--- @field private options sia.config.Insert
--- @field private writer sia.StreamRenderer?
local InsertStrategy = setmetatable({}, { __index = Strategy })
InsertStrategy.__index = InsertStrategy

--- @param conversation sia.Conversation
--- @param options sia.config.Insert
function InsertStrategy:new(conversation, options)
  local obj = setmetatable(Strategy:new(conversation), self)
  obj.conversation.no_supersede = true
  if not conversation.context then
    error("Can't intialize InsertStrategy")
  end
  self.context = conversation.context
  obj.options = options
  obj.writer = nil
  return obj
end

function InsertStrategy:is_buf_loaded()
  return vim.api.nvim_buf_is_loaded(self.context.buf)
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
    vim.api.nvim_buf_call(self.context.buf, function()
      pcall(vim.cmd.undojoin)
    end)
  else
    -- TODO: account for cursor column if "cursor"
    self.start_col =
      #vim.api.nvim_buf_get_lines(self.context.buf, start_row - 1, start_row, false)[1]
  end
  local message = self.options.message or { "Generating response...", "SiaProgress" }
  vim.api.nvim_buf_set_extmark(
    self.conversation.context.buf,
    INSERT_NS,
    math.max(self.start_row - 1, 0),
    0,
    {
      virt_lines = { { { "🤖 ", "Normal" }, message } },
      virt_lines_above = self.start_row - 1 > 0,
    }
  )
  self.writer = StreamRenderer:new({
    line = self.start_row - 1,
    col = self.start_col,
    canvas = Canvas:new(self.context.buf, { temporary_text_hl = "SiaInsert" }),
    temporary = true,
    use_cache = true,
  })

  self:set_abort_keymap(self.context.buf)
  return true
end

function InsertStrategy:on_stream_started()
  return self:is_buf_loaded()
end

function InsertStrategy:on_error()
  if not self:is_buf_loaded() then
    return false
  end
  vim.api.nvim_buf_clear_namespace(self.context.buf, INSERT_NS, 0, -1)
  self.writer.canvas:clear_temporary_text()
end

function InsertStrategy:on_cancelled()
  self:on_error()
end

function InsertStrategy:on_content_received(content)
  if not self:is_buf_loaded() then
    return false
  end
  vim.api.nvim_buf_call(self.context.buf, function()
    pcall(vim.cmd.undojoin)
  end)
  self.writer:append(content)
  return true
end

function InsertStrategy:on_completed(control)
  if not self:is_buf_loaded() then
    control.finish()
    self.conversation:untrack_messages()
    return false
  end

  self:execute_tools({
    handle_tools_completion = function(opts)
      if not self.writer:is_empty() then
        self.conversation:add_instruction({
          role = "assistant",
          content = self.writer.cache,
        })
      end
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
          self.writer:append_newline()
          if tool_result.result.display_content then
            for _, display in ipairs(tool_result.result.display_content) do
              self.writer:append(display)
            end
          end
        end
        self.conversation:add_instruction({
          role = "user",
          content = "If you're ready to insert the text now, output ONLY the text to insert - no explanations, no 'Here's the code:', no 'Now I'll insert:', nothing else. Your entire next response will be inserted verbatim into the file.",
        })
      end

      if not self.writer:is_empty() then
        self.writer:append_newline()
        self.writer:reset_cache()
      end

      if opts.cancelled then
        self:confirm_continue_after_cancelled_tool(control)
      else
        control.continue_execution()
      end
    end,
    handle_empty_toolset = function()
      if not self:is_buf_loaded() then
        control.finish()
        self.conversation:untrack_messages()
        return
      end

      self:del_abort_keymap(self.context.buf)
      self.writer.canvas:clear_temporary_text()
      vim.api.nvim_buf_clear_namespace(self.conversation.context.buf, INSERT_NS, 0, -1)
      if self.padding_direction == "below" or self.padding_direction == "above" then
        vim.api.nvim_buf_set_lines(
          self.context.buf,
          self.start_row - 1,
          self.start_row - 1,
          false,
          { "" }
        )
      end
      local content = self.writer.cache
      vim.api.nvim_buf_set_text(
        self.context.buf,
        self.start_row - 1,
        self.start_col,
        self.start_row - 1,
        self.start_col,
        content
      )
      local end_row = self.start_row + #content - 1
      local end_col = #content[#content]
      vim.api.nvim_buf_set_extmark(
        self.context.buf,
        INSERT_NS,
        self.start_row - 1,
        self.start_col,
        {
          end_line = end_row - 1,
          end_col = end_col,
          hl_group = "SiaInsert",
        }
      )
      self:post_process(
        self.writer.cache,
        self.start_row - 1,
        self.start_col,
        end_row - 1,
        end_col
      )
      self.writer = nil
      vim.defer_fn(function()
        if not self:is_buf_loaded() then
          return
        end
        vim.api.nvim_buf_clear_namespace(self.context.buf, INSERT_NS, 0, -1)
      end, 500)
      self.conversation:untrack_messages()
      control.finish()
    end,
  })
end

--- @private
function InsertStrategy:post_process(lines, srow, scol, erow, ecol)
  local post_process = self.options and self.options.post_process
  if not (post_process and self:is_buf_loaded()) then
    return
  end
  local ok, new_lines = pcall(post_process, {
    lines = lines,
    buf = self.context.buf,
    start_line = srow,
    start_col = scol,
    end_line = erow,
    end_col = ecol,
  })

  local changed = false
  if ok and type(new_lines) == "table" and #new_lines ~= #lines then
    vim.api.nvim_buf_call(self.conversation.context.buf, function()
      pcall(vim.cmd.undojoin)
    end)
    vim.api.nvim_buf_set_text(self.context.buf, srow, scol, erow, ecol, new_lines)
    changed = true
  elseif ok and type(new_lines) == "table" then
    for i = 1, #lines do
      if lines[i] ~= new_lines[i] then
        vim.api.nvim_buf_call(self.conversation.context.buf, function()
          pcall(vim.cmd.undojoin)
        end)
        vim.api.nvim_buf_set_text(self.context.buf, srow, scol, erow, ecol, new_lines)
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

    vim.api.nvim_buf_clear_namespace(self.context.buf, INSERT_NS, 0, -1)
    vim.api.nvim_buf_set_extmark(
      self.context.buf,
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

--- @private
--- @return number start_line
--- @return string padding_direction
function InsertStrategy:compute_placement()
  local start_line, end_line = self.context.pos[1], self.context.pos[2]
  local padding_direction
  local placement = self.options.placement
  if type(placement) == "function" then
    placement = placement()
  end

  if type(placement) == "table" then
    padding_direction = placement[1]
    if placement[2] == "cursor" then
      start_line = self.context.cursor[1]
    elseif placement[2] == "end" then
      start_line = end_line
    elseif type(placement[2]) == "function" then
      start_line = placement[2](start_line, end_line)
    end
  elseif placement == "cursor" then
    start_line = self.context.cursor[1]
  elseif placement == "end" then
    start_line = end_line
  end

  return start_line, padding_direction
end

return InsertStrategy
