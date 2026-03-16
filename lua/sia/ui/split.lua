--- Reusable split panel attached to a chat window.
---
--- Opens a split (horizontal or vertical depending on chat width),
--- displays a buffer, restores focus to the caller, and cleans up
--- when the chat window/buffer is closed.
---
--- Usage:
---   local panel = require("sia.ui.split").new("status")
---   panel:toggle(chat, buf)      -- toggle / open with buffer
---   panel:open(chat, buf)        -- open (idempotent)
---   panel:close(chat)            -- close
---   panel:is_open(chat)          -- check

local M = {}

--- @class sia.ui.Panel
--- @field name string
--- @field _windows table<integer, integer>  chat_buf -> panel_win
--- @field _autocmds table<integer, integer> chat_buf -> autocmd_id
local Panel = {}
Panel.__index = Panel

--- Create a new named panel.
--- @param name string   identifier used for debugging / differentiation
--- @return sia.ui.Panel
function M.new(name)
  return setmetatable({
    name = name,
    _windows = {},
    _autocmds = {},
  }, Panel)
end

--- @param chat_buf integer
--- @return boolean
function Panel:is_open(chat_buf)
  local win = self._windows[chat_buf]
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

--- Close the panel for a given chat buffer.
--- @param chat_buf integer
function Panel:close(chat_buf)
  local win = self._windows[chat_buf]
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  self._windows[chat_buf] = nil
end

--- @param chat_win integer
--- @return integer win   the newly created panel window
local function create_split(chat_win)
  local chat_width = vim.api.nvim_win_get_width(chat_win)
  local screen_width = vim.o.columns
  local is_full_width = chat_width >= (screen_width - 2)

  local current_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(chat_win)

  local panel_win
  if is_full_width then
    vim.cmd("vertical topleft split")
    panel_win = vim.api.nvim_get_current_win()
    local width = math.floor(screen_width * 0.2)
    vim.api.nvim_win_set_width(panel_win, width)
  else
    vim.cmd("belowright split")
    panel_win = vim.api.nvim_get_current_win()
  end

  if vim.api.nvim_win_is_valid(current_win) then
    vim.api.nvim_set_current_win(current_win)
  end

  return panel_win
end

--- Size the panel window to fit content, respecting max limits.
--- @param panel_win integer
--- @param buf integer
--- @param is_vertical boolean
local function size_to_content(panel_win, buf, is_vertical)
  if is_vertical then
    return
  end
  local line_count = vim.api.nvim_buf_line_count(buf)
  local max_height = math.floor(vim.o.lines * 0.2)
  vim.api.nvim_win_set_height(panel_win, math.min(line_count, max_height))
end

--- Set up cleanup autocmds so the panel closes when the chat window/buffer goes away.
--- @param self sia.ui.Panel
--- @param chat_buf integer
--- @param chat_win integer
local function setup_cleanup(self, chat_buf, chat_win)
  -- Remove previous autocmd if any
  if self._autocmds[chat_buf] then
    pcall(vim.api.nvim_del_autocmd, self._autocmds[chat_buf])
    self._autocmds[chat_buf] = nil
  end

  local id = vim.api.nvim_create_autocmd(
    { "BufDelete", "BufWipeout", "WinClosed", "BufWinLeave" },
    {
      buffer = chat_buf,
      callback = function(ev)
        if ev.event == "WinClosed" then
          local closed_win = tonumber(ev.match)
          if closed_win == chat_win then
            self:close(chat_buf)
          end
        else
          self:close(chat_buf)
        end
      end,
    }
  )
  self._autocmds[chat_buf] = id
end

--- Open (or reuse) the panel, displaying the given buffer.
--- Does nothing if no valid chat window is found.
--- @param chat_buf integer
--- @param buf integer       the buffer to show in the panel
--- @param opts { size: "auto"|integer, vertical: boolean, wrap: boolean?}?
function Panel:open(chat_buf, buf, opts)
  opts = opts or {}
  local is_vertical = opts.vertical == true
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local chat_win = vim.fn.bufwinid(chat_buf)
  if chat_win == -1 then
    return
  end

  if self:is_open(chat_buf) then
    local win = self._windows[chat_buf]
    vim.api.nvim_win_set_buf(win, buf)
    size_to_content(win, buf, is_vertical)
    return
  end

  local panel_win = create_split(chat_win)

  vim.api.nvim_win_set_buf(panel_win, buf)
  if opts.size == nil or opts.size == "auto" then
    size_to_content(panel_win, buf, is_vertical)
  else
    vim.api.nvim_win_set_height(panel_win, opts.size --[[@as integer]])
  end
  vim.wo[panel_win].wrap = opts.wrap or false
  vim.wo[panel_win].number = false
  vim.wo[panel_win].relativenumber = false
  vim.wo[panel_win].signcolumn = "no"

  self._windows[chat_buf] = panel_win
  setup_cleanup(self, chat_buf, chat_win)
end

--- Toggle the panel for a chat buffer.
--- @param chat_buf integer
--- @param buf integer       the buffer to show when opening
function Panel:toggle(chat_buf, buf)
  if self:is_open(chat_buf) then
    self:close(chat_buf)
  else
    self:open(chat_buf, buf)
  end
end

return M
