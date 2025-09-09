local M = {}

--- @type table<integer, {tick:integer, editing: boolean}>
M.tracked_buffers = {}

--- @param buf integer
--- @return integer
function M.ensure_tracked(buf)
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
