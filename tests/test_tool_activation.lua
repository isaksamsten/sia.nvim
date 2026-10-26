local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local Canvas = require("sia.canvas").Canvas

T["live actions follow blocks, show a cursor hint, and are cleared on replacement"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  local canvas = Canvas:new(buf)
  local called = 0
  local action = function()
    called = called + 1
  end
  local renders = {
    a = { status = "done", summary = { header = "Read file", on_activate = action } },
    b = { status = "done", summary = "No action" },
  }
  local count = canvas:update_tool_block({ 0, 0 }, 1, renders, { "a", "b" })
  eq(action, canvas:tool_action_at(0))
  eq(nil, canvas:tool_action_at(1))
  local hint_ns = vim.api.nvim_get_namespaces().sia_chat_tool_action_hint
  eq(1, #vim.api.nvim_buf_get_extmarks(buf, hint_ns, 0, -1, {}))
  vim.api.nvim_buf_get_keymap(buf, "n")[1].callback()
  eq(1, called)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
  eq(0, #vim.api.nvim_buf_get_extmarks(buf, hint_ns, 0, -1, {}))
  canvas:insert_lines_at(0, { "above" })
  eq(action, canvas:tool_action_at(1))
  renders.a.summary = "No longer actionable"
  canvas:update_tool_block({ 1, 0 }, count, renders, { "a", "b" })
  eq(nil, canvas:tool_action_at(1))
  eq(nil, next(canvas.tool_actions))
  canvas:clear()
  eq(nil, next(canvas.tool_actions))
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["history rendering does not register actions"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  local canvas = Canvas:new(buf)
  canvas:render_messages({
    {
      role = "tool",
      summary = { header = "Read file", on_activate = function() end },
    },
  })
  eq(nil, next(canvas.tool_actions))
  eq(0, #vim.api.nvim_buf_get_keymap(buf, "n"))
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["grep activation reruns with original scope and fills quickfix"] = function()
  local original = vim.system
  local command, options
  vim.system = function(cmd, opts, callback)
    command, options = cmd, opts
    callback({
      code = 0,
      stdout = vim.json.encode({
        type = "match",
        data = {
          path = { text = "file.lua" },
          lines = { text = "a match\n" },
          line_number = 3,
          submatches = { { start = 2 } },
        },
      }) .. "\n",
    })
  end
  local ok, err = pcall(function()
    require("sia.tools.activation").grep(
      { "rg", "-l", "--glob", "*.lua", "--", "match", "." },
      "/tmp"
    )()
    vim.wait(1000, function()
      return vim.fn.getqflist({ title = 0 }).title == "Sia grep"
    end)
    eq({ "rg", "--json", "--glob", "*.lua", "--", "match", "." }, command)
    eq("/tmp", options.cwd)
    local items = vim.fn.getqflist()
    eq(1, #items)
    eq(3, items[1].lnum)
    eq(3, items[1].col)
    eq("/tmp/file.lua", vim.api.nvim_buf_get_name(items[1].bufnr))
    vim.cmd("cclose")
  end)
  vim.system = original
  if not ok then
    error(err)
  end
end

T["file activation opens beside the canvas at the requested line"] = function()
  local path = vim.fn.tempname() .. " with spaces"
  vim.fn.writefile({ "first", "second" }, path)
  local chat_win = vim.api.nvim_get_current_win()
  local chat_buf = vim.api.nvim_get_current_buf()
  require("sia.tools.activation").open_file(path, 2)()
  eq(path, vim.api.nvim_buf_get_name(0))
  eq(2, vim.api.nvim_win_get_cursor(0)[1])
  eq(chat_buf, vim.api.nvim_win_get_buf(chat_win))
  local buf = vim.api.nvim_get_current_buf()
  vim.cmd("close")
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end

T["the entire detail range is actionable without stealing adjacent blocks"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  local canvas = Canvas:new(buf)
  local action = function() end
  canvas:update_tool_block({ 0, 0 }, 1, {
    a = {
      status = "done",
      summary = {
        header = "Read file",
        detail = { text = "one\ntwo", ft = "text" },
        on_activate = action,
      },
    },
  }, { "a" })
  local count = vim.api.nvim_buf_line_count(buf)
  for row = 0, count - 2 do
    eq(action, canvas:tool_action_at(row))
  end
  canvas:insert_lines_at(count, { "" })
  canvas:update_tool_block({ count, 0 }, 1, {
    b = { status = "done", summary = "No action" },
  }, { "b" })
  eq(action, canvas:tool_action_at(count - 2))
  eq(nil, canvas:tool_action_at(count - 1))
  eq(nil, canvas:tool_action_at(count))
  vim.api.nvim_buf_delete(buf, { force = true })
end

return T
