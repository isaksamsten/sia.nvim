local common = require("sia.strategy.common")

local Writer = common.Writer
local Strategy = common.Strategy

local STATUS_ICONS = {
  pending = " ",
  running = " ",
  done = " ",
}

local STATUS_HL = {
  pending = "NonText",
  running = "DiagnosticWarn",
  done = "DiagnosticOk",
}

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
--- @field total_tokens integer?
--- @field name string
--- @field _last_assistant_header_extmark integer?
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

  if ChatStrategy.count() == 1 then
    obj.name = "*sia*"
  else
    obj.name = "*sia " .. ChatStrategy.count() .. "*"
  end

  pcall(vim.api.nvim_buf_set_name, buf, obj.name)
  obj.canvas = require("sia.canvas").Canvas:new(obj.buf)
  local messages = conversation:get_messages()
  local model = obj.conversation.model or require("sia.config").get_default_model()
  obj.canvas:render_messages(vim.list_slice(messages, 1, #messages - 1), model)
  obj._last_assistant_header_extmark = nil

  obj._is_named = false
  local augroup = vim.api.nvim_create_augroup("SiaChat" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = augroup,
    buffer = buf,
    once = true,
    callback = function(args)
      ChatStrategy.remove(args.buf)
    end,
  })
  return obj
end

function ChatStrategy:redraw()
  vim.bo[self.buf].modifiable = true
  self.canvas:clear()
  local model = self.conversation.model or require("sia.config").get_default_model()
  self.canvas:render_messages(self.conversation:get_messages(), model)
  vim.bo[self.buf].modifiable = false
end

function ChatStrategy:on_init()
  self.cancellable.is_cancelled = false
  if vim.api.nvim_buf_is_loaded(self.buf) then
    vim.bo[self.buf].modifiable = true
    local model = self.conversation.model or require("sia.config").get_default_model()
    self.canvas:render_messages({ self.conversation:last_message() }, model)
    self._last_assistant_header_extmark = self.canvas:render_assistant_header(model)
    self.canvas:update_progress({ { "Analyzing your request...", "NonText" } })
    return true
  else
    return false
  end
end

function ChatStrategy:on_continue()
  if vim.api.nvim_buf_is_loaded(self.buf) then
    self.canvas:update_progress({ { "Analyzing your request...", "NonText" } })
  end
end

function ChatStrategy:on_error()
  if vim.api.nvim_buf_is_loaded(self.buf) then
    self.canvas:update_progress({
      { "Something went wrong. Please try again.", "Error" },
    })
  end
end

function ChatStrategy:on_start()
  if vim.api.nvim_buf_is_loaded(self.buf) then
    self.canvas:clear_reasoning()
    self.canvas:update_progress({ { "Analyzing your request...", "NonText" } })
    self:set_abort_keymap(self.buf)
    local line_count = vim.api.nvim_buf_line_count(self.buf)
    if line_count > 0 then
      local last_line = vim.api.nvim_buf_get_lines(self.buf, -2, -1, false)
      if last_line[1]:match("%S") then
        vim.api.nvim_buf_set_lines(self.buf, -1, -1, false, { "" })
        line_count = line_count + 1
      end
    end

    self._writer = Writer:new(self.canvas, self.buf, line_count - 1, 0)
    self._reasoning_writer = Writer:new(self.canvas, nil, line_count - 1, 0, false)
    return true
  end
  return false
end

function ChatStrategy:on_reasoning(_)
  if not vim.api.nvim_buf_is_loaded(self.buf) then
    return false
  end
  return true
end

function ChatStrategy:on_progress(content)
  if not vim.api.nvim_buf_is_loaded(self.buf) then
    return false
  end
  self._writer:append(content)
  return true
end

function ChatStrategy:on_tool_call(tool)
  if vim.api.nvim_buf_is_loaded(self.buf) then
    self.canvas:update_progress({ { "Preparing to use tools...", "NonText" } })
    return Strategy.on_tool_call(self, tool)
  else
    return false
  end
end

function ChatStrategy:get_win()
  return vim.fn.bufwinid(self.buf)
end

function ChatStrategy:on_cancelled()
  if vim.api.nvim_buf_is_loaded(self.buf) then
    self.canvas:update_progress({
      {
        "Operation cancelled. Waiting for user...",
        "DiagnosticWarn",
      },
    })
  end
end

function ChatStrategy:on_complete(control)
  if not self._writer then
    control.finish()
    return
  end

  if not vim.api.nvim_buf_is_loaded(self.buf) then
    control.finish()
    return
  end

  self.canvas:scroll_to_bottom()
  if #self._writer.cache > 0 and #self._writer.cache[1] > 0 then
    self.conversation:add_instruction(
      { role = "assistant", content = self._writer.cache },
      nil
    )
  end
  local handle_cleanup = function()
    if not vim.api.nvim_buf_is_loaded(self.buf) then
      control.finish()
      return
    end

    self:del_abort_keymap(self.buf)
    self.canvas:clear_extmarks()
    if control.usage then
      self.canvas:update_usage(control.usage, self._last_assistant_header_extmark)
    end
    vim.bo[self.buf].modifiable = false
    if not self._is_named then
      local config = require("sia.config")
      require("sia.assistant").execute_query({
        model = config.get_default_model("fast_model"),
        prompt = {
          {
            role = "system",
            content = [[Summarize the interaction. Make it suitable for a
buffer name in neovim using three to five words separated by
spaces. Only output the name, nothing else.]],
          },
          {
            role = "user",
            content = table.concat(
              vim.api.nvim_buf_get_lines(self.buf, 0, -1, true),
              "\n"
            ),
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
  end

  self:execute_tools({
    cancellable = self.cancellable,
    handle_status_updates = function(statuses)
      local lines = {}
      for _, s in ipairs(statuses) do
        local icon = STATUS_ICONS[s.status] or ""
        local friendly_message = s.tool.message
        local label = friendly_message or (s.tool.name or "tool")
        local hl = STATUS_HL[s.status] or "NonText"
        table.insert(lines, { { icon, hl }, { label, "NonText" } })
      end
      self.canvas:update_tool_progress(lines)
    end,
    handle_tools_completion = function(opts)
      if opts.results then
        for _, tool_result in ipairs(opts.results) do
          if tool_result.result.display_content then
            self.canvas:append_tool_result(tool_result.result.display_content)
          end
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
        self:confirm_continue_after_cancelled_tool({
          continue_execution = control.continue_execution,
          finish = function()
            handle_cleanup()
            self.canvas:update_progress({ { "Waiting for user...", "NonText" } })
          end,
        })
      else
        control.continue_execution()
      end
    end,
    handle_empty_toolset = function()
      handle_cleanup()
    end,
  })
  self._writer = nil
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

  strategy.conversation:untrack_messages()
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

return ChatStrategy
