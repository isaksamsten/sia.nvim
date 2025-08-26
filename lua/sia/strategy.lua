local M = {}
local ChatCanvas = require("sia.canvas").ChatCanvas
local assistant = require("sia.assistant")
local Message = require("sia.conversation").Message

local DIFF_NS = vim.api.nvim_create_namespace("SiaDiffStrategy")
local INSERT_NS = vim.api.nvim_create_namespace("SiaInsertStrategy")

--- @class sia.ToolResult
--- @field content string[]
--- @field context sia.Context?
--- @field kind string?

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

--- @param buf integer
--- @param callback fun():nil
local function set_abort_keymap(buf, callback)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_set_keymap(buf, "n", "x", "", {
      callback = callback,
    })
  end
end

--- @param buf number
local function del_abort_keymap(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_del_keymap, buf, "n", "x")
  end
end

--- @class sia.Strategy
--- @field is_busy boolean?
--- @field cancellable sia.Cancellable?
--- @field tools table<integer, sia.ToolCall>
--- @field conversation sia.Conversation
--- @field modified [integer]
local Strategy = {}
Strategy.__index = Strategy

--- @return sia.Strategy
function Strategy:new(conversation)
  local obj = setmetatable({}, self)
  obj.conversation = conversation
  obj.tools = {}
  obj.modified = {}
  return obj
end

function Strategy:on_init() end

function Strategy:on_continue() end

--- Callback triggered when the strategy starts.
--- @param job number
function Strategy:on_start(job) end

--- Callback triggered on each streaming content.
--- @param content string
function Strategy:on_progress(content) end

--- Callback triggered when the model is reasoning
--- @param content string
function Strategy:on_reasoning(content) end

--- Callback triggered when the strategy is completed.
--- @param control { continue_execution: (fun():nil), finish: (fun():nil), job: number? }
function Strategy:on_complete(control) end

function Strategy:on_error() end

function Strategy:on_cancelled() end

--- Callback triggered when LLM wants to call a function
---
--- Collects a streaming function call response
--- @param t table
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
end

--- @class sia.ParsedTool
--- @field index integer
--- @field name string?
--- @field arguments table?
--- @field tool_call sia.ToolCall

--- @class sia.ExecuteToolsOpts
--- @field handle_tools_completion fun(args: { results?: {tool: sia.ToolCall, result: sia.ToolResult}[]})
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
        for i = 1, total_tools do
          if tool_results[i] then
            table.insert(ordered_results, tool_results[i])
          end
        end

        if opts.handle_tools_completion then
          opts.handle_tools_completion({ results = ordered_results })
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

--- @class sia.ToolCall
--- @field id string
--- @field type string
--- @field function { arguments: string, name: string }

--- @class sia.Cancellable
--- @field is_cancelled boolean

--- Create a new chat window.
--- @class sia.ChatStrategy : sia.Strategy
--- @field buf integer the split view buffer
--- @field options sia.config.Chat options for the chat
--- @field canvas sia.Canvas the canvas used to draw the conversation
--- @field name string
--- @field _is_named boolean
--- @field _writer sia.Writer? the writer
--- @field _reasoning_writer sia.Writer? reasoning writer
local ChatStrategy = setmetatable({}, { __index = Strategy })
ChatStrategy.__index = ChatStrategy

--- @type table<integer, sia.ChatStrategy>
ChatStrategy._buffers = {}

--- @type table<integer, integer>
ChatStrategy._order = {}

--- @param conversation sia.Conversation
--- @param options sia.config.Chat
function ChatStrategy:new(conversation, options)
  vim.cmd(options.cmd)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_buf(win, buf)

  if options.wo then
    for wo, value in pairs(options.wo) do
      vim.wo[win][wo] = value
    end
  end
  vim.bo[buf].ft = "sia"
  vim.bo[buf].syntax = "markdown"
  vim.bo[buf].buftype = "nowrite"
  local obj = setmetatable(Strategy:new(conversation), self)
  obj.buf = buf
  obj._writer = nil
  obj.options = options

  --- @cast obj sia.ChatStrategy
  ChatStrategy._buffers[obj.buf] = obj
  ChatStrategy._order[#ChatStrategy._order + 1] = obj.buf

  -- Ensure that the count has been incremented
  if ChatStrategy.count() == 1 then
    obj.name = "*sia*"
  else
    obj.name = "*sia " .. ChatStrategy.count() .. "*"
  end

  pcall(vim.api.nvim_buf_set_name, buf, obj.name)
  obj.canvas = ChatCanvas:new(obj.buf)
  local messages = conversation:get_messages()
  local model = obj.conversation.model or require("sia.config").options.defaults.model
  obj.canvas:render_messages(vim.list_slice(messages, 1, #messages - 1), model)

  obj._is_named = false
  obj.cancellable = { is_cancelled = false }
  return obj
end

function ChatStrategy:redraw()
  vim.bo[self.buf].modifiable = true
  self.canvas:clear()
  local model = self.conversation.model or require("sia.config").options.defaults.model
  self.canvas:render_messages(self.conversation:get_messages(), model)
  vim.bo[self.buf].modifiable = false
end

function ChatStrategy:on_init()
  self.cancellable.is_cancelled = false
  if vim.api.nvim_buf_is_loaded(self.buf) then
    vim.bo[self.buf].modifiable = true
    local model = self.conversation.model or require("sia.config").options.defaults.model
    self.canvas:render_messages({ self.conversation:last_message() }, model)
    if not self.hide_header then
      self.canvas:render_assistant_header(model)
    end
    self.canvas:update_progress({ { "Analyzing your request...", "NonText" } })
  end
end

function ChatStrategy:on_continue()
  self.canvas:update_progress({ { "Analyzing your request...", "NonText" } })
end

function ChatStrategy:on_error()
  self.canvas:update_progress({ { "Something went wrong. Please try again.", "Error" } })
end

function ChatStrategy:on_start(job)
  if vim.api.nvim_buf_is_loaded(self.buf) then
    self.canvas:clear_reasoning()
    self.canvas:update_progress({ { "Analyzing your request...", "NonText" } })
    set_abort_keymap(self.buf, function()
      self.cancellable.is_cancelled = true
      vim.fn.jobstop(job)
    end)
    local line_count = vim.api.nvim_buf_line_count(self.buf)
    if line_count > 0 then
      local last_line = vim.api.nvim_buf_get_lines(self.buf, -2, -1, false)
      if #last_line[1] > 0 then
        vim.api.nvim_buf_set_lines(self.buf, -1, -1, false, { "" })
        line_count = line_count + 1
      end
    end

    self._writer = Writer:new(self.canvas, self.buf, line_count - 1, 0)
    self._reasoning_writer = Writer:new(self.canvas, nil, line_count - 1, 0, false)
  end
end

function ChatStrategy:on_reasoning(content)
  -- self._reasoning_writer:append(content)
end

function ChatStrategy:on_progress(content)
  if vim.api.nvim_buf_is_loaded(self.buf) then
    self._writer:append(content)
  end
end

function ChatStrategy:on_tool_call(tool)
  self.canvas:update_progress({ { "Preparing to use tools...", "NonText" } })
  Strategy.on_tool_call(self, tool)
end

function ChatStrategy:get_win()
  return vim.fn.bufwinid(self.buf)
end

function ChatStrategy:on_cancelled()
  self.canvas:update_progress({
    { "Operation cancelled. Continue the conversation or start a new request", "DiagnosticWarn" },
  })
end

function ChatStrategy:on_complete(control)
  if not self._writer then
    return
  end

  if vim.api.nvim_buf_is_loaded(self.buf) then
    self.canvas:scroll_to_bottom()
    if #self._writer.cache > 0 and #self._writer.cache[1] > 0 then
      self.conversation:add_instruction({ role = "assistant", content = self._writer.cache }, nil)
    end

    self:execute_tools({
      cancellable = self.cancellable,
      handle_status_updates = function(statuses)
        local status_icons = { pending = " ", running = " ", done = " " }
        local status_hl = { pending = "NonText", running = "DiagnosticWarn", done = "DiagnosticOk" }
        local lines = {}
        for _, s in ipairs(statuses) do
          local icon = status_icons[s.status] or ""
          local friendly_message = s.tool.message
          local label = friendly_message or (s.tool.name or "tool")
          local hl = status_hl[s.status] or "NonText"
          table.insert(lines, { { icon, hl }, { label, "NonText" } })
        end
        self.canvas:update_tool_progress(lines)
      end,
      handle_tools_completion = function(opts)
        -- Add all tool instructions in order
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

        self.hide_header = nil
        -- -- Show completion message briefly before continuing
        -- self.canvas:update_progress({ { "Tools completed", "DiagnosticOk" } })
        -- vim.defer_fn(function()
        --   self.canvas:clear_extmarks()
        -- end, 500)
        control.continue_execution()
      end,
      handle_empty_toolset = function(opts)
        del_abort_keymap(self.buf)
        self.canvas:clear_extmarks()
        vim.bo[self.buf].modifiable = false
        if not self._is_named then
          assistant.execute_query({
            model = "openai/gpt-4o-mini",
            prompt = {
              {
                role = "system",
                content = [[Summarize the interaction. Make it suitable for a
buffer name in neovim using three to five words separated by
spaces. Only output the name, nothing else.]],
              },
              {
                role = "user",
                content = table.concat(vim.api.nvim_buf_get_lines(self.buf, 0, -1, true), "\n"),
              },
            },
          }, function(resp)
            if resp then
              self.name = "*sia " .. resp:lower():gsub("%s+", "-") .. "*"
              pcall(vim.api.nvim_buf_set_name, self.buf, self.name)
            end
            self._is_named = true
            control.finish()
          end)
        else
          control.finish()
        end
      end,
    })
    self._writer = nil
  end
end

--- Get the ChatStrategy associated with buf
--- @param buf number? the buffer if nil use current
--- @return sia.ChatStrategy?
function ChatStrategy.by_buf(buf)
  return ChatStrategy._buffers[buf or vim.api.nvim_get_current_buf()]
end

--- @param index integer
--- @return sia.ChatStrategy?
function ChatStrategy.by_order(index)
  return ChatStrategy._buffers[ChatStrategy._order[index]]
end

--- @return sia.ChatStrategy?
function ChatStrategy.last()
  return ChatStrategy.by_order(#ChatStrategy._order)
end

--- @return {buf: integer, win: integer}[]
function ChatStrategy.visible()
  local visible = {}
  for buf, _ in pairs(ChatStrategy._buffers) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local win = vim.fn.bufwinid(buf)
      if win ~= -1 then
        table.insert(visible, { buf = buf, win = win })
      end
    end
  end
  return visible
end

--- @return {buf: integer }[]
function ChatStrategy.all()
  local all = {}
  for buf, _ in pairs(ChatStrategy._buffers) do
    if vim.api.nvim_buf_is_loaded(buf) then
      table.insert(all, { buf = buf })
    end
  end
  return all
end

--- @param buf integer the buffer number
function ChatStrategy.remove(buf)
  local strategy = ChatStrategy._buffers[buf]
  if strategy == nil then
    return
  end

  ChatStrategy._buffers[buf] = nil
  for i, b in ipairs(ChatStrategy._order) do
    if b == buf then
      table.remove(ChatStrategy._order, i)
      break
    end
  end
end

--- @return number count the number of chat buffers
function ChatStrategy.count()
  return vim.tbl_count(ChatStrategy._buffers)
end

--- @class sia.DiffStrategy : sia.Strategy
--- @field buf number
--- @field win number
--- @field options sia.config.Diff
--- @field private _writer sia.Writer?
local DiffStrategy = setmetatable({}, { __index = Strategy })
DiffStrategy.__index = DiffStrategy

--- @param conversation sia.Conversation
--- @param options sia.config.Diff
function DiffStrategy:new(conversation, options)
  local obj = setmetatable(Strategy:new(conversation), self)
  vim.cmd(options.cmd)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_buf(win, buf)

  obj.buf = buf
  obj.win = win
  obj.options = options
  return obj
end

function DiffStrategy:on_init()
  vim.bo[self.buf].modifiable = true
  vim.bo[self.buf].buftype = "nofile"
  vim.bo[self.buf].ft = vim.bo[self.conversation.context.buf].ft
  for _, wo in ipairs(self.options.wo) do
    vim.wo[self.win][wo] = vim.wo[self.conversation.context.win][wo]
  end

  local context = self.conversation.context
  local before = vim.api.nvim_buf_get_lines(context.buf, 0, context.pos[1] - 1, true)
  vim.api.nvim_buf_set_lines(self.buf, 0, 0, false, before)

  vim.api.nvim_buf_clear_namespace(context.buf, DIFF_NS, 0, -1)
  vim.api.nvim_buf_set_extmark(context.buf, DIFF_NS, context.pos[1] - 1, 0, {
    virt_lines = { { { "🤖 ", "Normal" }, { "Analyzing changes...", "SiaProgress" } } },
    virt_lines_above = context.pos[1] - 1 > 0,
    hl_group = "SiaReplace",
    end_line = context.pos[2],
  })
end

function DiffStrategy:on_error()
  vim.api.nvim_buf_clear_namespace(self.buf, DIFF_NS, 0, -1)
end

--- @param job number
function DiffStrategy:on_start(job)
  set_abort_keymap(self.buf, function()
    vim.fn.jobstop(job)
  end)
  self._writer = Writer:new(nil, self.buf, vim.api.nvim_buf_line_count(self.buf) - 1, 0)
end

--- @param content string
function DiffStrategy:on_progress(content)
  if vim.api.nvim_buf_is_loaded(self.buf) then
    self._writer:append(content)
    vim.api.nvim_buf_set_extmark(self.buf, DIFF_NS, math.max(0, self._writer.start_line - 1), self._writer.start_col, {
      end_line = self._writer.line,
      end_col = self._writer.column,
      hl_group = "SiaInsert",
    })
  end
end

function DiffStrategy:on_complete(control)
  del_abort_keymap(self.buf)
  self:execute_tools({
    -- handle_status_updates = function(statuses)
    --   local status_icons = { pending = " ", running = " ", done = " " }
    --   local status_hl = { pending = "NonText", running = "DiagnosticWarn", done = "DiagnosticOk" }
    --   local lines = {}
    --   for _, s in ipairs(statuses) do
    --     local icon = status_icons[s.status] or ""
    --     local friendly_message = s.tool.message
    --     local label = friendly_message or (s.tool.name or "tool")
    --     local hl = status_hl[s.status] or "NonText"
    --     table.insert(lines, { { icon, hl }, { label, "NonText" } })
    --   end
    --   if #lines > 0 then
    --     vim.api.nvim_buf_clear_namespace(self.conversation.context.buf, DIFF_NS, 0, -1)
    --     vim.api.nvim_buf_set_extmark(self.conversation.context.buf, DIFF_NS, self.conversation.context.pos[1] - 1, 0, {
    --       virt_lines = lines,
    --       virt_lines_above = self.conversation.context.pos[1] - 1 > 0,
    --       hl_group = "SiaReplace",
    --       end_line = self.conversation.context.pos[2],
    --     })
    --   end
    -- end,
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
      control.continue_execution()
    end,
    handle_empty_toolset = function()
      if vim.api.nvim_buf_is_loaded(self.buf) then
        local context = self.conversation.context
        local after = vim.api.nvim_buf_get_lines(context.buf, context.pos[2], -1, true)
        vim.api.nvim_buf_set_lines(self.buf, -1, -1, false, after)
        if vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_win_is_valid(context.win) then
          vim.api.nvim_set_current_win(self.win)
          vim.cmd("diffthis")
          vim.api.nvim_set_current_win(context.win)
          vim.cmd("diffthis")
        end
        vim.bo[self.buf].modifiable = false
      end
      vim.api.nvim_buf_clear_namespace(self.conversation.context.buf, DIFF_NS, 0, -1)
      control.finish()
    end,
  })
end

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
function InsertStrategy:on_start(job)
  local context = self.conversation.context

  if self._padding_direction == "below" or self._padding_direction == "above" then
    vim.api.nvim_buf_set_lines(context.buf, self._line - 1, self._line - 1, false, { "" })
  end
  local content = vim.api.nvim_buf_get_lines(context.buf, self._line - 1, self._line, false)
  self._cal = #content
  vim.api.nvim_buf_clear_namespace(context.buf, INSERT_NS, 0, -1)
  set_abort_keymap(context.buf, function()
    vim.fn.jobstop(job)
  end)
end

function InsertStrategy:on_error()
  vim.api.nvim_buf_clear_namespace(self.conversation.context.buf, INSERT_NS, 0, -1)
end

function InsertStrategy:on_progress(content)
  local context = self.conversation.context
  if self._writer then
    vim.api.nvim_buf_call(context.buf, function()
      pcall(vim.cmd.undojoin)
    end)
  else
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
end

function InsertStrategy:on_complete(control)
  local context = self.conversation.context
  del_abort_keymap(context.buf)
  self:execute_tools({
    -- handle_status_updates = function(statuses)
    --   local status_icons = { pending = " ", running = " ", done = " " }
    --   local status_hl = { pending = "NonText", running = "DiagnosticWarn", done = "DiagnosticOk" }
    --   local lines = {}
    --   for _, s in ipairs(statuses) do
    --     local icon = status_icons[s.status] or ""
    --     local friendly_message = s.tool.message
    --     local label = friendly_message or (s.tool.name or "tool")
    --     local hl = status_hl[s.status] or "NonText"
    --     table.insert(lines, { { icon, hl }, { label, "NonText" } })
    --   end
    --   if #lines > 0 then
    --     vim.api.nvim_buf_clear_namespace(context.buf, INSERT_NS, 0, -1)
    --     vim.api.nvim_buf_set_extmark(context.buf, INSERT_NS, math.max(self._line - 1, 0), 0, {
    --       virt_lines = lines,
    --       virt_lines_above = self._line - 1 > 0,
    --     })
    --   end
    -- end,
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
      control.continue_execution()
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

--- @class sia.HiddenStrategy : sia.Strategy
--- @field conversation sia.Conversation
--- @field private _options sia.config.Hidden
--- @field private _writer sia.Writer?
local HiddenStrategy = setmetatable({}, { __index = Strategy })
HiddenStrategy.__index = HiddenStrategy

--- @param conversation sia.Conversation
--- @param options sia.config.Hidden
--- @param cancellable sia.Cancellable?
function HiddenStrategy:new(conversation, options, cancellable)
  local obj = setmetatable(Strategy:new(conversation), self)
  obj._options = options
  obj._writer = nil
  obj.cancellable = cancellable
  return obj
end

function HiddenStrategy:on_init()
  local context = self.conversation.context
  if context then
    vim.api.nvim_buf_clear_namespace(context.buf, INSERT_NS, 0, -1)
    vim.api.nvim_buf_set_extmark(context.buf, INSERT_NS, context.pos[1] - 1, 0, {
      virt_lines = { { { "🤖 ", "Normal" }, { "Processing in background...", "SiaProgress" } } },
      virt_lines_above = context.pos[1] - 1 > 0,
      hl_group = "SiaInsert",
      end_line = context.pos[2],
    })
  else
    vim.api.nvim_echo({ { "🤖 Processing in background...", "SiaProgress" } }, false, {})
  end
end

--- @param job number
function HiddenStrategy:on_start(job)
  local context = self.conversation.context
  if context then
    set_abort_keymap(context.buf, function()
      vim.fn.jobstop(job)
    end)
  end
  self._writer = Writer:new()
end

function HiddenStrategy:on_error()
  local context = self.conversation.context
  if context then
    vim.api.nvim_buf_clear_namespace(context.buf, INSERT_NS, 0, -1)
    del_abort_keymap(context.buf)
  end
end

function HiddenStrategy:on_progress(content)
  self._writer:append(content)
end

function HiddenStrategy:on_complete(control)
  local context = self.conversation.context
  if #self._writer.cache > 0 then
    self.conversation:add_instruction({
      role = "assistant",
      content = self._writer.cache,
      kind = "<assistant-callback>",
    })
  end

  self:execute_tools({
    cancellable = self.cancellable,
    handle_status_updates = function(statuses)
      local running_tools = vim.tbl_filter(function(s)
        return s.status == "running"
      end, statuses)
      if #running_tools > 0 then
        local tool = running_tools[1].tool
        local friendly_message = tool.message
        local message = friendly_message or ("Using " .. (tool.name or "tool") .. "...")
        if context then
          vim.api.nvim_buf_clear_namespace(context.buf, INSERT_NS, 0, -1)
          vim.api.nvim_buf_set_extmark(context.buf, INSERT_NS, context.pos[1] - 1, 0, {
            virt_lines = { { { "🤖 ", "Normal" }, { message, "SiaProgress" } } },
            virt_lines_above = context.pos[1] - 1 > 0,
          })
        else
          vim.api.nvim_echo({ { "🤖 " .. message, "SiaProgress" } }, false, {})
        end
      end
    end,
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
      control.continue_execution()
    end,
    handle_empty_toolset = function()
      if context then
        del_abort_keymap(context.buf)
        vim.api.nvim_buf_clear_namespace(context.buf, INSERT_NS, 0, -1)
      end
      local messages = self.conversation:get_messages({
        filter = function(message)
          return message.role == "assistant" and message.kind == "<assistant-callback>"
        end,
      })
      local content = Message.merge_content(messages)
      if content then
        self._options.callback(context, content)
      else
        vim.api.nvim_echo({ { "Sia: No response received", "Error" } }, false, {})
      end
      control.finish()
    end,
  })
end

function HiddenStrategy:on_cancelled()
  local context = self.conversation.context
  if context then
    vim.api.nvim_buf_clear_namespace(context.buf, INSERT_NS, 0, -1)
    del_abort_keymap(context.buf)
  end
  self._options.callback(self.conversation.context, { "Operation was cancelled by user" })
  vim.api.nvim_echo({ { "Sia: Operation cancelled", "DiagnosticWarn" } }, false, {})
end

M.HiddenStrategy = HiddenStrategy
M.ChatStrategy = ChatStrategy
M.DiffStrategy = DiffStrategy
M.InsertStrategy = InsertStrategy

return M
