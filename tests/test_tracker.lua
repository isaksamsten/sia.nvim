local tracker = require("sia.tracker")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["sia.tracker"] = MiniTest.new_set()

local function create_test_buffer(lines)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, "test_" .. buf .. ".lua")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

T["sia.tracker"]["refcounting tracks and untracks"] = function()
  local buf = create_test_buffer({ "line 1", "line 2" })

  -- First track should start tracking
  local tick1 = tracker.ensure_tracked(buf)
  eq(tracker.tracked_buffers[buf] ~= nil, true)
  eq(tracker.tracked_buffers[buf].refcount, 1)
  eq(tick1, 0)

  -- Second track should increment refcount
  local tick2 = tracker.ensure_tracked(buf)
  eq(tracker.tracked_buffers[buf].refcount, 2)
  eq(tick2, 0)

  tracker.untrack(buf)
  eq(tracker.tracked_buffers[buf] ~= nil, true)
  eq(tracker.tracked_buffers[buf].refcount, 1)

  -- Second untrack should cleanup
  tracker.untrack(buf)
  eq(tracker.tracked_buffers[buf].marked_for_deletion, true)

  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tracker"]["refcounting handles multiple buffers"] = function()
  local buf1 = create_test_buffer({ "buffer 1" })
  local buf2 = create_test_buffer({ "buffer 2" })

  tracker.ensure_tracked(buf1)
  tracker.ensure_tracked(buf2)
  tracker.ensure_tracked(buf1) -- buf1 now has refcount 2

  eq(tracker.tracked_buffers[buf1].refcount, 2)
  eq(tracker.tracked_buffers[buf2].refcount, 1)

  tracker.untrack(buf1)
  eq(tracker.tracked_buffers[buf1] ~= nil, true)
  eq(tracker.tracked_buffers[buf1].refcount, 1)
  eq(tracker.tracked_buffers[buf2].refcount, 1)

  tracker.untrack(buf2)
  eq(tracker.tracked_buffers[buf1].refcount, 1)
  eq(tracker.tracked_buffers[buf2].marked_for_deletion, true)

  tracker.untrack(buf1)
  eq(tracker.tracked_buffers[buf1].marked_for_deletion, true)

  vim.api.nvim_buf_delete(buf1, { force = true })
  vim.api.nvim_buf_delete(buf2, { force = true })
end

T["sia.tracker"]["untrack on non-tracked buffer is safe"] = function()
  local buf = create_test_buffer({ "test" })

  -- Should not error
  tracker.untrack(buf)
  eq(tracker.tracked_buffers[buf], nil)

  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tracker"]["per-conversation tracking isolates ticks"] = function()
  local buf = create_test_buffer({ "-- Test file", "local x = 1", "print(x)" })

  -- Track with two different conversation IDs
  local conv4 = 4
  local conv3 = 3
  local tick_conv4 = tracker.ensure_tracked(buf, conv4)
  local tick_conv3 = tracker.ensure_tracked(buf, conv3)

  eq(tick_conv4, 0)
  eq(tick_conv3, 0)

  -- Make a non-tracked edit for conv4
  -- This should NOT increment conv4's tick, but SHOULD increment conv3's tick
  tracker.non_tracked_edit(buf, conv4, function()
    vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "print(y)" })
  end)

  -- Wait for on_lines callback to process
  vim.wait(100, function()
    return tracker.user_tick(buf, conv3) == tick_conv3 + 1
  end)

  eq(tracker.user_tick(buf, conv4), tick_conv4) -- conv4 tick unchanged
  eq(tracker.user_tick(buf, conv3), tick_conv3 + 1) -- conv3 tick incremented

  -- Clean up
  tracker.untrack(buf)
  tracker.untrack(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
end

return T
