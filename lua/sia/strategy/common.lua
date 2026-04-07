--- @class sia.ToolResult
--- @field content sia.Content
--- @field region sia.Region?
--- @field summary string?
--- @field ephemeral boolean?
--- @field actions sia.ToolAction[]?

--- Write text to a buffer via a canvas.
--- @class sia.StreamRenderer
--- @field canvas sia.Canvas?
--- @field buf integer?
--- @field start_line integer
--- @field start_col integer
--- @field line integer
--- @field column integer
--- @field temporary_line integer
--- @field temporary_column integer
--- @field temporary boolean
--- @field extra table?
local StreamRenderer = {}
StreamRenderer.__index = StreamRenderer

--- @class sia.StreamRendererOpts
--- @field canvas sia.Canvas?
--- @field buf integer?
--- @field line integer? 0-indexed
--- @field column integer? 0-indexed
--- @field temporary boolean?

--- @param opts sia.StreamRendererOpts?
function StreamRenderer:new(opts)
  opts = opts or {}
  local obj = {
    canvas = opts.canvas,
    buf = opts.buf,
    start_line = opts.line or 0,
    start_col = opts.column or 0,
    line = opts.line or 0,
    temporary_line = opts.line or 0,
    temporary_column = opts.column or 0,
    column = opts.column or 0,
    temporary = opts.temporary,
  }
  setmetatable(obj, self)
  return obj
end

--- @param substring string
--- @param temporary boolean?
function StreamRenderer:append_substring(substring, temporary)
  temporary = temporary or self.temporary
  if self.canvas then
    if not temporary then
      self.canvas:append_text_at(self.line, self.column, substring)
    else
      self.canvas:append_temporary_text_at(
        self.temporary_line,
        self.temporary_column,
        substring
      )
    end
  elseif self.buf then
    vim.api.nvim_buf_set_text(
      self.buf,
      self.line,
      self.column,
      self.line,
      self.column,
      { substring }
    )
  end
  if temporary then
    self.temporary_column = self.temporary_column + #substring
  else
    self.column = self.column + #substring
    self.temporary_column = self.column
  end
end

--- @param temporary boolean?
function StreamRenderer:append_newline(temporary)
  temporary = temporary or self.temporary
  if self.canvas then
    if not temporary then
      self.canvas:append_newline_at(self.line)
    else
      self.canvas:append_temporary_newline_at(self.temporary_line)
    end
  elseif self.buf then
    vim.api.nvim_buf_set_lines(self.buf, self.line + 1, self.line + 1, false, { "" })
  end
  if temporary then
    self.temporary_column = 0
    self.temporary_line = self.temporary_line + 1
  else
    self.line = self.line + 1
    self.column = 0
    self.temporary_column = 0
    self.temporary_line = self.line
  end
end

--- @param temporary boolean?
function StreamRenderer:append_newline_if_needed(temporary)
  if self.column == 0 then
    return
  end
  self:append_newline(temporary)
end

function StreamRenderer:is_empty()
  return self.start_col == self.column and self.start_line == self.line
end

--- Shift all line positions by `delta`. Useful when lines are inserted
--- above the renderer's current write position.
--- @param delta integer
function StreamRenderer:shift(delta)
  if delta == 0 then
    return
  end
  self.start_line = self.start_line + delta
  self.line = self.line + delta
  self.temporary_line = self.temporary_line + delta
end

--- @param content string The string content to append to the buffer.
--- @param temporary boolean?
function StreamRenderer:append(content, temporary)
  local index = 1
  while index <= #content do
    local newline = content:find("\n", index) or (#content + 1)
    local substring = content:sub(index, newline - 1)
    if #substring > 0 then
      self:append_substring(substring, temporary)
    end

    if newline <= #content then
      self:append_newline(temporary)
    end

    index = newline + 1
  end
end

--- @class sia.Strategy
--- @field is_busy boolean?
--- @field cancellable sia.Cancellable
--- @field conversation sia.Conversation
--- @field modified [integer]
local Strategy = {}
Strategy.__index = Strategy

--- @param conversation sia.Conversation
--- @param cancellable sia.Cancellable?
--- @return sia.Strategy
function Strategy.new(conversation, cancellable)
  local obj = setmetatable({}, Strategy)
  obj.conversation = conversation
  obj.modified = {}
  obj.cancellable = cancellable or { is_cancelled = false }
  return obj
end

--- Called at the very start of request execution, before any API calls are made.
--- This is the initialization phase where the strategy should set up its UI,
--- initialize buffers, and prepare to display content.
---
--- When: Once per request, before on_round_start()
--- Triggers: SiaInit autocmd if successful
---
--- @return boolean success If false, execution stops and on_error() is called
function Strategy:on_request_start()
  return true
end

--- Called at the beginning of each round of execution. A request may have multiple
--- rounds if tools are used (initial round + continuation rounds after tools execute).
---
--- When: Before each API call (initial request and after tool execution)
--- Use for: Showing status updates like "Analyzing your request..." between rounds
function Strategy:on_round_start() end

--- Called after one round has completed.
function Strategy:on_round_end() end

--- Called when the first data arrives from the streaming API response.
--- This signals that streaming has begun and the strategy should prepare to
--- receive content chunks. At this point, the API has responded successfully.
---
--- When: After on_request_start() and on_round_start(), when first stream data arrives
---
--- @return boolean success If false, execution stops and on_error() is called
function Strategy:on_stream_start()
  return true
end

--- Called repeatedly during streaming for each piece of content that arrives.
--- Content can be text chunks or reasoning content. This is where
--- the strategy displays the streaming response to the user.
---
--- When: Multiple times during streaming as content arrives
--- Frequency: Every time a delta arrives from the API (text or reasoning)
---
--- @param input sia.StreamDelta
--- @return boolean success If false, streaming is aborted
function Strategy:on_stream(input)
  return true
end

function Strategy:on_stream_end() end

--- Called with tool status updates during execution.
--- @param statuses sia.engine.Status[]
function Strategy:on_tool_status(statuses) end

--- Called once after all tools in a round have completed, with batch results.
--- Use for rendering summaries, updating UI state.
--- @param statuses sia.engine.Completed[]
function Strategy:on_tool_results(statuses) end

--- Called when the round loop ends (no more tools, or stream produced content only).
--- @param ctx sia.FinishContext
function Strategy:on_finish(ctx) end

--- Called with a transient status message during long-running operations
--- (e.g. context compaction, tool execution).
---
--- When: During context management or other async operations
--- Use for: Showing progress/status indicators to the user
---
--- @param message string The status message
--- @param severity "info"|"warning"|"error"|nil The message severity (nil = info)
function Strategy:on_status(message, severity) end

--- Called after context management completes (pruning and/or compaction).
--- The assistant calls this to inform the strategy about context budget changes
--- so it can update its UI (e.g. winbar budget display).
---
--- When: After each round's context management pass
--- Use for: Updating context budget displays, redrawing after compaction
---
--- @param info { budget: { estimated: integer, limit: integer, percent: number }?, pruned: boolean, compacted: boolean }
function Strategy:on_context_update(info) end

--- Called when an error occurs during execution. This can be API errors,
--- initialization failures, or stream errors.
---
--- Called when:
--- - on_request_start() returns false
--- - on_stream_start() returns false
--- - API returns an error response
---
--- Use for: Cleanup, showing error messages to user
---
--- @param error string?
function Strategy:on_error(error) end

--- Called when the user cancels the operation (typically via the abort keymap).
---
--- When: User cancels via abort keymap
---
--- Use for: Cleanup, showing cancellation message to user
function Strategy:on_cancel() end

--- Called by the assistant after a request completes (on_finish or after tool
--- results) to ask whether the strategy has queued work that should trigger a
--- new execution round.
---
--- The assistant owns the re-execution decision: it checks this return value
--- and calls execute_strategy itself when true.
--- @return boolean should_reexecute
function Strategy:on_request_end()
  return false
end

--- Called when tool calls are first detected in the API response.
--- This is a notification that tools will be included in the response, allowing
--- the strategy to show UI feedback like "Preparing to use tools...".
---
--- When: During streaming, before the complete tool_calls are assembled
--- Use for: Showing status updates like "Preparing to use tools..."
---
--- @return boolean success If false, streaming is aborted
function Strategy:on_tools()
  return true
end

--- @param buf integer
function Strategy:set_abort_keymap(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_set_keymap(buf, "n", "x", "", {
      callback = function()
        self.cancellable.is_cancelled = true
      end,
    })
  end
end

--- @param buf number
function Strategy:del_abort_keymap(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_del_keymap, buf, "n", "x")
  end
end

return { Strategy = Strategy, StreamRenderer = StreamRenderer }
