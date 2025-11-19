local M = {}
--- @class sia.ToolResult
--- @field content string[]
--- @field context sia.Context?
--- @field kind string?
--- @field display_content string[]?
--- @field cancelled boolean?

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
--- @field pending_tools table<integer, sia.ToolCall>
--- @field conversation sia.Conversation
--- @field modified [integer]
--- @field auto_continue_after_cancellation boolean?
local Strategy = {}
Strategy.__index = Strategy

--- @param conversation sia.Conversation
--- @param cancellable sia.Cancellable?
--- @return sia.Strategy
function Strategy:new(conversation, cancellable)
  local obj = setmetatable({}, self)
  obj.conversation = conversation
  obj.pending_tools = {}
  obj.modified = {}
  obj.cancellable = cancellable or { is_cancelled = false }
  obj.auto_continue_after_cancellation = false
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
---
--- @return nil This is a notification callback with no return value
function Strategy:on_round_start() end

--- Called when the first data arrives from the streaming API response.
--- This signals that streaming has begun and the strategy should prepare to
--- receive content chunks. At this point, the API has responded successfully.
---
--- When: After on_request_start() and on_round_start(), when first stream data arrives
--- Triggers: SiaStart autocmd if successful
---
--- @return boolean success If false, execution stops and on_error() is called
function Strategy:on_stream_start()
  return true
end

--- Called repeatedly during streaming for each piece of content that arrives.
--- Content can be text chunks, reasoning content, or tool calls. This is where
--- the strategy displays the streaming response to the user.
---
--- When: Multiple times during streaming as content arrives
--- Frequency: Every time a delta arrives from the API (text, reasoning, or tool_calls)
---
--- @param input { content: string?, reasoning: table?, tool_calls: sia.ToolCall[]?}
--- @return boolean success If false, streaming is aborted
function Strategy:on_content(input)
  return true
end

--- Called after streaming completes. This is where the strategy executes tools
--- (if any were detected), performs cleanup, and decides whether to continue with
--- another round (if tools were used) or finish.
---
--- When: After all content has been streamed
--- Triggers: SiaComplete autocmd when control.finish() is called
---
--- The control table provides:
--- - continue_execution(): Start another round (typically after tool execution)
--- - finish(): End execution and mark strategy as not busy
--- - content: The complete streamed content as string[]
--- - usage: Token usage statistics
---
--- @param control { continue_execution: (fun():nil), finish: (fun():nil), usage: sia.Usage?, content: string[]? }
function Strategy:on_complete(control) end

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
--- @return nil This is a notification callback
function Strategy:on_error() end

--- Called when the user cancels the operation (typically via the abort keymap).
---
--- When: User cancels via abort keymap
---
--- Use for: Cleanup, showing cancellation message to user
---
--- @return nil This is a notification callback
function Strategy:on_cancel() end

--- Called when tool calls are first detected in the API response.
--- This is a notification that tools will be included in the response, allowing
--- the strategy to show UI feedback like "Preparing to use tools...".
---
--- Note: The actual tool call data arrives later through on_content() with
--- input.tool_calls populated. This callback just signals that tools were detected.
---
--- When: During streaming, before the complete tool_calls are assembled
--- Use for: Showing status updates like "Preparing to use tools..."
---
--- @return boolean success If false, streaming is aborted
function Strategy:on_tools()
  return true
end

--- @protected
--- @param control { continue_execution: (fun():nil), finish: (fun():nil) }
function Strategy:confirm_continue_after_cancelled_tool(control)
  if
    self.auto_continue_after_cancellation
    or require("sia.config").get_auto_continue()
  then
    control.continue_execution()
  else
    vim.ui.input({
      prompt = "Continue? (Y/n/[a]lways): ",
    }, function(response)
      if response ~= nil and (response:lower() == "y" or response:lower() == "yes") then
        control.continue_execution()
      elseif
        response ~= nil and (response:lower() == "a" or response:lower() == "always")
      then
        self.auto_continue_after_cancellation = true
        control.continue_execution()
      else
        control.finish()
      end
    end)
  end
end

--- @class sia.ParsedTool
--- @field index integer
--- @field name string?
--- @field arguments table?
--- @field tool_call sia.ToolCall

--- @class sia.ExecuteToolsOpts
--- @field handle_tools_completion fun(args: { results?: {tool: sia.ToolCall, result: sia.ToolResult}[], cancelled: boolean})
--- @field handle_empty_toolset fun(args: table?)
--- @field handle_status_updates? fun(statuses: table<string, {tool: sia.ParsedTool, status: string}>)
--- @field cancellable sia.Cancellable?

--- @param opts sia.ExecuteToolsOpts
function Strategy:execute_tools(opts)
  if not vim.tbl_isempty(self.pending_tools) then
    --- @type sia.ParsedTool[]
    local parallel_tools = {}
    --- @type sia.ParsedTool[]
    local sequential_tools = {}

    --- @type { tool: sia.ParsedTool, status: string}[]
    local all_tools = {}

    --- @type {tool: sia.ToolCall, result: sia.ToolResult}[]
    local tool_results = {}

    local index = 1
    for _, tool in pairs(self.pending_tools) do
      local tool_name = nil
      local tool_args = nil
      --- @type string?
      local tool_message = nil
      local is_parallel = false
      local fun = tool["function"]
      if fun then
        tool_name = fun.name
        local status, args
        if fun.arguments and fun.arguments:match("%S") then
          status, args = pcall(vim.fn.json_decode, fun.arguments)
        else
          -- Handle empty or whitespace-only arguments
          status, args = true, {}
        end
        if status then
          tool_args = args
          local tool_fn = self.conversation.tool_fn[fun.name]
          if tool_fn then
            if tool_fn.message ~= nil then
              if type(tool_fn.message) == "string" then
                tool_message = tool_fn.message
              else
                tool_message = tool_fn.message(args)
              end
            end
            is_parallel = tool_fn.allow_parallel ~= nil
              and tool_fn.allow_parallel(self.conversation, tool_args)
          end
        end
      end
      local parsed_tool = {
        index = index,
        message = tool_message,
        name = tool_name,
        arguments = tool_args,
        tool_call = tool,
      }
      all_tools[index] = { tool = parsed_tool, status = "pending" }
      tool_results[index] = nil
      index = index + 1
      if is_parallel then
        table.insert(parallel_tools, parsed_tool)
      else
        table.insert(sequential_tools, parsed_tool)
      end
    end

    self.pending_tools = {}

    if opts.handle_status_updates then
      opts.handle_status_updates(all_tools)
    end

    local total_tools = #sequential_tools + #parallel_tools
    local completed_count = 0

    --- @param idx integer
    local function update_status(idx, status)
      all_tools[idx].status = status
      if opts.handle_status_updates then
        opts.handle_status_updates(all_tools)
      end
    end

    --- @param index integer
    --- @param tool_call sia.ToolCall
    --- @param tool_result sia.ToolResult
    local function on_tool_finished(index, tool_call, tool_result)
      completed_count = completed_count + 1
      update_status(index, "done")
      tool_results[index] = { tool = tool_call, result = tool_result }

      if completed_count == total_tools then
        local ordered_results = {}
        local has_cancelled_tools = false

        for i = 1, total_tools do
          if tool_results[i] then
            table.insert(ordered_results, tool_results[i])
            if tool_results[i].result.cancelled then
              has_cancelled_tools = true
            end
          end
        end

        if opts.handle_tools_completion then
          opts.handle_tools_completion({
            results = ordered_results,
            cancelled = has_cancelled_tools,
          })
        end
      end
    end

    for i, tool in ipairs(parallel_tools) do
      vim.schedule(function()
        update_status(tool.index, "running")
        if tool.name then
          if tool.arguments then
            self.conversation:execute_tool(tool.name, tool.arguments, {
              cancellable = opts.cancellable,
              callback = vim.schedule_wrap(function(tool_result)
                if not tool_result then
                  tool_result =
                    { content = { "Could not find tool..." }, kind = "failed" }
                end
                on_tool_finished(tool.index, tool.tool_call, tool_result)
              end),
            })
          else
            local error_message = { "Could not parse tool arguments" }
            tool.tool_call["function"].arguments = "{}"
            on_tool_finished(
              tool.index,
              tool.tool_call,
              { content = error_message, kind = "failed" }
            )
          end
        else
          on_tool_finished(tool.index, tool.tool_call, {
            content = { "Tool is not a function. Try without parallel tool calls." },
            kind = "failed",
          })
        end
      end)
    end

    -- Interactive tools
    local current_tool_index = 1
    local function process_next_tool()
      if current_tool_index > #sequential_tools then
        return
      end
      local tool = sequential_tools[current_tool_index]
      update_status(tool.index, "running")
      current_tool_index = current_tool_index + 1
      if tool.name then
        if tool.arguments then
          self.conversation:execute_tool(tool.name, tool.arguments, {
            cancellable = opts.cancellable,
            callback = vim.schedule_wrap(function(tool_result)
              if not tool_result then
                tool_result =
                  { content = { "Could not find tool..." }, kind = "failed" }
              end
              on_tool_finished(tool.index, tool.tool_call, tool_result)
              process_next_tool()
            end),
          })
        else
          local error_message = { "Could not parse tool arguments" }
          tool.tool_call["function"].arguments = "{}"
          on_tool_finished(
            tool.index,
            tool.tool_call,
            { content = error_message, kind = "failed" }
          )
          process_next_tool()
        end
      else
        on_tool_finished(
          tool.index,
          tool.tool_call,
          { content = { "Tool is not a function" }, kind = "failed" }
        )
        process_next_tool()
      end
    end

    if #sequential_tools > 0 then
      process_next_tool()
    end
  else
    opts.handle_empty_toolset({})
  end
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
