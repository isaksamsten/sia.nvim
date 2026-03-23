--- Reusable split panel attached to a chat window.
---
--- Opens a horizontal split below the chat window, displays a buffer,
--- restores focus to the caller, and cleans up when the chat window/buffer
--- is closed. The panel is "sticky": it remembers its target height and
--- restores it when other windows (e.g. quickfix) cause layout changes.
---
--- Usage:
---   local panel = require("sia.ui.split").new("status")
---   panel:toggle(chat, buf)      -- toggle / open with buffer
---   panel:open(chat, buf)        -- open (idempotent)
---   panel:close(chat)            -- close
---   panel:is_open(chat)          -- check

local M = {}

--- @class sia.ui.Panel
--- @field private max_size number
--- @field private windows table<integer, integer>
--- @field private autocmds table<integer, integer[]> chat_buf -> autocmd_ids
--- @field private sizes table<integer, integer>    chat_buf -> target size
local Panel = {}
Panel.__index = Panel

--- Create a new panel.
--- @param max_size number?
--- @return sia.ui.Panel
function M.new(max_size)
  return setmetatable({
    max_size = max_size or 0.2,
    windows = {},
    autocmds = {},
    sizes = {},
  }, Panel)
end

--- @param chat_buf integer
--- @return boolean
function Panel:is_open(chat_buf)
  local win = self.windows[chat_buf]
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

--- Close the panel for a given chat buffer.
--- @param chat_buf integer
function Panel:close(chat_buf)
  local win = self.windows[chat_buf]
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  self.windows[chat_buf] = nil
  self.sizes[chat_buf] = nil
  if self.autocmds[chat_buf] then
    for _, id in ipairs(self.autocmds[chat_buf]) do
      pcall(vim.api.nvim_del_autocmd, id)
    end
    self.autocmds[chat_buf] = nil
  end
end

--- @param chat_win integer
--- @return integer win   the newly created panel window
local function create_split(chat_win)
  local current_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(chat_win)

  vim.cmd("belowright split")
  local panel_win = vim.api.nvim_get_current_win()

  if vim.api.nvim_win_is_valid(current_win) then
    vim.api.nvim_set_current_win(current_win)
  end

  return panel_win
end

--- Compute a height that fits the buffer content, capped at 20% of screen.
--- @para max_size number
--- @param buf integer
--- @return integer
local function size_to_content(max_size, buf)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local max_height = math.floor(vim.o.lines * max_size)
  return math.min(line_count, max_height)
end

--- Set up cleanup autocmds so the panel closes when the chat window/buffer goes away.
--- @param self sia.ui.Panel
--- @param chat_buf integer
--- @param chat_win integer
local function setup_cleanup(self, chat_buf, chat_win)
  -- Remove previous autocmds if any
  if self.autocmds[chat_buf] then
    for _, id in ipairs(self.autocmds[chat_buf]) do
      pcall(vim.api.nvim_del_autocmd, id)
    end
    self.autocmds[chat_buf] = nil
  end

  local cleanup_id = vim.api.nvim_create_autocmd(
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

  -- Restore panel size when window layout changes
  local resize_id = vim.api.nvim_create_autocmd("WinResized", {
    callback = function()
      local win = self.windows[chat_buf]
      local target = self.sizes[chat_buf]
      if win and target and vim.api.nvim_win_is_valid(win) then
        local current = vim.api.nvim_win_get_height(win)
        if current ~= target then
          vim.api.nvim_win_set_height(win, target)
        end
      end
    end,
  })

  self.autocmds[chat_buf] = { cleanup_id, resize_id }
end

--- Open (or reuse) the panel, displaying the given buffer.
--- Does nothing if no valid chat window is found.
--- @param chat_buf integer
--- @param buf integer       the buffer to show in the panel
--- @param opts { size: "auto"|integer, wrap: boolean?}?
function Panel:open(chat_buf, buf, opts)
  opts = opts or {}
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local chat_win = vim.fn.bufwinid(chat_buf)
  if chat_win == -1 then
    return
  end

  if self:is_open(chat_buf) then
    local win = self.windows[chat_buf]
    vim.api.nvim_win_set_buf(win, buf)
    local target = size_to_content(self.max_size, buf)
    vim.api.nvim_win_set_height(win, target)
    self.sizes[chat_buf] = target
    return
  end

  local panel_win = create_split(chat_win)

  vim.api.nvim_win_set_buf(panel_win, buf)
  local target
  if opts.size == nil or opts.size == "auto" then
    target = size_to_content(self.max_size, buf)
  else
    target = opts.size --[[@as integer]]
  end
  vim.api.nvim_win_set_height(panel_win, target)
  self.sizes[chat_buf] = target

  vim.wo[panel_win].wrap = opts.wrap or false
  vim.wo[panel_win].number = false
  vim.wo[panel_win].relativenumber = false
  vim.wo[panel_win].signcolumn = "no"

  self.windows[chat_buf] = panel_win
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
