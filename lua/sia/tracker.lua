local M = {}

--- @type table<integer, {tick:integer, editing: boolean, timer: uv_timer_t?, refcount: integer, group: integer?}>
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
  local tracker = M.tracked_buffers[buf]
  if tracker then
    pcall(vim.api.nvim_del_augroup_by_id, tracker.group)
    if tracker.timer then
      tracker.timer:stop()
      tracker.timer = nil
    end
  end
  M.tracked_buffers[buf] = nil
end

--- @param buf integer
--- @return integer
function M.ensure_tracked(buf)
  if not should_track_buffer(buf) then
    return 0
  end

  if not M.tracked_buffers[buf] then
    local group = vim.api.nvim_create_augroup("SiaTracker_" .. buf, { clear = true })
    M.tracked_buffers[buf] = {
      tick = 0,
      editing = false,
      timer = nil,
      refcount = 1,
      group = group,
    }

    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      buffer = buf,
      group = group,
      callback = function()
        local tracker = M.tracked_buffers[buf]
        if not tracker then
          cleanup(buf)
          return
        end
        if not tracker.editing then
          tracker.tick = tracker.tick + 1
        end
      end,
    })

    vim.api.nvim_create_autocmd("BufEnter", {
      buffer = buf,
      group = group,
      callback = function()
        local tracker = M.tracked_buffers[buf]
        if not tracker then
          cleanup(buf)
          return
        end
        if tracker.timer then
          tracker.timer:stop()
          tracker.timer = nil
        end
        tracker.editing = true
        tracker.timer = vim.defer_fn(function()
          tracker.editing = false
          tracker.timer = nil
        end, 100)
      end,
    })

    vim.api.nvim_create_autocmd("BufDelete", {
      buffer = buf,
      group = group,
      once = true,
      callback = function()
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

--- @param buf integer
--- @return integer
function M.user_tick(buf)
  local tracker = M.tracked_buffers[buf]
  return tracker and tracker.tick or 0
end

return M
