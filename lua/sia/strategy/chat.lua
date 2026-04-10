local common = require("sia.strategy.common")
local winbar = require("sia.ui.winbar")

local StreamRenderer = common.StreamRenderer
local Strategy = common.Strategy
local TOOL_RENDER_NS = vim.api.nvim_create_namespace("sia_chat_inline_tools")

local SUMMARIZE_PROMPT = [[Summarize the interaction. Make it suitable for a
buffer name in neovim using three to five words separated by
spaces. Only output the name, nothing else.]]

--- @class sia.chat.AssistantTurnRenderer
--- @field canvas sia.Canvas
--- @field buf integer
--- @field content_writer sia.StreamRenderer
--- @field reasoning_writer sia.StreamRenderer?
--- @field tool_status table<string, boolean>
--- @field tool_order string[]
--- @field tool_block_extmark integer?
--- @field tool_block_line_count integer
--- @field has_tool_blocks boolean
local AssistantTurnRenderer = {}
AssistantTurnRenderer.__index = AssistantTurnRenderer

--- @class sia.chat.ToolRenderState
--- @field key string
--- @field index integer?
--- @field status "pending"|"running"|"done"
--- @field header string?
--- @field details string?
--- @field name string?

--- @param opts { canvas: sia.Canvas, buf: integer, line: integer }
--- @return sia.chat.AssistantTurnRenderer
function AssistantTurnRenderer.new(opts)
  local obj = {
    canvas = opts.canvas,
    buf = opts.buf,
    content_writer = StreamRenderer:new({
      canvas = opts.canvas,
      line = opts.line,
      column = 0,
      temporary = false,
    }),
    reasoning_writer = nil,
    tool_status = {},
    tool_order = {},
    tool_block_extmark = nil,
    tool_block_line_count = 0,
    has_tool_blocks = false,
  }
  return setmetatable(obj, AssistantTurnRenderer)
end

--- @return sia.StreamRenderer
function AssistantTurnRenderer:_ensure_reasoning_writer()
  if self.reasoning_writer then
    return self.reasoning_writer
  end

  local insert_at = self.content_writer.start_line
  local current_line =
    vim.api.nvim_buf_get_lines(self.buf, insert_at, insert_at + 1, false)[1]
  local reuse_placeholder = self.content_writer:is_empty() and current_line == ""

  if reuse_placeholder then
    self.canvas:append_text_at(insert_at, 0, ">| ")
    self.canvas:insert_lines_at(insert_at + 1, { "", "" })
  else
    self.canvas:insert_lines_at(insert_at, { ">| ", "", "" })
  end

  self.content_writer:shift(2)
  self.reasoning_writer = StreamRenderer:new({
    canvas = self.canvas,
    line = insert_at,
    column = 3,
    temporary = false,
  })
  return self.reasoning_writer
end

--- @param content string
function AssistantTurnRenderer:append_content(content)
  if content == "" then
    return
  end
  -- Strip leading newlines before any content has been written to avoid
  -- a blank line at the top of the response (e.g. when the first delta is "\n")
  if self.content_writer:is_empty() then
    content = content:gsub("^\n+", "")
    if content == "" then
      return
    end
  end
  self.content_writer:append(content)
end

--- @param content string
function AssistantTurnRenderer:append_reasoning(content)
  if content == "" then
    return
  end

  local writer = self:_ensure_reasoning_writer()
  local index = 1
  while index <= #content do
    local newline = content:find("\n", index, true)
    local substring = newline and content:sub(index, newline - 1) or content:sub(index)
    if #substring > 0 then
      writer:append_substring(substring)
    end

    if newline then
      writer:append_newline()
      self.content_writer:shift(1)
      writer:append_substring(">| ")
    end

    index = (newline or #content) + 1
  end
end

--- @param key string
function AssistantTurnRenderer:ensure_order(key)
  local render = self.tool_status[key]
  if render then
    return
  end

  self.tool_status[key] = true
  table.insert(self.tool_order, key)
  return render
end

function AssistantTurnRenderer:_render_tool_block() end

--- @param statuses sia.engine.Status[]
function AssistantTurnRenderer:update_tool_blocks(statuses)
  local keyed_statuses = {}
  for _, status in ipairs(statuses) do
    self:ensure_order(status.key)
    keyed_statuses[status.key] = status
  end

  if not self.tool_block_extmark then
    self.content_writer:append_newline_if_needed()
    local line = self.content_writer.line
    local current_line = vim.api.nvim_buf_get_lines(self.buf, line, line + 1, false)[1]
    local reuses_placeholder = current_line == ""
    self.tool_block_extmark =
      vim.api.nvim_buf_set_extmark(self.buf, TOOL_RENDER_NS, line, 0, {
        right_gravity = false,
      })
    self.tool_block_line_count = reuses_placeholder and 1 or 0
    self.has_tool_blocks = true
  end

  local position = vim.api.nvim_buf_get_extmark_by_id(
    self.buf,
    TOOL_RENDER_NS,
    self.tool_block_extmark,
    {}
  )
  self.tool_block_line_count = self.canvas:update_tool_block(
    position,
    self.tool_block_line_count,
    keyed_statuses,
    self.tool_order
  )
end

function AssistantTurnRenderer:finalize()
  if
    self.reasoning_writer
    and self.content_writer:is_empty()
    and not self.has_tool_blocks
  then
    self.canvas:remove_line_at(self.content_writer.line)
  end
end

--- @class sia.Cancellable
--- @field is_cancelled boolean

--- @class sia.chat.Hooks
--- @field on_cancel fun()?
--- @field on_error fun()?
--- @field on_finish fun()?
--- @field on_close fun()?

--- Create a new chat window.
--- @class sia.ChatStrategy : sia.Strategy
--- @field buf integer the split view buffer
--- @field options sia.config.Chat options for the chat
--- @field canvas sia.Canvas the canvas used to draw the conversation
--- @field total_tokens integer?
--- @field next_mode sia.chat.Submit?
--- @field private assistant_extmark integer?
--- @field private has_generated_name boolean
--- @field private turn_renderer sia.chat.AssistantTurnRenderer?
--- @field private hooks sia.chat.Hooks
local ChatStrategy = setmetatable({}, { __index = Strategy })
ChatStrategy.__index = ChatStrategy

--- @type table<integer, sia.ChatStrategy>
ChatStrategy._buffers = {}

--- @type table<integer, integer>
ChatStrategy._order = {}

--- @class sia.chat.NewChatOpts
--- @field render_all boolean?
--- @field destroy boolean?
--- @field hooks sia.chat.Hooks?

--- @param conversation sia.Conversation
--- @param options sia.config.Chat
--- @param opts sia.chat.NewChatOpts?
--- @return sia.ChatStrategy
function ChatStrategy.new(conversation, options, opts)
  opts = opts or {}
  vim.cmd(options.cmd)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_buf(win, buf)

  vim.bo[buf].buftype = "nowrite"
  vim.bo[buf].ft = "sia"

  if options.wo then
    for wo, value in pairs(options.wo) do
      vim.wo[win][wo] = value
    end
  end
  local obj = setmetatable(Strategy.new(conversation), ChatStrategy)
  obj.buf = buf
  obj.turn_renderer = nil
  obj.options = options
  obj.hooks = opts.hooks or {}

  --- @cast obj sia.ChatStrategy
  ChatStrategy._buffers[obj.buf] = obj
  ChatStrategy._order[#ChatStrategy._order + 1] = obj.buf

  obj.conversation.name = tostring(ChatStrategy.count())
  pcall(vim.api.nvim_buf_set_name, buf, "*sia " .. obj.conversation.name .. "*")
  obj.canvas = require("sia.canvas").Canvas:new(obj.buf)
  local messages = conversation.entries
  if opts.render_all then
    obj.canvas:render_messages(messages, obj.conversation.model.name)
    obj.has_generated_name = true
  else
    obj.canvas:render_messages(
      vim.list_slice(messages, 1, #messages - 1),
      obj.conversation.model.name
    )
    obj.has_generated_name = false
  end
  obj.assistant_extmark = nil

  local augroup = vim.api.nvim_create_augroup("SiaChat" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = augroup,
    buffer = buf,
    once = true,
    callback = function(args)
      ChatStrategy.remove(args.buf, opts.destroy ~= false)
    end,
  })

  if options.winbar then
    winbar.attach(buf, conversation, obj)
  end

  return obj
end

--- @private
--- @param chat sia.ChatStrategy
--- @param mode string
local function enter_mode(chat, mode)
  if mode then
    local info = chat.conversation:enter_mode(mode)
    if info then
      if info.truncate_after_id then
        chat.conversation:drop_after(info.truncate_after_id)
        return true
      end

      if info.content then
        chat.conversation:add_user_message(info.content, nil, { hide = true })
      end
    end
  end
  return false
end
--- @class sia.chat.Submit
--- @field content string?
--- @field hidden_messages string[]?
--- @field mode string?

--- @param submit sia.chat.Submit
--- @return sia.conversation.PendingUserMessage[]
local function submit_to_messages(submit)
  local messages = {}
  for _, content in ipairs(submit.hidden_messages or {}) do
    table.insert(messages, {
      content = content,
      hide = true,
    })
  end
  if submit.content then
    table.insert(messages, { content = submit.content })
  end
  return messages
end

--- @param conversation sia.Conversation
--- @param messages sia.conversation.PendingUserMessage[]
local function append_user_messages(conversation, messages)
  for _, message in ipairs(messages) do
    conversation:add_user_message(
      message.content,
      message.region,
      { hide = message.hide }
    )
  end
end

--- @param submit sia.chat.Submit
function ChatStrategy:submit(submit)
  local messages = submit_to_messages(submit)

  -- While a request is running, queue mode changes for the next request but let
  -- plain user messages steer the current round as soon as tools finish.
  if self.is_busy then
    if #messages > 0 and not submit.mode then
      for _, message in ipairs(messages) do
        self.conversation:add_pending_user_message(
          message.content,
          message.region,
          message.hide
        )
      end
    elseif submit.mode and not self.next_mode then
      self.next_mode = {
        mode = submit.mode,
        hidden_messages = submit.hidden_messages,
        content = submit.content,
      }
    end
    return
  end

  local needs_redraw = enter_mode(self, submit.mode)
  if needs_redraw then
    self:redraw()
  end

  append_user_messages(self.conversation, messages)
  self.conversation:attach_completed_agents()
  require("sia.assistant").execute_strategy(self)
end

function ChatStrategy:buf_is_loaded()
  return vim.api.nvim_buf_is_loaded(self.buf)
end

function ChatStrategy:redraw()
  if not self:buf_is_loaded() then
    return
  end
  self.canvas:clear()
  self.canvas:render_messages(self.conversation.entries, self.conversation.model.name)
end

function ChatStrategy:on_request_end()
  self.conversation:attach_completed_agents()
  if not self.next_mode and not self.conversation:has_pending_user_messages() then
    return false
  end

  local redraw = false
  if self.next_mode then
    redraw = enter_mode(self, self.next_mode.mode)
    append_user_messages(self.conversation, submit_to_messages(self.next_mode))
  end

  if redraw then
    self:redraw()
  end

  local new_entries = self.conversation:attach_pending_user_messages()
  if new_entries and #new_entries > 1 then
    self.canvas:render_messages(
      vim.list_slice(new_entries, 1, #new_entries - 1),
      self.conversation.model.name
    )
  end
  self.next_mode = nil
  return true
end

function ChatStrategy:on_request_start()
  self.cancellable.is_cancelled = false
  if not self:buf_is_loaded() then
    return false
  end
  self.canvas:render_messages({
    self.conversation:get_last_entry(),
  }, self.conversation.model.name)
  self.assistant_extmark =
    self.canvas:render_assistant_header(self.conversation.model.name)
  vim.bo[self.buf].modifiable = true
  self.canvas:clear_progress()
  winbar.update_status(self.buf, nil)
  return true
end

function ChatStrategy:on_round_start()
  if not self:buf_is_loaded() then
    return false
  end

  self.canvas:update_assistant_extmark(
    self.assistant_extmark,
    { model = self.conversation.model.name }
  )
end

--- @param turn_id string
function ChatStrategy:on_round_end(turn_id)
  local new_entries = self.conversation:attach_pending_user_messages()
  if new_entries then
    self.canvas:render_messages(new_entries, self.conversation.model.name)
    self.canvas:render_assistant_header(self.conversation.model.name)
  end
end

--- @param message string
--- @param severity "info"|"warning"|"error"|nil
function ChatStrategy:on_status(message, severity)
  if not self:buf_is_loaded() then
    return
  end
  winbar.update_status(self.buf, {
    message = message,
    status = severity or "info",
  })
end

--- @param info { budget: table?, pruned: boolean, compacted: boolean }
function ChatStrategy:on_context_update(info)
  if not self:buf_is_loaded() then
    return
  end
  if info.compacted then
    winbar.clear_status(self.buf, 1000)
    self:redraw()
  end
  winbar.update_context_budget(self.buf, info.budget)
end

function ChatStrategy:on_error(error)
  if not self:buf_is_loaded() then
    return
  end
  winbar.update_status(
    self.buf,
    { message = error or "Internal error", status = "error" }
  )
  if self.hooks.on_error then
    self.hooks.on_error()
  end
end

function ChatStrategy:on_stream_start()
  if not self:buf_is_loaded() then
    return false
  end
  self:set_abort_keymap(self.buf)
  local last_line = vim.api.nvim_buf_line_count(self.buf) - 1
  local last_text =
    vim.api.nvim_buf_get_lines(self.buf, last_line, last_line + 1, false)[1]
  if last_text ~= "" then
    self.canvas:insert_lines_at(last_line + 1, { "", "" })
    last_line = last_line + 2
  end
  self.turn_renderer = AssistantTurnRenderer.new({
    canvas = self.canvas,
    buf = self.buf,
    line = last_line,
  })
  return true
end

--- @param input sia.StreamDelta
function ChatStrategy:on_stream(input)
  if not self:buf_is_loaded() then
    return false
  end
  if input.reasoning then
    local content = input.reasoning.content
    local first_line = content:match("^([^\n]*)")
    local header = first_line and first_line:match("^%*%*(.*)%*%*$")

    if header then
      winbar.update_status(self.buf, { message = header })
    end
    if content and content ~= "" and self.turn_renderer then
      self.turn_renderer:append_reasoning(content)
    end
  end
  if input.content and input.content ~= "" and self.turn_renderer then
    self.turn_renderer:append_content(input.content)
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
  self.next_mode = nil
  self.conversation:clear_pending_user_messages()
  winbar.update_status(self.buf, {
    message = "Operation cancelled",
    status = "warning",
  })
  if self.hooks.on_cancel then
    self.hooks.on_cancel()
  end
end

--- @param statuses sia.engine.Status[]
function ChatStrategy:on_tool_status(statuses)
  if not self:buf_is_loaded() then
    return
  end
  if self.turn_renderer then
    self.turn_renderer:update_tool_blocks(statuses)
  end
end

--- @param statuses sia.engine.Status[]
function ChatStrategy:on_tool_results(statuses)
  if not self:buf_is_loaded() then
    return
  end
  if self.turn_renderer then
    self.turn_renderer:update_tool_blocks(statuses)
  end

  local needs_redraw = false
  for _, status in ipairs(statuses) do
    if status.actions["drop_after"] then
      needs_redraw = true
      break
    end
  end

  if needs_redraw then
    if self.turn_renderer then
      self.turn_renderer:finalize()
      self.turn_renderer = nil
    end
    self:redraw()
    self.assistant_extmark =
      self.canvas:render_assistant_header(self.conversation.model.name)
  end
end

--- @param ctx sia.FinishContext
function ChatStrategy:on_finish(ctx)
  if not self.turn_renderer then
    if not self:buf_is_loaded() then
      return
    end
    self:del_abort_keymap(self.buf)
    self.canvas:clear_progress()
    winbar.update_status(self.buf, {
      message = "No response received from model",
      status = "error",
    })
    vim.bo[self.buf].modifiable = false
    return
  end

  if not self:buf_is_loaded() then
    return
  end

  self.canvas:scroll_to_bottom()

  -- Finalize the turn renderer
  if self.turn_renderer then
    self.turn_renderer:finalize()
  end
  self.turn_renderer = nil

  if not self:buf_is_loaded() then
    return
  end

  self:del_abort_keymap(self.buf)
  self.canvas:clear_temporary_text()
  self.canvas:clear_progress()
  winbar.update_status(self.buf, nil)
  if ctx.usage then
    self.canvas:update_assistant_extmark(self.assistant_extmark, {
      usage = ctx.usage,
      model = self.conversation.model.name,
      status_text = ctx.turn_id:sub(1, 5),
    })
  end
  vim.bo[self.buf].modifiable = false

  if not self.has_generated_name then
    local fast_model =
      require("sia.model").resolve(require("sia.config").options.settings.fast_model)
    local name_conv = require("sia.conversation").new({
      model = fast_model,
      temporary = true,
    })
    name_conv:add_system_message(SUMMARIZE_PROMPT)
    name_conv:add_user_message(
      table.concat(vim.api.nvim_buf_get_lines(self.buf, 0, -1, true), "\n")
    )
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
    end)
  end

  if self.hooks.on_finish then
    self.hooks.on_finish()
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
--- @param destroy_conversation boolean?
function ChatStrategy.remove(buf, destroy_conversation)
  local strategy = ChatStrategy._buffers[buf]
  if strategy == nil then
    return
  end

  winbar.detach(buf)
  if destroy_conversation then
    strategy.conversation:destroy()
  end
  if strategy.hooks.on_close then
    strategy.hooks.on_close()
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

return ChatStrategy
