local common = require("sia.strategy.common")

local Strategy = common.Strategy

--- @class sia.HiddenStrategy : sia.Strategy
--- @field conversation sia.Conversation
--- @field private options sia.config.Hidden
local HiddenStrategy = setmetatable({}, { __index = Strategy })
HiddenStrategy.__index = HiddenStrategy

--- @param conversation sia.Conversation
--- @param options sia.config.Hidden
--- @param cancellable sia.Cancellable?
function HiddenStrategy:new(conversation, options, cancellable)
  local obj = setmetatable(Strategy:new(conversation, cancellable), self)
  obj.options = options
  return obj
end

local function default_notify(msg)
  vim.api.nvim_echo({ { "🤖 " .. msg, "SiaProgress" } }, false, {})
end

function HiddenStrategy:on_request_start()
  local notify = self.options.notify or default_notify
  notify("Analyzing your request...")
  return true
end

function HiddenStrategy:on_tools()
  local notify = self.options.notify or default_notify
  notify("Preparing to use tools...")
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
  self.options.callback(context, nil)
end

function HiddenStrategy:on_complete(control)
  local context = self.conversation.context

  local notify = self.options.notify or default_notify
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
        notify(message)
      end
    end,
    handle_tools_completion = function(opts)
      notify("Analyzing your request...")
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
        self.options.callback(context, nil)
      else
        control.continue_execution()
      end
    end,
    handle_empty_toolset = function()
      self.options.callback(context, control.content)
      self.conversation:untrack_messages()
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
    self:del_abort_keymap(context.buf)
  end
  self.options.callback(
    self.conversation.context,
    { "Operation was cancelled by user" }
  )
  vim.api.nvim_echo({ { "Sia: Operation cancelled", "DiagnosticWarn" } }, false, {})
end

return HiddenStrategy
