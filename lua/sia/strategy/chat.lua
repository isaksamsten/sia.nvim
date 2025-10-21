local common = require("sia.strategy.common")

local StreamRenderer = common.StreamRenderer
local Strategy = common.Strategy

local SUMMARIZE_PROMPT = [[Summarize the interaction. Make it suitable for a
buffer name in neovim using three to five words separated by
spaces. Only output the name, nothing else.]]

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
--- @field private assistant_extmark integer?
--- @field private has_generated_name boolean
--- @field private writer sia.StreamRenderer?
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
  obj.writer = nil
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
  obj.assistant_extmark = nil

  obj.has_generated_name = false
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

function ChatStrategy:buf_is_loaded()
  return vim.api.nvim_buf_is_loaded(self.buf)
end

function ChatStrategy:redraw()
  if not self:buf_is_loaded() then
    return
  end
  vim.bo[self.buf].modifiable = true
  self.canvas:clear()
  local model = self.conversation.model or require("sia.config").get_default_model()
  self.canvas:render_messages(self.conversation:get_messages(), model)
  vim.bo[self.buf].modifiable = false
end

function ChatStrategy:on_request_start()
  self.cancellable.is_cancelled = false
  if not self:buf_is_loaded() then
    return false
  end
  vim.bo[self.buf].modifiable = true
  local model = self.conversation.model or require("sia.config").get_default_model()
  self.canvas:render_messages({ self.conversation:last_message() }, model)
  self.assistant_extmark = self.canvas:render_assistant_header(model)
  return true
end

function ChatStrategy:on_round_started()
  return self:buf_is_loaded()
end

function ChatStrategy:on_error()
  if not self:buf_is_loaded() then
    return
  end
  self.canvas:update_progress({
    { "Something went wrong. Please try again.", "Error" },
  })
end

function ChatStrategy:on_stream_started()
  if not self:buf_is_loaded() then
    return false
  end
  self.canvas:clear_temporary_text()
  self.canvas:update_progress({ { "Analyzing your request...", "NonText" } })
  self:set_abort_keymap(self.buf)
  self.writer = StreamRenderer:new({
    canvas = self.canvas,
    line = vim.api.nvim_buf_line_count(self.buf) - 1,
    column = 0,
    temporary = false,
  })
  return true
end

function ChatStrategy:on_content_received(input)
  if not self:buf_is_loaded() then
    return false
  end
  if input.content then
    self.writer:append(input.content)
  end
  if input.reasoning then
    if input.reasoning.content then
      self.writer:append(input.reasoning.content, true)
    else
      self.writer.extra = input.reasoning.extra
    end
  end
  return true
end

function ChatStrategy:on_tool_call_received(tool)
  if not self:buf_is_loaded() then
    return false
  end
  self.canvas:update_progress({ { "Preparing to use tools...", "NonText" } })
  return Strategy.on_tool_call_received(self, tool)
end

function ChatStrategy:get_win()
  return vim.fn.bufwinid(self.buf)
end

function ChatStrategy:on_cancelled()
  if not self:buf_is_loaded() then
    return false
  end
  self.canvas:update_progress({
    {
      "Operation cancelled. Waiting for user...",
      "DiagnosticWarn",
    },
  })
end

function ChatStrategy:on_completed(control)
  if not self.writer then
    control.finish()
    return
  end

  if not self:buf_is_loaded() then
    control.finish()
    return
  end

  self.canvas:scroll_to_bottom()
  if not self.writer:is_empty() then
    self.conversation:add_instruction({
      role = "assistant",
      content = self.writer.cache,
    })
  end
  local handle_cleanup = function()
    self.writer = nil
    if not self:buf_is_loaded() then
      control.finish()
      return
    end

    self:del_abort_keymap(self.buf)
    self.canvas:clear_extmarks()
    if control.usage then
      self.canvas:update_usage(control.usage, self.assistant_extmark)
    end
    vim.bo[self.buf].modifiable = false
    if not self.has_generated_name then
      local Message = require("sia.conversation").Message
      require("sia.assistant").execute_query({
        Message:from_table({ role = "system", content = SUMMARIZE_PROMPT }),
        Message:from_table({
          role = "user",
          content = table.concat(
            vim.api.nvim_buf_get_lines(self.buf, 0, -1, true),
            "\n"
          ),
        }),
      }, {
        model = require("sia.config").get_default_model("fast_model"),
        callback = function(resp)
          if resp then
            self.name = "*sia " .. resp:lower():gsub("%s+", "-") .. "*"
            pcall(vim.api.nvim_buf_set_name, self.buf, self.name)
          end
          self.has_generated_name = true
          control.finish()
        end,
      })
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
            self.writer:append_newline()
            local line = self.writer.line
            for _, display in ipairs(tool_result.result.display_content) do
              self.writer:append(display)
            end
            self.writer:append_newline()
            self.canvas:highlight_tool(line, self.writer.line)
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
          self.writer:append_newline()
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
