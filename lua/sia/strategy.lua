local M = {}
local utils = require("sia.utils")
local ChatCanvas = require("sia.canvas").ChatCanvas
local block = require("sia.blocks")
local assistant = require("sia.assistant")

--- Write text to a buffer.
--- @class sia.Writer
--- @field buf number
--- @field start_line integer
--- @field line number
--- @field column number
--- @field show (fun(s: string):boolean)?
--- @field cache string[]
local Writer = {}
Writer.__index = Writer

--- @param buf integer
--- @param line integer
--- @param column integer
--- @param show (fun(s: string):boolean)?
function Writer:new(buf, line, column, show)
  local obj = {
    buf = buf,
    start_line = line or 0,
    line = line or 0,
    column = column or 0,
    cache = {},
    show = show,
  }
  obj.cache[1] = ""
  setmetatable(obj, self)
  return obj
end

--- @param substring string
function Writer:append_substring(substring)
  vim.api.nvim_buf_set_text(self.buf, self.line, self.column, self.line, self.column, { substring })
  self.cache[#self.cache] = self.cache[#self.cache] .. substring
  self.column = self.column + #substring
end

function Writer:append_newline()
  vim.api.nvim_buf_set_lines(self.buf, self.line + 1, self.line + 1, false, { "" })
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
  vim.api.nvim_buf_set_keymap(buf, "n", "x", "", {
    callback = function()
      vim.fn.jobstop(job)
    end,
  })
end

--- @param buf number
local function del_abort_keymap(buf)
  vim.api.nvim_buf_del_keymap(buf, "n", "x")
end

--- @class sia.Strategy
local Strategy = {}

--- Callback triggered when the strategy starts.
--- @param job number
function Strategy:on_start(job) end

--- Callback triggered on each streaming content.
--- @param content string
function Strategy:on_progress(content) end

--- Callback triggered when the strategy is completed.
--- @return boolean? continue
function Strategy:on_complete() end

--- Callback triggered when LLM wants to call a function
--- @param t table
function Strategy:on_tool_call(t) end

--- Returns the query submitted to the LLM
--- @return sia.Query
function Strategy:get_query()
  --- @type sia.Query
  return nil
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
--- @field conversation sia.Conversation the (ongoing) conversation
--- @field name string
--- @field files string[]
--- @field block_action sia.BlockAction
--- @field tools table<integer, sia.ToolCall>
--- @field _writer sia.Writer? the writer
local SplitStrategy = {}
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
  local obj = setmetatable({}, self)
  obj.buf = buf
  obj._writer = nil
  obj.conversation = conversation
  obj.options = options
  obj.blocks = {}
  obj.tools = {}
  obj.files = utils.get_global_files()
  utils.clear_global_files()

  if type(options.block_action) == "table" then
    obj.block_action = options.block_action --[[@as sia.BlockAction]]
  else
    obj.block_action = block.actions[options.block_action]
  end

  if SplitStrategy.count() == 0 then
    obj.name = "*sia*"
  else
    obj.name = "*sia " .. SplitStrategy.count() .. "*"
  end
  vim.api.nvim_buf_set_name(buf, obj.name)

  SplitStrategy._buffers[obj.buf] = obj
  SplitStrategy._order[#SplitStrategy._order + 1] = obj.buf
  obj.canvas = ChatCanvas:new(obj.buf)
  local messages = conversation:get_messages()
  obj.canvas:render_messages(vim.list_slice(messages, 1, #messages - 1))
  return obj
end

--- @param files string[]
function SplitStrategy:add_files(files)
  for _, file in ipairs(files) do
    if not vim.tbl_contains(self.files, file) then
      self.files[#self.files + 1] = file
    end
  end
end

function SplitStrategy:add_file(file)
  if not vim.tbl_contains(self.files, file) then
    self.files[#self.files + 1] = file
  end
end

--- @param patterns string[]
function SplitStrategy:remove_files(patterns)
  --- @type string[]
  local regexes = {}
  for i, pattern in ipairs(patterns) do
    regexes[i] = vim.fn.glob2regpat(pattern)
  end

  --- @type integer[]
  local to_remove = {}
  for i, file in ipairs(self.files) do
    for _, regex in ipairs(regexes) do
      if vim.fn.match(file, regex) ~= -1 then
        table.insert(to_remove, i)
        break
      end
    end
  end

  for i = #to_remove, 1, -1 do
    table.remove(self.files, to_remove[i])
  end
end

function SplitStrategy:on_start(job)
  if vim.api.nvim_buf_is_valid(self.buf) and vim.api.nvim_buf_is_loaded(self.buf) then
    vim.bo[self.buf].modifiable = true
    self.canvas:render_messages({ self.conversation:last_message() })
    if self.canvas:line_count() == 1 then
      self.canvas:render_last({ "# Sia", "", "" })
    else
      self.canvas:render_last({ "", "---", "", "# Sia", "", "" })
    end
    set_abort_keymap(self.buf, job)
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
--- @param args sia.Context
function SplitStrategy:add_instruction(instruction, args)
  self.conversation:add_instruction(instruction, args)
end

function SplitStrategy:on_complete()
  local continue = false
  if vim.api.nvim_buf_is_valid(self.buf) and vim.api.nvim_buf_is_loaded(self.buf) then
    if #self._writer.cache > 0 then
      self.conversation:add_instruction(
        { role = "assistant", content = self._writer.cache },
        { buf = self.buf, cursor = vim.api.nvim_win_get_cursor(0) }
      )

      local blocks = block.parse_blocks(self.buf, self._writer.start_line, self._writer.cache)
      for _, b in ipairs(blocks) do
        self.blocks[#self.blocks + 1] = b
      end
      if self.block_action and self.options.automatic_block_action then
        require("sia.blocks").replace_all_blocks(self.block_action, blocks)
      end
    end

    if not vim.tbl_isempty(self.tools) and self.options.tools then
      for _, tool in pairs(self.tools) do
        local func = tool["function"]
        local status, arguments = pcall(vim.fn.json_decode, func.arguments)
        if func and status and self.options.tools[func.name] then
          local content = self.options.tools[func.name](self, arguments)
          if content then
            self.conversation:add_instruction(
              { role = "assistant", tool_calls = { tool } },
              { buf = self.buf, cursor = vim.api.nvim_win_get_cursor(0) }
            )

            self.conversation:add_instruction(
              { role = "tool", content = content, _tool_call_id = tool.id },
              { buf = self.buf, cursor = vim.api.nvim_win_get_cursor(0) }
            )
            continue = true
            self.canvas:render_last(content)
          else
            self.canvas:render_last({ " The function call to " .. func.name .. " failed." })
          end
        end
      end
      self.tools = {}
    end

    vim.bo[self.buf].modifiable = false
    self._writer = nil
    if not continue then
      assistant.execute_query({
        prompt = {
          {
            role = "system",
            content = [[Summarize the interaction. Make it suitable for a buffer
name in neovim using three to five words. Only output the name, nothing else.]],
          },
          { role = "user", content = table.concat(vim.api.nvim_buf_get_lines(self.buf, 0, -1, true), "\n") },
        },
      }, function(resp)
        if resp then
          self.name = "*sia " .. resp:lower():gsub("%s+", "-") .. "*"
          pcall(vim.api.nvim_buf_set_name, self.buf, self.name)
        end
      end)
    end
    return continue
  end
end

function SplitStrategy:on_tool_call(t)
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

--- @return sia.Query
function SplitStrategy:get_query()
  return self.conversation:to_query()
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
--- @field conversation sia.Conversation
--- @field buf number
--- @field win number
--- @field private _options sia.config.Diff
--- @field private _writer sia.Writer?
local DiffStrategy = {}
DiffStrategy.__index = DiffStrategy

--- @param conversation sia.Conversation
--- @param options sia.config.Diff
function DiffStrategy:new(conversation, options)
  local obj = setmetatable({}, self)
  vim.cmd(options.cmd)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)

  obj.buf = buf
  obj.win = win
  obj._options = options
  obj.conversation = conversation
  return obj
end

--- @param job number
function DiffStrategy:on_start(job)
  vim.bo[self.buf].modifiable = true
  set_abort_keymap(self.buf, job)
  vim.bo[self.buf].ft = vim.bo[self.conversation.context.buf].ft
  for _, wo in ipairs(self._options.wo) do
    vim.wo[self.win][wo] = vim.wo[self.conversation.context.win][wo]
  end

  local context = self.conversation.context
  local before = vim.api.nvim_buf_get_lines(context.buf, 0, context.pos[1] - 1, true)
  vim.api.nvim_buf_set_lines(self.buf, 0, 0, false, before)
  self._writer = Writer:new(self.buf, context.pos[1] - 1, 0)
end

--- @param content string
function DiffStrategy:on_progress(content)
  if vim.api.nvim_buf_is_valid(self.buf) and vim.api.nvim_buf_is_loaded(self.buf) then
    self._writer:append(content)
  end
end

function DiffStrategy:on_complete()
  del_abort_keymap(self.buf)
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
end

--- @return sia.Query
function DiffStrategy:get_query()
  return self.conversation:to_query()
end

--- @class sia.InsertStrategy : sia.Strategy
--- @field conversation sia.Conversation
--- @field private _options sia.config.Insert
--- @field private _writer sia.Writer?
local InsertStrategy = {}
InsertStrategy.__index = InsertStrategy

--- @param conversation sia.Conversation
--- @param options sia.config.Insert
function InsertStrategy:new(conversation, options)
  local obj = setmetatable({}, self)
  obj.conversation = conversation
  obj._options = options
  obj._writer = nil
  return obj
end

--- @param job number
function InsertStrategy:on_start(job)
  local context = self.conversation.context
  set_abort_keymap(context.buf, job)
end

function InsertStrategy:on_progress(content)
  local context = self.conversation.context
  if self._writer then
    vim.api.nvim_buf_call(context.buf, function()
      pcall(vim.cmd.undojoin)
    end)
  else
    local line, col = self:_get_insert_placement()
    self._writer = Writer:new(context.buf, line - 1, col)
  end
  self._writer:append(content)
end

function InsertStrategy:on_complete()
  local context = self.conversation.context
  del_abort_keymap(context.buf)
  if self._writer then
    self._writer = nil
  end
end

--- @return number start_line
--- @return number start_col
function InsertStrategy:_get_insert_placement()
  local context = self.conversation.context
  local start_line, end_line = context.pos[1], context.pos[2]
  local pad
  local placement = self._options.placement
  if type(placement) == "function" then
    placement = placement()
  end

  if type(placement) == "table" then
    pad = placement[1]
    if placement[2] == "cursor" then
      start_line = context.cursor[1]
    elseif placement[2] == "end" then
      start_line = end_line
    end
  elseif placement == "cursor" then
    start_line = context.cursor[1]
  elseif placement == "end" then
    start_line = end_line
  end

  if pad == "below" then
    vim.api.nvim_buf_set_lines(context.buf, start_line, start_line, false, { "" })
    start_line = start_line + 1
  elseif pad == "above" then
    vim.api.nvim_buf_set_lines(context.buf, start_line - 1, start_line - 1, false, { "" })
  end

  local line = vim.api.nvim_buf_get_lines(context.buf, start_line - 1, start_line, false)
  return start_line, #line[1]
end

function InsertStrategy:get_query()
  return self.conversation:to_query()
end

M.SplitStrategy = SplitStrategy
M.DiffStrategy = DiffStrategy
M.InsertStrategy = InsertStrategy
return M
