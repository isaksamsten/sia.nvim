local M = {}

local win = nil
local buf = nil

--- Create or update the confirmation floating window
--- @param content string[]|fun(buf:integer, win:integer) Lines to display
--- @param opts table?
--- @return function clear_function Function to call to clear the confirmation
function M.show(content, opts)
  M.clear()
  opts = opts or {}
  local reflow = opts.reflow

  if not content then
    return function() end
  end

  local screen_width = vim.o.columns
  local screen_height = vim.o.lines

  local effective_width = screen_width - 2 -- Account for border

  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].swapfile = false
    vim.bo[buf].bufhidden = "wipe"
  end
  local max_height = math.floor(screen_height * 0.7)
  win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    fixed = true,
    width = screen_width,
    row = screen_height - vim.o.cmdheight,
    col = 0,
    anchor = "SW",
    height = 5,
    style = "minimal",
    border = "none",
    zindex = 251,
  })

  vim.wo[win].winhighlight = "Normal:MsgArea"
  if type(content) == "table" then
    --- @cast content string[]
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
    vim.bo[buf].textwidth = effective_width
    local initial_height = math.min(#content, max_height)

    if reflow then
      vim.cmd("normal! ggVGgwgg")

      local wrapped_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local actual_height = math.min(#wrapped_content, max_height)

      if actual_height ~= initial_height then
        vim.api.nvim_win_set_config(win, {
          height = actual_height,
        })
      end
    else
      vim.api.nvim_win_set_config(win, {
        height = initial_height,
      })
    end
  else
    content(buf, win)
  end
  vim.api.nvim_win_set_config(win, { focusable = false })
  vim.cmd("wincmd p")

  return M.clear
end

function M.clear()
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  win = nil
end

return M
