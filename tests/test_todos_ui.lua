---@diagnostic disable: undefined-global
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local function reset_modules()
  package.loaded["sia.ui.todos"] = nil
  package.loaded["sia.ui.list"] = nil
end

local function make_conversation(id, items)
  return {
    id = id,
    name = string.format("**%d**", id),
    todos = {
      items = items or {},
    },
  }
end

local function visible_lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

T["todos ui"] = MiniTest.new_set({
  hooks = {
    pre_case = reset_modules,
  },
})

T["todos ui"]["refreshes existing buffer when todo items change"] = function()
  local todos = require("sia.ui.todos")
  local conv = make_conversation(301, {
    { id = 1, description = "Inspect todo UI", status = "active" },
  })

  local buf = todos._get_or_create_buf(conv)
  eq({ "  ▶ Inspect todo UI" }, visible_lines(buf))

  conv.todos.items = {
    { id = 1, description = "Inspect todo UI", status = "done" },
    { id = 2, description = "Add tests", status = "pending" },
  }

  todos.render(conv)

  eq({ "  ✓ Inspect todo UI", "  ○ Add tests" }, visible_lines(buf))
end

T["todos ui"]["refreshes before closing completed todos panel"] = function()
  local todos = require("sia.ui.todos")
  local conv = make_conversation(302, {
    { id = 1, description = "Finish work", status = "active" },
  })
  local chat_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(chat_buf)

  package.loaded["sia.strategy"] = {
    get_chat = function()
      return { buf = chat_buf, conversation = conv }
    end,
  }

  local buf = todos._get_or_create_buf(conv)
  eq({ "  ▶ Finish work" }, visible_lines(buf))

  conv.todos.items[1].status = "done"
  todos.close(conv)

  eq({ "  ✓ Finish work" }, visible_lines(buf))
  package.loaded["sia.strategy"] = nil
end

return T

