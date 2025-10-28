local common = require("sia.strategy.common")

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
        { { "🤖 ", "Normal" }, { "Analyzing your request...", "SiaProgress" } },
      },
      virt_lines_above = context.pos[1] - 1 > 0,
      hl_group = "SiaInsert",
      end_line = context.pos[2],
    })
  else
    vim.api.nvim_echo(
      { { "🤖 Analyzing your request...", "SiaProgress" } },
      false,
      {}
    )
  end
  return true
end

function HiddenStrategy:on_tools()
  vim.api.nvim_echo({ { "🤖 Preparing to use tools...", "SiaProgress" } }, false, {})
  return true
end

function HiddenStrategy:on_content(input)
  if input.tool_calls then
    self.pending_tools = input.tool_calls
  end
  return true
end

function HiddenStrategy:on_error()
  local context = self.conversation.context
  self._options.callback(context, nil)
end

function HiddenStrategy:on_complete(control)
  local context = self.conversation.context

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
      vim.api.nvim_echo(
        { { "🤖 Analyzing your request...", "SiaProgress" } },
        false,
        {}
      )
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
        control.finish()
        self._options.callback(context, nil)
      else
        control.continue_execution()
      end
    end,
    handle_empty_toolset = function()
      if context then
        vim.api.nvim_buf_clear_namespace(context.buf, HIDDEN_NS, 0, -1)
      end
      self._options.callback(context, control.content)
      self.conversation:untrack_messages()
      vim.api.nvim_echo({ { "🤖 Completed request!", "SiaProgress" } }, false, {})
      vim.defer_fn(function()
        vim.cmd.echo()
      end, 500)
      control.finish()
    end,
  })
end

function HiddenStrategy:on_cancel()
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
