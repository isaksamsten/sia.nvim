local utils = require("sia.utils")
local tool_utils = require("sia.tools.utils")

return tool_utils.new_tool({
  name = "workspace",
  message = "Getting workspace information...",
  description = "Show visible files with line ranges and background files",
  system_prompt = [[Use this tool to get information about which files and line
ranges are currently visible in the user's workspace.

Always call this tool first when the user asks contextual questions about code
they are viewing, especially if they refer to "this", "here", or do not specify
a file.

Do not guess which file the user means—always check the workspace first.]],
  parameters = vim.empty_dict(),
  required = {},
}, function(_, _, callback)
  local content = {}
  local current_win = vim.api.nvim_get_current_win()
  local visible_windows = {}
  local visible_bufs = {}
  local background_buffers = {}

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local name = vim.api.nvim_buf_get_name(buf)

    if name == "" or vim.fn.filereadable(name) == 0 then
      goto continue
    end

    local relative_path = vim.fn.fnamemodify(name, ":.")

    -- Get visible line range in this window
    local topline = vim.fn.line("w0", win)
    local botline = vim.fn.line("w$", win)
    local total_lines = vim.api.nvim_buf_line_count(buf)

    table.insert(visible_windows, {
      win = win,
      buf = buf,
      relative_path = relative_path,
      topline = topline,
      botline = botline,
      total_lines = total_lines,
      is_current = win == current_win,
      cursor_line = vim.api.nvim_win_get_cursor(win)[1],
    })

    visible_bufs[buf] = true

    ::continue::
  end

  table.sort(visible_windows, function(a, b)
    if a.is_current ~= b.is_current then
      return a.is_current
    end
    return a.relative_path < b.relative_path
  end)

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and not visible_bufs[buf] then
      local name = vim.api.nvim_buf_get_name(buf)

      -- Only show buffers backed by actual files
      if name == "" or vim.fn.filereadable(name) == 0 then
        goto continue
      end

      local relative_path = vim.fn.fnamemodify(name, ":.")

      table.insert(background_buffers, {
        buf = buf,
        relative_path = relative_path,
      })

      ::continue::
    end
  end

  table.sort(background_buffers, function(a, b)
    return a.relative_path < b.relative_path
  end)

  if #visible_windows == 0 then
    table.insert(content, "No file windows are currently visible")
  else
    table.insert(
      content,
      string.format(
        "Visible files (%d window%s):",
        #visible_windows,
        #visible_windows == 1 and "" or "s"
      )
    )
    table.insert(content, "")

    for i, win_info in ipairs(visible_windows) do
      local line_range = string.format(
        "lines %d-%d of %d",
        win_info.topline,
        win_info.botline,
        win_info.total_lines
      )
      local header = string.format(
        "%s (%s, cursor at line %d) with content as shown by cat -n",
        win_info.relative_path,
        line_range,
        win_info.cursor_line
      )
      table.insert(content, header)

      local visible_content = utils.get_content(
        win_info.buf,
        win_info.topline - 1,
        win_info.botline,
        { show_line_numbers = true, max_line_length = 2000 }
      )

      for _, line in ipairs(visible_content) do
        table.insert(content, line)
      end

      if i < #visible_windows then
        table.insert(content, "")
      end
    end
  end

  if #background_buffers > 0 then
    table.insert(content, "")
    table.insert(content, string.format("Background files (%d):", #background_buffers))
    for _, buf_info in ipairs(background_buffers) do
      table.insert(content, string.format("  %s", buf_info.relative_path))
    end
  end

  callback({
    content = content,
    display_content = { "👁️ Read current workspace" },
  })
end)
