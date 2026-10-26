local Insert = require("sia.strategy.insert")
local Diff = require("sia.strategy.diff")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local buffers = {}

local function buffer(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  table.insert(buffers, buf)
  return buf
end

local function conversation()
  return { add_user_message = function() end, untrack_messages = function() end }
end

local function progress(buf)
  local ns = vim.api.nvim_get_namespaces().sia_inline_activity
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  return marks[1] and marks[1][4].virt_lines or {}
end

T = MiniTest.new_set({
  hooks = {
    post_case = function()
      vim.cmd("silent! diffoff!")
      vim.cmd("silent! only!")
      for _, buf in ipairs(buffers) do
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end
      buffers = {}
    end,
  },
})

T["insert separates activity, tools and code across rounds"] = function()
  local buf = buffer({ "before", "after" })
  local strategy = Insert.new(
    buf,
    { 1, 1 },
    { 1, 0 },
    conversation(),
    { placement = { "below", "end" } }
  )
  eq(true, strategy:on_request_start())
  strategy:on_round_start()
  eq("⠋ Waiting for model…", progress(buf)[1][1][1])
  strategy:on_stream({ reasoning = { content = "thinking" } })
  eq("⠋ Reasoning…", progress(buf)[1][1][1])
  strategy:on_stream({ content = "intermediate prose" })
  local statuses = {
    {
      key = "one",
      name = "view",
      status = "running",
      activity = { header = "Reading file" },
    },
  }
  strategy:on_tool_status(statuses)
  eq("⠋ Reading file · 0/1 tools complete", progress(buf)[1][1][1])
  statuses[1].status = "done"
  statuses[1].summary = { header = "Read file", details = "detail" }
  strategy:on_tool_results(statuses)
  eq({ "intermediate prose" }, strategy.writer.canvas.temporary_content)
  strategy:on_round_start()
  eq({}, strategy.writer.canvas.temporary_content)
  strategy:on_stream({ content = "replacement" })
  eq({ "replacement" }, strategy.writer.canvas.temporary_content)
  eq({ "before", "after" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  strategy:on_finish({ content = "replacement" })
  eq(
    { "before", "replacement", "after" },
    vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  )
  eq({}, progress(buf))
end

T["insert cancellation and early errors clean up safely"] = function()
  local buf = buffer({ "original" })
  local strategy = Insert.new(
    buf,
    { 1, 1 },
    { 1, 0 },
    conversation(),
    { placement = "end" }
  )
  strategy:on_error()
  strategy:on_request_start()
  strategy:on_round_start()
  strategy:on_stream({ content = "discard" })
  strategy:on_cancel()
  eq({}, progress(buf))
  eq({}, strategy.writer.canvas.temporary_content)
  eq({ "original" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  eq({}, vim.api.nvim_buf_get_keymap(buf, "n"))
end

T["diff preserves surrounding lines and restores source on completion"] = function()
  local buf = buffer({ "before", "old", "after" })
  vim.api.nvim_win_set_buf(0, buf)
  local strategy = Diff.new(
    buf,
    vim.api.nvim_get_current_win(),
    { 2, 2 },
    conversation(),
    { cmd = "vnew", wo = {} }
  )
  table.insert(buffers, strategy.target_buf)
  strategy:on_request_start()
  strategy:on_round_start()
  strategy:on_stream({ content = "new\ncode" })
  strategy:on_finish({ content = "new\ncode" })
  eq(
    { "before", "new", "code", "after" },
    vim.api.nvim_buf_get_lines(strategy.target_buf, 0, -1, false)
  )
  eq(true, vim.bo[buf].modifiable)
  eq({}, progress(strategy.target_buf))
end

T["diff cancellation restores modifiability and removes preview"] = function()
  local buf = buffer({ "original" })
  vim.api.nvim_win_set_buf(0, buf)
  local strategy = Diff.new(
    buf,
    vim.api.nvim_get_current_win(),
    { 1, 1 },
    conversation(),
    { cmd = "vnew", wo = {} }
  )
  table.insert(buffers, strategy.target_buf)
  strategy:on_request_start()
  strategy:on_round_start()
  strategy:on_stream({ content = "discard" })
  strategy:on_cancel()
  eq(true, vim.bo[buf].modifiable)
  eq({}, strategy.writer.canvas.temporary_content)
  eq({}, progress(strategy.target_buf))
end

return T
