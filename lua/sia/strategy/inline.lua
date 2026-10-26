local common = require("sia.strategy.common")
local activity = require("sia.activity")

local NS = vim.api.nvim_create_namespace("sia_inline_activity")

--- @class sia.InlineStrategy : sia.Strategy
--- @field activity sia.Activity
local InlineStrategy = setmetatable({}, { __index = common.Strategy })
InlineStrategy.__index = InlineStrategy

function InlineStrategy:start_activity(buf, line, message)
  self.activity = activity.new()
  self.activity_buf = buf
  self.activity_line = line
  self.initial_message = message
  self:render_activity()
end

function InlineStrategy:render_activity(message, highlight)
  local buf = self.activity_buf
  if not buf or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  local text = message or self.activity.message
  if not message and self.activity.total > 0 then
    text = text
      .. string.format(
        " · %d/%d tools complete",
        self.activity.completed,
        self.activity.total
      )
  end
  local lines = { { { "⠋ " .. text:gsub("\n", " "), highlight or "SiaProgress" } } }
  if not message and self.activity.last_completed then
    table.insert(
      lines,
      { { "  ✓ " .. self.activity.last_completed:gsub("\n", " "), "Comment" } }
    )
  end
  self.activity_mark = vim.api.nvim_buf_set_extmark(buf, NS, self.activity_line, 0, {
    id = self.activity_mark,
    virt_lines = lines,
    virt_lines_above = true,
    right_gravity = false,
  })
end

function InlineStrategy:on_round_start()
  activity.round(self.activity)
  -- Tool rounds may contain prose rather than replacement text. Never carry
  -- their preview into the next round or append tool summaries to it.
  if self.writer then
    self.writer.canvas:clear_temporary_text()
    self.writer.temporary_line = self.writer.start_line
    self.writer.temporary_column = self.writer.start_col
  end
  self:render_activity(
    self.initial_message and self.initial_message[1],
    self.initial_message and self.initial_message[2]
  )
  self.initial_message = nil
end

function InlineStrategy:on_tools()
  self.activity.message = "Preparing tools…"
  self:render_activity()
  return true
end

function InlineStrategy:on_tool_status(statuses)
  activity.tools(self.activity, statuses)
  self:render_activity()
end

function InlineStrategy:on_tool_results(statuses)
  self:on_tool_status(statuses)
end

function InlineStrategy:on_status(message, severity)
  local highlights = { warning = "DiagnosticWarn", error = "DiagnosticError" }
  self:render_activity(message, highlights[severity])
end

function InlineStrategy:on_stream(input)
  if not self:buf_is_loaded() then
    return false
  end
  activity.stream(self.activity, input)
  self:render_activity()
  if input.content then
    self.writer:append(input.content)
  end
  return true
end

function InlineStrategy:clear_activity()
  if self.activity_buf and vim.api.nvim_buf_is_loaded(self.activity_buf) then
    vim.api.nvim_buf_clear_namespace(self.activity_buf, NS, 0, -1)
  end
  self.activity_mark = nil
  if self.writer and vim.api.nvim_buf_is_loaded(self.writer.canvas.buf) then
    self.writer.canvas:clear_temporary_text()
  end
end

return InlineStrategy
