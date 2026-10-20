local common = require("sia.strategy.common")
local icons = require("sia.ui").icons
local activity = require("sia.activity")

local Strategy = common.Strategy

--- @class sia.HiddenStrategy : sia.Strategy
--- @field buf number?
--- @field conversation sia.Conversation
--- @field private options sia.config.Hidden
--- @field activity sia.Activity
--- @field private last_activity_message string?
local HiddenStrategy = setmetatable({}, { __index = Strategy })
HiddenStrategy.__index = HiddenStrategy

--- @param buf number?
--- @param conversation sia.Conversation
--- @param options sia.config.Hidden
--- @param cancellable sia.Cancellable?
--- @return sia.HiddenStrategy
function HiddenStrategy.new(buf, conversation, options, cancellable)
  local obj = setmetatable(Strategy.new(conversation, cancellable), HiddenStrategy)
  obj.buf = buf
  obj.options = options
  obj.activity = activity.new()
  return obj --[[@as sia.HiddenStrategy]]
end

--- @param content string
function HiddenStrategy:submit(content)
  if self.is_busy then
    self.conversation:add_pending_user_message(content)
  else
    self.conversation:add_user_message(content)
    require("sia.assistant").execute_strategy(self)
  end
end

local function default_notify(msg)
  vim.api.nvim_echo({ { icons.agents .. " " .. msg, "SiaProgress" } }, false, {})
end

function HiddenStrategy:_notify_activity()
  if self.last_activity_message == self.activity.message then
    return
  end
  self.last_activity_message = self.activity.message
  local notify = self.options.notify or default_notify
  notify(self.activity.message)
end

function HiddenStrategy:on_request_start()
  self.activity = activity.new()
  self.last_activity_message = nil
  return true
end

function HiddenStrategy:on_round_start()
  activity.round(self.activity)
  self:_notify_activity()
end

function HiddenStrategy:on_tools()
  return true
end

--- @param input sia.StreamDelta
function HiddenStrategy:on_stream(input)
  activity.stream(self.activity, input)
  self:_notify_activity()
  return true
end

function HiddenStrategy:on_error(error)
  self.options.callback(self.buf, { error = error or "Internal error" })
end

--- @param statuses sia.engine.Status[]
function HiddenStrategy:on_tool_status(statuses)
  activity.tools(self.activity, statuses)
  self:_notify_activity()
end

function HiddenStrategy:on_request_end()
  self.conversation:attach_pending_user_messages()
end

function HiddenStrategy:on_round_end()
  self.conversation:attach_pending_user_messages()
end

--- @param ctx sia.FinishContext
function HiddenStrategy:on_finish(ctx)
  self.options.callback(self.buf, {
    content = ctx.content and vim.split(ctx.content, "\n") or nil,
    usage = ctx.usage,
  })
  self.conversation:untrack_messages()
end

function HiddenStrategy:on_cancel()
  if self.buf then
    self:del_abort_keymap(self.buf)
  end
  self.options.callback(self.buf, {})
  vim.api.nvim_echo({ { "sia: cancelled", "DiagnosticWarn" } }, false, {})
end

return HiddenStrategy
