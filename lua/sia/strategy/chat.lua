local common = require("sia.strategy.common")
local winbar = require("sia.ui.winbar")

local StreamRenderer = common.StreamRenderer
local Strategy = common.Strategy

local SUMMARIZE_PROMPT = [[Summarize the interaction. Make it suitable for a
buffer name in neovim using three to five words separated by
spaces. Only output the name, nothing else.]]

--- @class sia.ToolCall
--- @field id string
--- @field type "function"|"custom"
--- @field call_id string?
--- @field function { arguments: string, name: string }? set for function tool calls
--- @field custom { name: string, input: string }? set for custom (freeform) tool calls

--- @class sia.Cancellable
--- @field is_cancelled boolean

--- Create a new chat window.
--- @class sia.ChatStrategy : sia.Strategy
--- @field buf integer the split view buffer
--- @field options sia.config.Chat options for the chat
--- @field canvas sia.Canvas the canvas used to draw the conversation
--- @field total_tokens integer?
--- @field private assistant_extmark integer?
--- @field private has_generated_name boolean
--- @field private writer sia.StreamRenderer?
--- @field private queued_instructions {instruction: sia.config.Instruction|string|sia.config.Instruction[], context: sia.Context?}[]
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
  obj.queued_instructions = {}

  --- @cast obj sia.ChatStrategy
  ChatStrategy._buffers[obj.buf] = obj
  ChatStrategy._order[#ChatStrategy._order + 1] = obj.buf

  obj.conversation.name = tostring(ChatStrategy.count())
  pcall(vim.api.nvim_buf_set_name, buf, "*sia " .. obj.conversation.name .. "*")
  obj.canvas = require("sia.canvas").Canvas:new(obj.buf)
  local messages = conversation:get_messages()
  obj.canvas:render_messages(
    vim.list_slice(messages, 1, #messages - 1),
    obj.conversation.model:name()
  )
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

  if options.winbar then
    winbar.attach(buf, conversation, obj)
  end

  return obj
end

function ChatStrategy:buf_is_loaded()
  return vim.api.nvim_buf_is_loaded(self.buf)
end

function ChatStrategy:redraw()
  if not self:buf_is_loaded() then
    return
  end
  self.canvas:clear()
  self.canvas:render_messages(
    self.conversation:get_messages(),
    self.conversation.model:name()
  )
end

function ChatStrategy:queue_size()
  return #self.queued_instructions
end

--- @param instruction sia.config.Instruction|sia.config.Instruction[]|string
--- @param context sia.Context?
function ChatStrategy:queue_instruction(instruction, context)
  table.insert(self.queued_instructions, {
    instruction = instruction,
    context = context,
  })
end

--- @return boolean flushed
function ChatStrategy:flush_queued_instructions()
  if vim.tbl_isempty(self.queued_instructions) then
    return false
  end

  local before_count = #self.conversation:prepare_messages()
  for _, queued in ipairs(self.queued_instructions) do
    self.conversation:add_instruction(queued.instruction, queued.context)
  end

  if self:buf_is_loaded() then
    local prepared = self.conversation:prepare_messages()
    local new_messages = vim.list_slice(prepared, before_count + 1)
    self.canvas:render_messages(new_messages, self.conversation.model:name())
  end

  self.queued_instructions = {}
  return true
end

function ChatStrategy:on_request_start()
  self.cancellable.is_cancelled = false
  if not self:buf_is_loaded() then
    return false
  end
  local model = self.conversation.model
  self.canvas:render_messages({ self.conversation:last_message() }, model:name())
  self.assistant_extmark = self.canvas:render_assistant_header(model:name())
  vim.bo[self.buf].modifiable = true
  self.canvas:clear_progress()
  winbar.update_status(self.buf, nil)
  return true
end

function ChatStrategy:on_round_start()
  if not self:buf_is_loaded() then
    return false
  end

  local context_manager = require("sia.context_manager")
  context_manager.prune_if_needed(self.conversation, {
    on_complete = function(pruned, compacted)
      if compacted and self:buf_is_loaded() then
        winbar.update_status(self.buf, nil)
        self:redraw()
      end
      winbar.update_context_budget(
        self.buf,
        context_manager.get_budget(self.conversation)
      )
    end,
    on_status = function(message)
      if self:buf_is_loaded() then
        winbar.update_status(self.buf, {
          message = message,
          status = "info",
        })
      end
    end,
  })

  self.canvas:update_assistant_extmark(
    self.assistant_extmark,
    { model = self.conversation.model:name() }
  )
end

function ChatStrategy:on_error()
  if not self:buf_is_loaded() then
    return
  end
  winbar.update_status(self.buf, { message = "Internal error", status = "error" })
end

function ChatStrategy:on_stream_start()
  if not self:buf_is_loaded() then
    return false
  end
  self:set_abort_keymap(self.buf)
  self.writer = StreamRenderer:new({
    canvas = self.canvas,
    line = vim.api.nvim_buf_line_count(self.buf) - 1,
    column = 0,
    temporary = false,
  })
  return true
end

function ChatStrategy:on_content(input)
  if not self:buf_is_loaded() then
    return false
  end
  if input.content then
    self.writer:append(input.content)
  end
  if input.reasoning then
    local content = input.reasoning.content
    local first_line = content:match("^([^\n]*)")
    local header = first_line and first_line:match("^%*%*(.*)%*%*$")

    if header then
      winbar.update_status(self.buf, { message = header })
    else
      self.writer:append(content, true)
    end
  end
  if input.tool_calls then
    self.pending_tools = input.tool_calls
  end
  return true
end

function ChatStrategy:on_tools()
  if not self:buf_is_loaded() then
    return false
  end
  return true
end

function ChatStrategy:get_win()
  return vim.fn.bufwinid(self.buf)
end

function ChatStrategy:on_cancel()
  if not self:buf_is_loaded() then
    return false
  end
  winbar.update_status(self.buf, {
    message = "Operation cancelled",
    status = "warning",
  })
end

function ChatStrategy:on_complete(control)
  if not self.writer then
    if not self:buf_is_loaded() then
      control.finish()
      return
    end
    self:del_abort_keymap(self.buf)
    self.canvas:clear_progress()
    winbar.update_status(self.buf, {
      message = "No response received from model",
      status = "error",
    })
    vim.bo[self.buf].modifiable = false
    control.finish()
    return
  end

  if not self:buf_is_loaded() then
    control.finish()
    return
  end

  self.canvas:scroll_to_bottom()
  local handle_cleanup = function()
    self.writer = nil
    if not self:buf_is_loaded() then
      control.finish()
      return
    end

    self:del_abort_keymap(self.buf)
    self.canvas:clear_temporary_text()
    self.canvas:clear_progress()
    winbar.update_status(self.buf, nil)
    if control.usage then
      self.canvas:update_assistant_extmark(self.assistant_extmark, {
        usage = control.usage,
        model = self.conversation.model:name(),
        status_text = control.turn_id:sub(1, 5),
      })
    end
    vim.bo[self.buf].modifiable = false

    local has_flushed = self:flush_queued_instructions()
    if has_flushed then
      self.assistant_extmark =
        self.canvas:render_assistant_header(self.conversation.model:name())
      control.continue_execution()
      return
    end

    if not self.has_generated_name then
      local fast_model =
        require("sia.model").resolve(require("sia.config").options.settings.fast_model)
      local name_conv = require("sia.conversation").Conversation:new({
        model = fast_model,
        temporary = true,
      })
      name_conv:add_instruction({
        { role = "system", content = SUMMARIZE_PROMPT },
        {
          role = "user",
          content = table.concat(
            vim.api.nvim_buf_get_lines(self.buf, 0, -1, true),
            "\n"
          ),
        },
      })
      require("sia.assistant").fetch_response(name_conv, function(resp)
        if resp then
          self.conversation.name = resp:lower():gsub("%s+", "-")
          pcall(
            vim.api.nvim_buf_set_name,
            self.buf,
            "*sia " .. self.conversation.name .. "*"
          )
        end
        self.has_generated_name = true
        control.finish()
      end)
    else
      control.finish()
    end
  end

  self:execute_tools({
    cancellable = self.cancellable,
    turn_id = control.turn_id,
    handle_status_updates = function(statuses)
      --- @type sia.WinbarToolStatus[]
      local tool_statuses = {}
      for _, s in ipairs(statuses) do
        table.insert(tool_statuses, {
          name = s.tool.name,
          message = s.tool.message,
          status = s.status,
        })
      end
      winbar.update_tool_status(self.buf, tool_statuses)
    end,
    handle_tools_completion = function(opts)
      winbar.update_tool_status(self.buf, nil)
      if opts.results then
        for _, tool_result in ipairs(opts.results) do
          if tool_result.result.display_content then
            self.writer:append_newline_if_needed()
            local line = self.writer.line
            self.writer:append(tool_result.result.display_content)
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
              display_content = tool_result.result.display_content,
              ephemeral = tool_result.result.kind == "failed"
                or tool_result.result.ephemeral,
            },
          }, tool_result.result.context, { turn_id = control.turn_id })
          self.writer:append_newline_if_needed()
        end
      end

      if opts.cancelled then
        self:confirm_continue_after_cancelled_tool({
          continue_execution = function()
            local has_flushed = self:flush_queued_instructions()
            if has_flushed then
              self.assistant_extmark =
                self.canvas:render_assistant_header(self.conversation.model:name())
            end
            control.continue_execution()
          end,
          finish = function()
            handle_cleanup()
            winbar.update_status(
              self.buf,
              { message = "Paused by user", status = "info" }
            )
          end,
        })
      else
        local has_flushed = self:flush_queued_instructions()
        if has_flushed then
          self.assistant_extmark =
            self.canvas:render_assistant_header(self.conversation.model:name())
        end
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

  winbar.detach(buf)
  strategy.conversation:destroy()
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
