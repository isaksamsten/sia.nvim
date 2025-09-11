local M = {}

--- @type table<integer, {tick:integer, editing: boolean}>
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

--- @param buf integer
--- @return integer
function M.ensure_tracked(buf)
  if not should_track_buffer(buf) then
    return 0
  end

  if not M.tracked_buffers[buf] then
    M.tracked_buffers[buf] = { tick = 0, editing = false }

    local group = vim.api.nvim_create_augroup("SiaTracker_" .. buf, { clear = true })
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      buffer = buf,
      group = group,
      callback = function()
        local tracker = M.tracked_buffers[buf]
        if not tracker.editing then
          tracker.tick = tracker.tick + 1
        end
      end,
    })

    -- Temporarily disable tracking when just entering a buffer
    vim.api.nvim_create_autocmd("BufEnter", {
      buffer = buf,
      group = group,
      callback = function()
        local tracker = M.tracked_buffers[buf]
        if tracker and not tracker.editing then
          tracker.editing = true
          vim.defer_fn(function()
            tracker.editing = false
          end, 100)
        end
      end,
    })

    vim.api.nvim_create_autocmd("BufDelete", {
      buffer = buf,
      group = group,
      once = true,
      callback = function()
        M.tracked_buffers[buf] = nil
      end,
    })
  end
  return M.tracked_buffers[buf].tick
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
