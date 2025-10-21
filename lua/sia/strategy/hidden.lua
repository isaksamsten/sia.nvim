local common = require("sia.strategy.common")

local StreamRenderer = common.StreamRenderer
local Strategy = common.Strategy

local HIDDEN_NS = vim.api.nvim_create_namespace("SiaHiddenStrategy")

--- @class sia.HiddenStrategy : sia.Strategy
--- @field conversation sia.Conversation
--- @field private _options sia.config.Hidden
--- @field private _writer sia.StreamRenderer?
local HiddenStrategy = setmetatable({}, { __index = Strategy })
HiddenStrategy.__index = HiddenStrategy

--- @param conversation sia.Conversation
--- @param options sia.config.Hidden
--- @param cancellable sia.Cancellable?
function HiddenStrategy:new(conversation, options, cancellable)
  local obj = setmetatable(Strategy:new(conversation, cancellable), self)
  obj._options = options
  obj._writer = nil
  return obj
end

function HiddenStrategy:on_request_start()
  local context = self.conversation.context
  if context then
    vim.api.nvim_buf_clear_namespace(context.buf, HIDDEN_NS, 0, -1)
    vim.api.nvim_buf_set_extmark(context.buf, HIDDEN_NS, context.pos[1] - 1, 0, {
      virt_lines = {
        { { "🤖 ", "Normal" }, { "Processing in background...", "SiaProgress" } },
      },
      virt_lines_above = context.pos[1] - 1 > 0,
      hl_group = "SiaInsert",
      end_line = context.pos[2],
    })
  else
    vim.api.nvim_echo(
      { { "🤖 Processing in background...", "SiaProgress" } },
      false,
      {}
    )
  end
end

function HiddenStrategy:on_stream_started()
  local context = self.conversation.context
  if context then
    self:set_abort_keymap(context.buf)
  end
  self._writer = StreamRenderer:new()
  return true
end

function HiddenStrategy:on_error()
  local context = self.conversation.context
  if context then
    vim.api.nvim_buf_clear_namespace(context.buf, HIDDEN_NS, 0, -1)
    self:del_abort_keymap(context.buf)
  end
  self._options.callback(context, { "The operation failed" })
end

function HiddenStrategy:on_content_received(input)
  if input.content then
    self._writer:append(input.content)
  end
end

function HiddenStrategy:on_completed(control)
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
          vim.api.nvim_buf_clear_namespace(context.buf, HIDDEN_NS, 0, -1)
          vim.api.nvim_buf_set_extmark(context.buf, HIDDEN_NS, context.pos[1] - 1, 0, {
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

      if opts.cancelled then
        self:confirm_continue_after_cancelled_tool(control)
      else
        control.continue_execution()
      end
    end,
    handle_empty_toolset = function()
      if context then
        self:del_abort_keymap(context.buf)
        vim.api.nvim_buf_clear_namespace(context.buf, HIDDEN_NS, 0, -1)
      end
      local messages = self.conversation:get_messages({
        filter = function(message)
          return message.role == "assistant" and message.kind == "<assistant-callback>"
        end,
      })
      local content = require("sia.conversation").Message.merge_content(messages)
      self._options.callback(context, content)
      if not content then
        vim.api.nvim_echo({ { "Sia: No response received", "Error" } }, false, {})
      end
      self.conversation:untrack_messages()
      control.finish()
    end,
  })
end

function HiddenStrategy:on_cancelled()
  local context = self.conversation.context
  if context then
    vim.api.nvim_buf_clear_namespace(context.buf, HIDDEN_NS, 0, -1)
    self:del_abort_keymap(context.buf)
  end
  self._options.callback(
    self.conversation.context,
    { "Operation was cancelled by user" }
  )
  vim.api.nvim_echo({ { "Sia: Operation cancelled", "DiagnosticWarn" } }, false, {})
end

return HiddenStrategy
