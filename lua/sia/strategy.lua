local M = {}
local utils = require("sia.utils")
local ChatCanvas = require("sia.canvas").ChatCanvas
local block = require("sia.blocks")
local assistant = require("sia.assistant")
local Message = require("sia.conversation").Message
local DIFF_NS = vim.api.nvim_create_namespace("sia_chat")

--- @param tools sia.CompletedTools[]
--- @param opts {on_confirm: (fun():nil), on_reject: (fun():nil)?}
local function request_user_confirmation(tools, opts)
  local require_confirmation = {}
  for _, tool in ipairs(tools) do
    if tool.confirmation then
      local descriptions = require_confirmation[tool.name]
      if descriptions == nil then
        descriptions = {}
      end
      for _, description in pairs(tool.confirmation.description) do
        table.insert(descriptions, description)
      end
      require_confirmation[tool.name] = descriptions
    end
  end

  if not vim.tbl_isempty(require_confirmation) then
    local bullet_list = {}
    for name, confirmation in pairs(require_confirmation) do
      table.insert(bullet_list, string.format("\n • %s (%s)", name, table.concat(confirmation, ", ")))
    end

    local prompt = string.format(
      "The following tools require confirmation:%s\n\nDo you want to continue? (y/N): ",
      table.concat(bullet_list)
    )
    vim.ui.input({ prompt = prompt }, function(input)
      if input and (input:lower() == "y" or input:lower() == "yes") then
        opts.on_confirm()
      else
        opts.on_reject()
      end
    end)
  else
    opts.on_confirm()
  end
end

--- Write text to a buffer.
--- @class sia.Writer
--- @field buf number?
--- @field start_line integer
--- @field line number
--- @field column number
--- @field cache string[]
local Writer = {}
Writer.__index = Writer

--- @param buf integer?
--- @param line integer?
--- @param column integer?
function Writer:new(buf, line, column)
  local obj = {
    buf = buf,
    start_line = line or 0,
    line = line or 0,
    column = column or 0,
    cache = {},
  }
  obj.cache[1] = ""
  setmetatable(obj, self)
  return obj
end

--- @param substring string
function Writer:append_substring(substring)
  if self.buf then
    vim.api.nvim_buf_set_text(self.buf, self.line, self.column, self.line, self.column, { substring })
  end
  self.cache[#self.cache] = self.cache[#self.cache] .. substring
  self.column = self.column + #substring
end

function Writer:append_newline()
  if self.buf then
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
--- @param job integer
local function set_abort_keymap(buf, job)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_set_keymap(buf, "n", "x", "", {
      callback = function()
        vim.fn.jobstop(job)
      end,
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
--- @field tools table<integer, sia.ToolCall>
--- @field conversation sia.Conversation
local Strategy = {}
Strategy.__index = Strategy

--- @return sia.Strategy
function Strategy:new(conversation)
  local obj = setmetatable({}, self)
  obj.conversation = conversation
  obj.tools = {}
  return obj
end

function Strategy:on_init() end

--- Callback triggered when the strategy starts.
--- @param job number
function Strategy:on_start(job) end

--- Callback triggered on each streaming content.
--- @param content string
function Strategy:on_progress(content) end

--- Callback triggered when the strategy is completed.
--- @param opts { on_complete: fun(): nil }
function Strategy:on_complete(opts) end

function Strategy:on_error() end

--- Callback triggered when LLM wants to call a function
---
--- Collects a streaming function call response
--- @param t table
function Strategy:on_tool_call(t)
  for _, v in ipairs(t) do
    local func = v["function"]
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

--- @alias sia.CompletedTools { name: string, confirmation: { description: string[] }?  }
--- @param opts { on_tool_start: (fun(tool: sia.ToolCall):nil), on_tool_complete: (fun(tool: sia.ToolCall, output: string[]):nil), on_tools_complete: (fun():nil), on_no_tools: (fun():nil) }
function Strategy:execute_tools(opts)
  if not vim.tbl_isempty(self.tools) then
    local tool_count = vim.tbl_count(self.tools)

    --- @type sia.CompletedTools[]
    local completed_tools = {}
    for _, tool in pairs(self.tools) do
      local func = tool["function"]
      if func then
        if opts.on_tool_start then
          opts.on_tool_start(tool)
        end
        local status, arguments = pcall(vim.fn.json_decode, func.arguments)
        if status then
          self.conversation:execute_tool(
            func.name,
            arguments,
            self,
            vim.schedule_wrap(function(content, confirmation)
              tool_count = tool_count - 1
              if opts.on_tool_complete then
                opts.on_tool_complete(tool, content)
                table.insert(completed_tools, { name = func.name, confirmation = confirmation })
              end
              if tool_count == 0 then
                if opts.on_tools_complete then
                  request_user_confirmation(
                    completed_tools,
                    { on_confirm = opts.on_tools_complete, on_reject = opts.on_no_tools }
                  )
                end
                self.tools = {}
              end
            end)
          )
        end
      end
    end
  else
    if opts.on_no_tools then
      opts.on_no_tools()
    end
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

--- Create a new split window tracking the chat.
--- @class sia.SplitStrategy : sia.Strategy
--- @field buf integer the split view buffer
--- @field options sia.config.Split options for the split
--- @field blocks sia.Block[] code blocks identified in the conversation
--- @field canvas sia.Canvas the canvas used to draw the conversation
--- @field name string
--- @field block_action sia.BlockAction
--- @field _writer sia.Writer? the writer
local SplitStrategy = setmetatable({}, { __index = Strategy })
SplitStrategy.__index = SplitStrategy

--- @type table<integer, sia.SplitStrategy>
SplitStrategy._buffers = {}

--- @type table<integer, integer>
SplitStrategy._order = {}

--- @param conversation sia.Conversation
--- @param options sia.config.Split
function SplitStrategy:new(conversation, options)
  vim.cmd(options.cmd)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(true, true)
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
  obj.blocks = {}

  if type(options.block_action) == "table" then
    obj.block_action = options.block_action --[[@as sia.BlockAction]]
  else
    obj.block_action = block.actions[options.block_action]
  end

  --- @cast obj sia.SplitStrategy
  SplitStrategy._buffers[obj.buf] = obj
  SplitStrategy._order[#SplitStrategy._order + 1] = obj.buf

  -- Ensure that the count has been incremented
  if SplitStrategy.count() == 0 then
    obj.name = "*sia*"
  else
    obj.name = "*sia " .. SplitStrategy.count() .. "*"
  end

  vim.api.nvim_buf_set_name(buf, obj.name)
  obj.canvas = ChatCanvas:new(obj.buf)
  local messages = conversation:get_messages()
  obj.canvas:render_messages(vim.list_slice(messages, 1, #messages - 1))

  return obj
end

function SplitStrategy:on_init()
  if vim.api.nvim_buf_is_valid(self.buf) and vim.api.nvim_buf_is_loaded(self.buf) then
    vim.bo[self.buf].modifiable = true
    self.canvas:render_messages({ self.conversation:last_message() })
    self.canvas:render_model(self.conversation.model or require("sia.config").options.defaults.model)
    if self.canvas:line_count() == 1 then
      self.canvas:render_last({ "# Sia", "" })
    else
      self.canvas:render_last({ "", "---", "", "# Sia", "" })
    end
    self.canvas:update_progress({ { "I'm thinking! Please wait...", "NonText" } })
  end
end

function SplitStrategy:on_error()
  self.canvas:update_progress({ { "An error has occured...", "Error" } })
end

function SplitStrategy:on_start(job)
  if vim.api.nvim_buf_is_valid(self.buf) and vim.api.nvim_buf_is_loaded(self.buf) then
    set_abort_keymap(self.buf, job)
    self.canvas:clear_extmarks()
    local line_count = vim.api.nvim_buf_line_count(self.buf)
    self._writer = Writer:new(self.buf, line_count - 1, 0)
  end
end

function SplitStrategy:on_progress(content)
  if vim.api.nvim_buf_is_valid(self.buf) and vim.api.nvim_buf_is_loaded(self.buf) then
    self._writer:append(content)
  end
end

--- @param instruction sia.config.Instruction
--- @param args sia.Context?
function SplitStrategy:add_instruction(instruction, args)
  self.conversation:add_instruction(instruction, args)
end

function SplitStrategy:get_win()
  return vim.fn.bufwinid(self.buf)
end

function SplitStrategy:on_complete(opts)
  del_abort_keymap(self.buf)
  if not self._writer then
    return
  end

  if vim.api.nvim_buf_is_valid(self.buf) and vim.api.nvim_buf_is_loaded(self.buf) then
    if #self._writer.cache > 0 then
      self.conversation:add_instruction({ role = "assistant", content = self._writer.cache })

      local blocks = block.parse_blocks(self.buf, self._writer.start_line, self._writer.cache)
      for _, b in ipairs(blocks) do
        self.blocks[#self.blocks + 1] = b
      end
      if self.block_action and self.options.automatic_block_action then
        vim.schedule(function()
          require("sia.blocks").replace_all_blocks(self.block_action, blocks)
        end)
      end
    end

    self:execute_tools({
      on_tool_start = function(tool)
        self.canvas:update_progress({ { "I'm calling '" .. tool["function"].name .. "'! Please wait...", "Comment" } })
      end,
      on_tool_complete = function(tool, content)
        self.canvas:clear_extmarks()
        self.canvas:render_last(content)
        self.conversation:add_instruction({ role = "assistant", tool_calls = { tool } })
        self.conversation:add_instruction({ role = "tool", content = content, _tool_call_id = tool.id })
      end,
      on_tools_complete = function()
        assistant.execute_strategy(self)
      end,
      on_no_tools = function()
        vim.bo[self.buf].modifiable = false
        assistant.execute_query({
          model = "gpt-4o-mini",
          prompt = {
            {
              role = "system",
              content = "Summarize the interaction. Make it suitable for a buffer name in neovim using three to five words separated by spaces. Only output the name, nothing else.",
            },
            { role = "user", content = table.concat(vim.api.nvim_buf_get_lines(self.buf, 0, -1, true), "\n") },
          },
        }, function(resp)
          if resp then
            self.name = "*sia " .. resp:lower():gsub("%s+", "-") .. "*"
            pcall(vim.api.nvim_buf_set_name, self.buf, self.name)
          end
          if opts and opts.on_complete then
            opts.on_complete()
          end
        end)
      end,
    })
    self._writer = nil
  end
end

--- @param line integer
--- @return sia.Block? block
function SplitStrategy:find_block(line)
  for _, b in ipairs(self.blocks) do
    if b.source.pos[1] <= line - 1 and line - 1 <= b.source.pos[2] then
      return b
    end
  end
  return nil
end

--- Get the SplitStrategy associated with buf
--- @param buf number? the buffer if nil use current
--- @return sia.SplitStrategy?
function SplitStrategy.by_buf(buf)
  return SplitStrategy._buffers[buf or vim.api.nvim_get_current_buf()]
end

--- @param index integer
--- @return sia.SplitStrategy?
function SplitStrategy.by_order(index)
  return SplitStrategy._buffers[SplitStrategy._order[index]]
end

--- @return sia.SplitStrategy?
function SplitStrategy.last()
  return SplitStrategy.by_order(#SplitStrategy._order)
end

--- @return {buf: integer, win: integer}[]
function SplitStrategy.visible()
  local visible = {}
  for buf, _ in pairs(SplitStrategy._buffers) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_is_valid(buf) then
      local win = vim.fn.bufwinid(buf)
      if win ~= -1 then
        table.insert(visible, { buf = buf, win = win })
      end
    end
  end
  return visible
end

--- @return {buf: integer }[]
function SplitStrategy.all()
  local all = {}
  for buf, _ in pairs(SplitStrategy._buffers) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
      table.insert(all, { buf = buf })
    end
  end
  return all
end

--- @param buf integer the buffer number
function SplitStrategy.remove(buf)
  local strategy = SplitStrategy._buffers[buf]
  if strategy == nil then
    return
  end

  SplitStrategy._buffers[buf] = nil
  for i, b in ipairs(SplitStrategy._order) do
    if b == buf then
      table.remove(SplitStrategy._order, i)
      break
    end
  end
end

--- @return number count the number of split buffers
function SplitStrategy.count()
  return #SplitStrategy._buffers
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
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)

  obj.buf = buf
  obj.win = win
  obj.options = options
  return obj
end

function DiffStrategy:on_init()
  vim.bo[self.buf].modifiable = true
  vim.bo[self.buf].ft = vim.bo[self.conversation.context.buf].ft
  for _, wo in ipairs(self.options.wo) do
    vim.wo[self.win][wo] = vim.wo[self.conversation.context.win][wo]
  end

  local context = self.conversation.context
  local before = vim.api.nvim_buf_get_lines(context.buf, 0, context.pos[1] - 1, true)
  vim.api.nvim_buf_set_lines(self.buf, 0, 0, false, before)

  vim.api.nvim_buf_clear_namespace(self.buf, DIFF_NS, 0, -1)
  vim.api.nvim_buf_set_extmark(self.buf, DIFF_NS, vim.api.nvim_buf_line_count(self.buf) - 1, 0, {
    virt_lines = { { { "🤖 ", "Normal" }, { "I'm thinking. Please wait...", "NonText" } } },
    virt_lines_above = true,
  })
end

function DiffStrategy:on_error()
  vim.api.nvim_buf_clear_namespace(self.buf, DIFF_NS, 0, -1)
end

--- @param job number
function DiffStrategy:on_start(job)
  vim.api.nvim_buf_clear_namespace(self.buf, DIFF_NS, 0, -1)
  set_abort_keymap(self.buf, job)
  self._writer = Writer:new(self.buf, vim.api.nvim_buf_line_count(self.buf) - 1, 0)
end

--- @param content string
function DiffStrategy:on_progress(content)
  if vim.api.nvim_buf_is_valid(self.buf) and vim.api.nvim_buf_is_loaded(self.buf) then
    self._writer:append(content)
  end
end

function DiffStrategy:on_complete(opts)
  del_abort_keymap(self.buf)
  self:execute_tools({
    on_tool_complete = function(tool, content)
      self.conversation:add_instruction({ role = "assistant", tool_calls = { tool } })
      self.conversation:add_instruction({ role = "tool", content = content, _tool_call_id = tool.id })
    end,
    on_tools_complete = function()
      assistant.execute_strategy(self)
    end,
    on_no_tools = function()
      if vim.api.nvim_buf_is_loaded(self.buf) and vim.api.nvim_buf_is_valid(self.buf) then
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
      if opts and opts.on_complete then
        opts.on_complete()
      end
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
  local message = self._options.message or { "Please wait...", "NonText" }
  vim.api.nvim_buf_set_extmark(self.conversation.context.buf, DIFF_NS, self._line - 1, 0, {
    virt_text = { { "🤖 ", "Normal" }, message },
    virt_text_pos = "overlay",
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
  vim.api.nvim_buf_clear_namespace(context.buf, DIFF_NS, 0, -1)
  set_abort_keymap(context.buf, job)
end

function InsertStrategy:on_error()
  vim.api.nvim_buf_clear_namespace(self.conversation.context.buf, DIFF_NS, 0, -1)
end

function InsertStrategy:on_progress(content)
  local context = self.conversation.context
  if self._writer then
    vim.api.nvim_buf_call(context.buf, function()
      pcall(vim.cmd.undojoin)
    end)
  else
    self._writer = Writer:new(context.buf, self._line - 1, self._col)
  end
  self._writer:append(content)
end

function InsertStrategy:on_complete(opts)
  local context = self.conversation.context
  del_abort_keymap(context.buf)
  self:execute_tools({
    on_tool_start = function() end,
    on_tool_complete = function(tool, content)
      self.conversation:add_instruction({ role = "assistant", tool_calls = { tool } })
      self.conversation:add_instruction({ role = "tool", content = content, _tool_call_id = tool.id })
    end,
    on_tools_complete = function()
      assistant.execute_strategy(self)
    end,
    on_no_tools = function()
      if self._writer then
        self._writer = nil
      end
      if opts and opts.on_complete then
        opts.on_complete()
      end
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
function HiddenStrategy:new(conversation, options)
  local obj = setmetatable(Strategy:new(conversation), self)
  obj._options = options
  obj._writer = nil
  return obj
end

function HiddenStrategy:on_init()
  local context = self.conversation.context
  vim.api.nvim_buf_clear_namespace(context.buf, DIFF_NS, 0, -1)
  vim.api.nvim_buf_set_extmark(context.buf, DIFF_NS, context.pos[1] - 1, 0, {
    virt_lines = { { { "🤖 ", "Normal" }, { "I'm thinking. Please wait...", "NonText" } } },
    virt_lines_above = true,
    hl_group = "NonText",
    end_line = context.pos[2],
  })
end

--- @param job number
function HiddenStrategy:on_start(job)
  local context = self.conversation.context
  set_abort_keymap(context.buf, job)
  self._writer = Writer:new()
end

function HiddenStrategy:on_error()
  local context = self.conversation.context
  vim.api.nvim_buf_clear_namespace(context.buf, DIFF_NS, 0, -1)
  del_abort_keymap(context.buf)
end

function HiddenStrategy:on_progress(content)
  self._writer:append(content)
end

function HiddenStrategy:on_complete(opts)
  local context = self.conversation.context
  del_abort_keymap(context.buf)
  if #self._writer.cache > 0 then
    self.conversation:add_instruction({ role = "assistant", content = self._writer.cache })
  end
  self:execute_tools({
    on_tool_start = function(tool) end,
    on_tool_complete = function(tool, content)
      self.conversation:add_instruction({ role = "assistant", tool_calls = { tool } })
      self.conversation:add_instruction({ role = "tool", content = content, _tool_call_id = tool.id })
    end,
    on_tools_complete = function()
      assistant.execute_strategy(self)
    end,
    on_no_tools = function()
      vim.api.nvim_buf_clear_namespace(context.buf, DIFF_NS, 0, -1)
      local messages = self.conversation:get_messages(function(message)
        return message.role == "assistant"
      end)
      local content = Message.merge_content(messages)
      if content then
        self._options.callback(context, content)
      else
        vim.api.nvim_echo({ { "Sia: no response", "Error" } }, false, {})
      end
      if opts and opts.on_complete then
        opts.on_complete()
      end
    end,
  })
end

M.HiddenStrategy = HiddenStrategy
M.SplitStrategy = SplitStrategy
M.DiffStrategy = DiffStrategy
M.InsertStrategy = InsertStrategy
return M
