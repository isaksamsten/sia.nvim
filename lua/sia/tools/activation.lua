local M = {}

--- Open beside the chat so activation does not replace the canvas.
function M.open_file(path, line)
  return function()
    vim.cmd("vsplit " .. vim.fn.fnameescape(path))
    if line then
      local row = math.max(1, math.min(line, vim.api.nvim_buf_line_count(0)))
      vim.api.nvim_win_set_cursor(0, { row, 0 })
    end
  end
end

--- Review the file's remaining Sia edits without replacing the chat canvas.
function M.edit_file(buf)
  return function()
    if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
      return
    end
    local diff = require("sia.diff")
    -- Diff updates are debounced; activation should use the current contents.
    diff.update_diff(buf)
    local items = diff.get_all_hunks_for_quickfix(buf)
    if #items == 0 then
      return
    end
    M.open_file(vim.api.nvim_buf_get_name(buf), items[1].lnum)()
    local win = vim.api.nvim_get_current_win()
    vim.fn.setqflist(items, "r")
    vim.cmd("copen")
    vim.api.nvim_set_current_win(win)
  end
end

--- Rerun a tool search as navigable matches, regardless of its output mode.
function M.grep(command, workspace)
  command = vim.deepcopy(command)
  for i, arg in ipairs(command) do
    if arg == "--" then
      break
    end
    if arg == "-l" or arg == "-c" then
      command[i] = "--json"
    end
  end
  return function()
    vim.system(
      command,
      { text = true, cwd = workspace, timeout = 5000 },
      vim.schedule_wrap(function(result)
        if result.code ~= 0 and result.code ~= 1 then
          vim.notify(result.stderr or "Search failed", vim.log.levels.ERROR)
          return
        end
        local items = {}
        for line in (result.stdout or ""):gmatch("[^\n]+") do
          local ok, event = pcall(vim.json.decode, line)
          if
            ok
            and event.type == "match"
            and event.data.path.text
            and event.data.lines.text
          then
            local data = event.data
            local path = require("sia.tools.utils").resolve_workspace_path(
              data.path.text,
              workspace
            )
            table.insert(items, {
              filename = path,
              lnum = data.line_number,
              col = data.submatches[1] and data.submatches[1].start + 1 or 1,
              text = data.lines.text:gsub("[\r\n]+$", ""),
            })
          end
        end
        vim.fn.setqflist({}, " ", { title = "Sia grep", items = items })
        vim.cmd("copen")
      end)
    )
  end
end

return M
