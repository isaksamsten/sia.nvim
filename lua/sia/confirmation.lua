local M = {}

local confirmation_win = nil
local confirmation_buf = nil

--- Create or update the confirmation floating window
--- @param content string[] Lines to display
--- @param opts table?
--- @return function clear_function Function to call to clear the confirmation
function M.show(content, opts)
  M.clear()
  opts = opts or {}
  local reflow = opts.reflow ~= false

  if not content or #content == 0 then
    return function() end
  end

  local screen_width = vim.o.columns
  local screen_height = vim.o.lines

  local effective_width = screen_width - 2 -- Account for border

  if not confirmation_buf or not vim.api.nvim_buf_is_valid(confirmation_buf) then
    confirmation_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[confirmation_buf].buftype = "nofile"
    vim.bo[confirmation_buf].swapfile = false
    vim.bo[confirmation_buf].bufhidden = "wipe"
  end

  vim.api.nvim_buf_set_lines(confirmation_buf, 0, -1, false, content)
  vim.bo[confirmation_buf].textwidth = effective_width

  local initial_height = math.min(#content, math.floor(screen_height * 0.3))

  confirmation_win = vim.api.nvim_open_win(confirmation_buf, true, {
    relative = "editor",
    fixed = true,
    width = screen_width,
    row = screen_height - vim.o.cmdheight,
    col = 0,
    anchor = "SW",
    height = initial_height,
    style = "minimal",
    border = "none",
    zindex = 251,
  })

  vim.wo[confirmation_win].winhighlight = "Normal:MsgArea"
  if reflow then
    vim.cmd("normal! ggVGgwgg")

    local wrapped_content = vim.api.nvim_buf_get_lines(confirmation_buf, 0, -1, false)
    local actual_height = math.min(#wrapped_content, math.floor(screen_height * 0.7))

    if actual_height ~= initial_height then
      vim.api.nvim_win_set_config(confirmation_win, {
        height = actual_height,
      })
    end

    vim.api.nvim_win_set_config(confirmation_win, { focusable = false })
  end
  vim.cmd("wincmd p")

  return M.clear
end

function M.clear()
  if confirmation_win and vim.api.nvim_win_is_valid(confirmation_win) then
    vim.api.nvim_win_close(confirmation_win, true)
  end
  confirmation_win = nil
end

return M
