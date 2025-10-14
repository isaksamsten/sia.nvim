local M = {}

--- @type table<integer, {tick:integer, editing: boolean, refcount: integer}>
M.tracked_buffers = {}

--- @param buf integer
--- @return boolean
local function should_track_buffer(buf)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
    return false
  end

  if vim.bo[buf].buftype ~= "" then
    return false
  end

  local bufname = vim.api.nvim_buf_get_name(buf)
  if bufname == "" then
    return false
  end

  -- if not vim.bo[buf].buflisted then
  --   return false
  -- end

  return true
end

local function cleanup(buf)
  M.tracked_buffers[buf] = nil
end

--- @param buf integer
--- @return integer
function M.ensure_tracked(buf)
  if not should_track_buffer(buf) then
    return 0
  end

  if not M.tracked_buffers[buf] then
    M.tracked_buffers[buf] = {
      tick = 0,
      editing = false,
      refcount = 1,
    }
    vim.api.nvim_buf_attach(buf, false, {
      on_lines = function()
        local tracker = M.tracked_buffers[buf]
        if not tracker then
          return true
        end
        if not tracker.editing then
          tracker.tick = tracker.tick + 1
        end
      end,
      on_detach = function()
        cleanup(buf)
      end,
    })
  else
    M.tracked_buffers[buf].refcount = M.tracked_buffers[buf].refcount + 1
  end
  return M.tracked_buffers[buf].tick
end

--- Decrement the reference count for a tracked buffer
--- When refcount reaches 0, stop tracking and clean up
--- @param buf integer
function M.untrack(buf)
  local tracker = M.tracked_buffers[buf]
  if not tracker then
    return
  end

  tracker.refcount = tracker.refcount - 1
  if tracker.refcount <= 0 then
    cleanup(buf)
  end
end

--- @param buf integer
--- @param callback fun():any
--- @return any
function M.non_tracked_edit(buf, callback)
  local tracker = M.tracked_buffers[buf]
  if tracker then
    tracker.editing = true
  end

  local ok, result = pcall(callback)

  if tracker then
    tracker.editing = false
  end

  if not ok then
    error(result)
  end

  return result
end

--- Get the current user tick count for a buffer
--- @param buf integer The buffer number to get the tick count for
--- @return integer The current tick count, or 0 if the buffer is not tracked
---
--- Example usage:
--- ```lua
--- local tracker = require("sia.tracker")
---
--- -- Ensure buffer is tracked and get initial tick
--- local buf = vim.api.nvim_get_current_buf()
--- local initial_tick = tracker.ensure_tracked(buf)
---
--- -- Later, check if buffer has been modified by user
--- local current_tick = tracker.user_tick(buf)
--- if current_tick > initial_tick then
---   print("Buffer has been modified by user")
--- end
---
--- -- Use with non_tracked_edit to make programmatic changes
--- tracker.non_tracked_edit(buf, function()
---   vim.api.nvim_buf_set_lines(buf, 0, 1, false, {"-- Added comment"})
--- end)
--- -- Tick count remains unchanged after non_tracked_edit
--- assert(tracker.user_tick(buf) == current_tick)
--- ```
function M.user_tick(buf)
  local tracker = M.tracked_buffers[buf]
  return tracker and tracker.tick or 0
end

return M
