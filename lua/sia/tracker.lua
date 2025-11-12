local M = {}

--- @type table<integer, {tick: integer, ticks:table<integer, integer>, editing: table<integer, boolean>, refcount: integer, marked_for_deletion: boolean?}>
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

  return true
end

local function attach(buf)
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      local tracker = M.tracked_buffers[buf]
      if not tracker or tracker.marked_for_deletion then
        return true
      end
      local any_tracked_edit = false
      for conv, tick in pairs(tracker.ticks) do
        if not tracker.editing[conv] then
          tracker.ticks[conv] = tick + 1
          any_tracked_edit = true
        end
      end
      if any_tracked_edit then
        tracker.tick = tracker.tick + 1
      end
    end,
    on_detach = function()
      M.tracked_buffers[buf] = nil
    end,
  })
end
--- @param buf integer
--- @param id integer?
--- @return integer
function M.ensure_tracked(buf, id)
  if not should_track_buffer(buf) then
    return 0
  end

  if not M.tracked_buffers[buf] then
    M.tracked_buffers[buf] = {
      tick = 0,
      ticks = {},
      editing = {},
      refcount = 1,
      marked_for_deletion = false,
    }
    if id then
      M.tracked_buffers[buf].ticks[id] = 0
    end
    attach(buf)
  else
    local tracker = M.tracked_buffers[buf]
    if tracker.marked_for_deletion then
      tracker.marked_for_deletion = false
      tracker.tick = 0
      tracker.refcount = 1
      if id then
        tracker.ticks[id] = 0
      end
      return tracker.ticks[id] or tracker.tick
    else
      tracker.refcount = tracker.refcount + 1
    end
  end

  -- Lazy initialization: if this conversation hasn't tracked this buffer yet,
  -- inherit the current global tick (handles pre-conversation context)
  local tracker = M.tracked_buffers[buf]
  if id and not tracker.ticks[id] then
    tracker.ticks[id] = tracker.tick
  end

  return tracker.ticks[id] or tracker.tick
end

--- Decrement the reference count for a tracked buffer
--- When refcount reaches 0, stop tracking and clean up
--- @param buf integer
function M.untrack(buf)
  local tracker = M.tracked_buffers[buf]
  if not tracker or tracker.marked_for_deletion then
    return
  end

  tracker.refcount = tracker.refcount - 1
  if tracker.refcount <= 0 then
    -- Mark for deletion but don't cleanup immediately
    -- The on_lines callback will return true on next change, triggering on_detach
    tracker.marked_for_deletion = true
  end
end

--- @param buf integer
--- @param id integer
--- @param callback fun():any
--- @return any
function M.non_tracked_edit(buf, id, callback)
  local tracker = M.tracked_buffers[buf]
  if tracker then
    tracker.editing[id] = true
  end

  local ok, result = pcall(callback)

  if tracker then
    tracker.editing[id] = false
  end

  if not ok then
    error(result)
  end

  return result
end

--- Get the current user tick count for a buffer
--- @param buf integer The buffer number to get the tick count for
--- @param id integer Conversation ID
--- @return integer The current tick count, or 0 if the buffer is not tracked
---
--- Fallback behavior: Use the global tick
function M.user_tick(buf, id)
  local tracker = M.tracked_buffers[buf]
  if not tracker then
    return 0
  end
  if tracker.marked_for_deletion then
    return tracker.tick
  end

  return tracker.ticks[id] or tracker.tick
end

return M
