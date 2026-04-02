local common = require("sia.strategy.common")
local winbar = require("sia.ui.winbar")

local StreamRenderer = common.StreamRenderer
local Strategy = common.Strategy

local SUMMARIZE_PROMPT = [[Summarize the interaction. Make it suitable for a
buffer name in neovim using three to five words separated by
spaces. Only output the name, nothing else.]]

--- @class sia.chat.AssistantTurnRenderer
--- @field canvas sia.Canvas
--- @field buf integer
--- @field content_writer sia.StreamRenderer
--- @field reasoning_writer sia.StreamRenderer?
local AssistantTurnRenderer = {}
AssistantTurnRenderer.__index = AssistantTurnRenderer

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

--- @param content string
function AssistantTurnRenderer:append_tool_result(content)
  self.content_writer:append_newline_if_needed()
  local line = self.content_writer.line
  self.content_writer:append(content)
  self.content_writer:append_newline()
  self.canvas:highlight_tool(line, self.content_writer.line)
  self.content_writer:append_newline_if_needed()
end

--- Clean up the layout after a turn is complete.
function AssistantTurnRenderer:finalize()
  if self.reasoning_writer and self.content_writer:is_empty() then
    self.canvas:remove_line_at(self.content_writer.line)
  end
end

--- @class sia.BaseToolCall
--- @field id string
--- @field call_id string?
--- @field name string

--- @class sia.FunctionCall : sia.BaseToolCall
--- @field type "function"
--- @field arguments string

--- @class sia.CustomCall : sia.BaseToolCall
--- @field type "custom"
--- @field input string

--- @alias sia.ToolCall sia.FunctionCall|sia.CustomCall

--- @class sia.Cancellable
--- @field is_cancelled boolean

--- Create a new chat window.
--- @class sia.ChatStrategy : sia.Strategy
--- @field buf integer the split view buffer
--- @field options sia.config.Chat options for the chat
--- @field canvas sia.Canvas the canvas used to draw the conversation
--- @field total_tokens integer?
--- @field queue sia.chat.Submit[]
--- @field private assistant_extmark integer?
--- @field private has_generated_name boolean
--- @field private turn_renderer sia.chat.AssistantTurnRenderer?
local ChatStrategy = setmetatable({}, { __index = Strategy })
ChatStrategy.__index = ChatStrategy

--- @type table<integer, sia.ChatStrategy>
ChatStrategy._buffers = {}

--- @type table<integer, integer>
ChatStrategy._order = {}

--- @param conversation sia.Conversation
--- @param options sia.config.Chat
--- @param opts { render_all: boolean? }?
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
  obj.queue = {}

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
      ChatStrategy.remove(args.buf)
    end,
  })

  if options.winbar then
    winbar.attach(buf, conversation, obj)
  end

  return obj
end

--- @class sia.chat.Submit
--- @field content string?
--- @field mode string?

--- @param submit sia.chat.Submit
function ChatStrategy:submit(submit)
  -- If the current chat is executing, enqueue the submission
  -- and realize it after the current turn.
  if self.is_busy then
    self:enqueue_submit(submit)
    return
  end

  local needs_redraw = false
  if submit.mode then
    local info = self.conversation:enter_mode(submit.mode)
    if info then
      if info.truncate_after_id then
        self.conversation:drop_after(info.truncate_after_id)
        needs_redraw = true
      end

      if info.content then
        self.conversation:add_user_message(info.content, nil, true)
      end
    end
  end

  if needs_redraw then
    self:redraw()
  end

  if submit.content then
    self.conversation:add_user_message(submit.content)
  end
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

--- @private
--- @param submit sia.chat.Submit
function ChatStrategy:enqueue_submit(submit)
  table.insert(self.queue, submit)
end

--- @return boolean flushed
function ChatStrategy:flush_queued_instructions()
  -- if #self.queue then
  --   return false
  -- end
  --
  -- for _, queued in ipairs(self.queue) do
  --   if queued.mode_entry then
  --     local info = self.conversation:enter_mode(queued.mode_entry.name, queued.context)
  --     if info and info.truncate_after_id then
  --       self.conversation:drop_after(info.truncate_after_id)
  --       for _, content in ipairs(info.content) do
  --         self.conversation:add_user_message(content)
  --       end
  --     end
  --     if queued.mode_entry.user_input and queued.mode_entry.user_input ~= "" then
  --       self.conversation:add_user_message(queued.mode_entry.user_input)
  --     end
  --   elseif queued.content then
  --     self.conversation:add_user_message(queued.content, queued.context)
  --   end
  -- end
  --
  -- if self:buf_is_loaded() then
  --   self:redraw()
  -- end
  --
  -- self.queue = {}
  -- return true
end

function ChatStrategy:on_request_start()
  self.cancellable.is_cancelled = false
  if not self:buf_is_loaded() then
    return false
  end
  local model = self.conversation.model
  self.canvas:render_messages({ self.conversation:get_last_entry() }, model.name)
  self.assistant_extmark = self.canvas:render_assistant_header(model.name)
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
  winbar.update_status(self.buf, {
    message = "Operation cancelled",
    status = "warning",
  })
end

--- @param statuses sia.engine.Status[]
function ChatStrategy:on_tool_status(statuses)
  if not self:buf_is_loaded() then
    return
  end
  --- @type sia.WinbarToolStatus[]
  local tool_statuses = {}
  for _, s in ipairs(statuses) do
    table.insert(tool_statuses, {
      name = s.name,
      message = s.notification,
      status = s.status,
    })
  end
  winbar.update_tool_status(self.buf, tool_statuses)
end

--- @param statuses sia.engine.Completed[]
function ChatStrategy:on_tool_results(statuses)
  if not self:buf_is_loaded() then
    return
  end
  winbar.update_tool_status(self.buf, nil)
  for _, status in ipairs(statuses) do
    if status.summary and self.turn_renderer then
      self.turn_renderer:append_tool_result(status.summary)
    end
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
    local name_conv = require("sia.conversation").new_conversation({
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
