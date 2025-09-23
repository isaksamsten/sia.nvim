local M = {}
--- @class sia.ToolResult
--- @field content string[]
--- @field context sia.Context?
--- @field kind string?
--- @field display_content string[]?
--- @field cancelled boolean?

--- Write text to a buffer via a canvas.
--- @class sia.Writer
--- @field canvas sia.Canvas?
--- @field buf integer?
--- @field start_line integer
--- @field start_col integer
--- @field line integer
--- @field column integer
--- @field persistent boolean
--- @field cache string[]
local Writer = {}
Writer.__index = Writer

--- @param canvas sia.Canvas?
--- @param buf integer?
--- @param line integer?
--- @param column integer?
--- @param persistent boolean?
function Writer:new(canvas, buf, line, column, persistent)
  if persistent == nil then
    persistent = true
  end
  local obj = {
    canvas = canvas,
    buf = buf,
    start_line = line or 0,
    start_col = column or 0,
    line = line or 0,
    column = column or 0,
    persistent = persistent,
    cache = {},
  }
  obj.cache[1] = ""
  setmetatable(obj, self)
  return obj
end

--- @param substring string
function Writer:append_substring(substring)
  if self.canvas then
    if self.persistent then
      self.canvas:append_text_at(self.line, self.column, substring)
    else
      self.canvas:append_text_extmark_at(self.line, self.column, substring)
    end
  elseif self.buf then
    vim.api.nvim_buf_set_text(self.buf, self.line, self.column, self.line, self.column, { substring })
  end
  self.cache[#self.cache] = self.cache[#self.cache] .. substring
  self.column = self.column + #substring
end

function Writer:append_newline()
  if self.canvas then
    if self.persistent then
      self.canvas:append_newline_at(self.line)
    else
      self.canvas:append_newline_extmark_at(self.line)
    end
  elseif self.buf then
    vim.api.nvim_buf_set_lines(self.buf, self.line + 1, self.line + 1, false, { "" })
  end
  self.line = self.line + 1
  self.column = 0
  self.cache[#self.cache + 1] = ""
end

--- @param content string The string content to append to the buffer.
function Writer:append(content)
  local index = 1
  while index <= #content do
    local newline = content:find("\n", index) or (#content + 1)
    local substring = content:sub(index, newline - 1)
    if #substring > 0 then
      self:append_substring(substring)
    end

    if newline <= #content then
      self:append_newline()
    end

    index = newline + 1
  end
end

--- @class sia.Strategy
--- @field is_busy boolean?
--- @field cancellable sia.Cancellable
--- @field tools table<integer, sia.ToolCall>
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
  obj.tools = {}
  obj.modified = {}
  obj.cancellable = cancellable or { is_cancelled = false }
  obj.auto_continue_after_cancellation = false
  return obj
end

function Strategy:on_init() end

function Strategy:on_continue() end

--- Callback triggered when the strategy starts.
--- @return boolean success
function Strategy:on_start()
  return true
end

--- Callback triggered on each streaming content.
--- @param content string
--- @return boolean success
function Strategy:on_progress(content)
  return true
end

--- Callback triggered when the model is reasoning
--- @param content string
--- @return boolean success
function Strategy:on_reasoning(content)
  return true
end

--- Callback triggered when the strategy is completed.
--- @param control { continue_execution: (fun():nil), finish: (fun():nil), usage: sia.Usage? }
function Strategy:on_complete(control) end

function Strategy:on_error() end

function Strategy:on_cancelled() end

--- @param control { continue_execution: (fun():nil), finish: (fun():nil) }
function Strategy:confirm_continue_after_cancelled_tool(control)
  if self.auto_continue_after_cancellation or require("sia.config").get_local_config().auto_continue then
    control.continue_execution()
  else
    vim.ui.input({
      prompt = "Continue? (Y/n/[a]lways): ",
    }, function(response)
      if response ~= nil and (response:lower() == "y" or response:lower() == "yes") then
        control.continue_execution()
      elseif response ~= nil and (response:lower() == "a" or response:lower() == "always") then
        self.auto_continue_after_cancellation = true
        control.continue_execution()
      else
        control.finish()
      end
    end)
  end
end

--- Callback triggered when LLM wants to call a function
---
--- Collects a streaming function call response
--- @param t table
--- @return boolean success
function Strategy:on_tool_call(t)
  for i, v in ipairs(t) do
    local func = v["function"]
    --- Patch for gemini models
    if v.index == nil then
      v.index = i
      v.id = "tool_call_id_" .. v.index
    end

    if not self.tools[v.index] then
      self.tools[v.index] = { ["function"] = { name = "", arguments = "" }, type = v.type, id = v.id }
    end
    if func.name then
      self.tools[v.index]["function"].name = self.tools[v.index]["function"].name .. func.name
    end
    if func.arguments then
      self.tools[v.index]["function"].arguments = self.tools[v.index]["function"].arguments .. func.arguments
    end
  end
  return true
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
  if not vim.tbl_isempty(self.tools) then
    --- @type sia.ParsedTool[]
    local parallel_tools = {}
    --- @type sia.ParsedTool[]
    local sequential_tools = {}

    --- @type { tool: sia.ParsedTool, status: string}[]
    local all_tools = {}

    --- @type {tool: sia.ToolCall, result: sia.ToolResult}[]
    local tool_results = {}

    local index = 1
    for _, tool in pairs(self.tools) do
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
            is_parallel = tool_fn.allow_parallel ~= nil and tool_fn.allow_parallel(self.conversation, tool_args)
          end
        end
      end
      local parsed_tool =
        { index = index, message = tool_message, name = tool_name, arguments = tool_args, tool_call = tool }
      all_tools[index] = { tool = parsed_tool, status = "pending" }
      tool_results[index] = nil
      index = index + 1
      if is_parallel then
        table.insert(parallel_tools, parsed_tool)
      else
        table.insert(sequential_tools, parsed_tool)
      end
    end

    self.tools = {}

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
                  tool_result = { content = { "Could not find tool..." } }
                end
                on_tool_finished(tool.index, tool.tool_call, tool_result)
              end),
            })
          else
            local error_message = { "Could not parse tool arguments" }
            tool.tool_call["function"].arguments = "{}"
            on_tool_finished(tool.index, tool.tool_call, { content = error_message })
          end
        else
          on_tool_finished(tool.index, tool.tool_call, { content = { "Tool is not a function" } })
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
                tool_result = { content = { "Could not find tool..." } }
              end
              on_tool_finished(tool.index, tool.tool_call, tool_result)
              process_next_tool()
            end),
          })
        else
          local error_message = { "Could not parse tool arguments" }
          tool.tool_call["function"].arguments = "{}"
          on_tool_finished(tool.index, tool.tool_call, { content = error_message })
          process_next_tool()
        end
      else
        on_tool_finished(tool.index, tool.tool_call, { content = { "Tool is not a function" } })
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

--- Returns the query submitted to the LLM
--- @return sia.Query
function Strategy:get_query()
  --- @type sia.Query
  return self.conversation:to_query()
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
return { Strategy = Strategy, Writer = Writer }
