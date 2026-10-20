local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local activity = require("sia.activity")

T["parallel tools transition to waiting without stale descriptions"] = function()
  local state = activity.new()
  local statuses = {
    { name = "view", status = "running", activity = { header = "Reading chat.lua" } },
    { name = "grep", status = "running", activity = "Searching handlers" },
    { name = "view", status = "pending" },
  }
  activity.tools(state, statuses)
  eq(state.message, "Reading chat.lua (+1 running)")
  eq(state.running, 2)
  eq(state.total, 3)
  statuses[1].status = "done"
  statuses[1].summary = { header = "Read chat.lua" }
  activity.tools(state, statuses)
  eq(state.message, "Searching handlers")
  eq(state.completed, 1)
  eq(state.last_completed, "Read chat.lua")
  statuses[2].status = "done"
  statuses[3].status = "done"
  activity.tools(state, statuses)
  eq(state.message, "Waiting for model…")
  eq(state.phase, "waiting")
  eq(state.running, 0)
end

T["stream reports phases and bounds unicode response preview"] = function()
  local state = activity.new()
  activity.stream(state, { reasoning = { content = "private reasoning" } })
  eq(state.message, "Reasoning…")
  eq(state.response, "")
  activity.stream(state, { content = string.rep("å", 1100) })
  eq(state.message, "Writing response…")
  eq(state.response, string.rep("å", 1000))
  activity.stream(state, { content = "done" })
  eq(vim.fn.strchars(state.response), 1000)
  eq(state.response:sub(-4), "done")
end

T["hidden strategy notifies completion and resets each model round"] = function()
  local messages = {}
  local strategy = require("sia.strategy.hidden").new(nil, {}, {
    notify = function(message)
      table.insert(messages, message)
    end,
  })
  strategy:on_request_start()
  strategy:on_round_start()
  strategy:on_tool_status({
    { name = "view", status = "running", activity = { header = "Reading file" } },
  })
  eq(messages[#messages], "Reading file")
  strategy:on_tool_status({ { name = "view", status = "done" } })
  eq(messages[#messages], "Waiting for model…")
  strategy:on_stream({ content = "Partial response" })
  eq(messages[#messages], "Writing response…")
  strategy:on_round_start()
  eq(messages[#messages], "Waiting for model…")
  eq(strategy.activity.response, "")
end

T["chat activity is transient and cleared on cancellation"] = function()
  local Chat = require("sia.strategy.chat")
  local buf = vim.api.nvim_create_buf(false, true)
  local canvas = require("sia.canvas").Canvas:new(buf)
  local chat = setmetatable({
    buf = buf,
    canvas = canvas,
    activity = activity.new(),
    hooks = {},
    conversation = { clear_pending_user_messages = function() end },
  }, { __index = Chat })
  chat:on_tool_status({
    { name = "view", status = "running", activity = "Reading file" },
  })
  local ns = vim.api.nvim_get_namespaces().sia_chat_progress
  local function message()
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    return marks[1][4].virt_lines[1][1][1]
  end
  eq(message(), "⠋ Reading file · 0/1 tools complete")
  chat:on_tool_status({ { name = "view", status = "done" } })
  eq(message(), "⠋ Waiting for model…")
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "" })
  chat:on_cancel()
  eq(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}), {})
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["last completed follows completion order rather than tool order"] = function()
  local state = activity.new()
  local statuses = {
    { key = "a", name = "A", status = "running" },
    { key = "b", name = "B", status = "done" },
  }
  activity.tools(state, statuses)
  eq(state.last_completed, "B")
  statuses[1].status = "done"
  activity.tools(state, statuses)
  eq(state.last_completed, "A")
end

T["progress namespace does not remove transcript marks"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  local canvas = require("sia.canvas").Canvas:new(buf)
  local ns = vim.api.nvim_create_namespace("sia_chat")
  local id = vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {})
  canvas:mark_assistant_text(0)
  canvas:update_tool_progress({ { { "Running", "SiaProgress" } } })
  canvas:clear_progress()
  eq(vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, {}), { 0, 0 })
  local assistant_ns = vim.api.nvim_get_namespaces().sia_chat_assistant_text
  eq(#vim.api.nvim_buf_get_extmarks(buf, assistant_ns, 0, -1, {}), 1)
  canvas:update_tool_progress({ { { "Running", "SiaProgress" } } })
  canvas:clear()
  canvas:append_text_at(0, 0, "Still works")
  eq(canvas.progress_extmark, nil)
  vim.api.nvim_buf_delete(buf, { force = true })
end

return T

