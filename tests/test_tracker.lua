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

  -- First track should start tracking (global whole buffer)
  local tick1 = tracker.ensure_tracked(buf)
  eq(tracker.tracked_buffers[buf] ~= nil, true)
  eq(tracker.tracked_buffers[buf].global ~= nil, true)
  eq(tracker.tracked_buffers[buf].global[1].refcount, 1)
  eq(tick1, 0)

  -- Second track should increment refcount
  local tick2 = tracker.ensure_tracked(buf)
  eq(tracker.tracked_buffers[buf].global[1].refcount, 2)
  eq(tick2, 0)

  tracker.untrack(buf)
  eq(tracker.tracked_buffers[buf] ~= nil, true)
  eq(tracker.tracked_buffers[buf].global[1].refcount, 1)

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

  eq(tracker.tracked_buffers[buf1].global[1].refcount, 2)
  eq(tracker.tracked_buffers[buf2].global[1].refcount, 1)

  tracker.untrack(buf1)
  eq(tracker.tracked_buffers[buf1] ~= nil, true)
  eq(tracker.tracked_buffers[buf1].global[1].refcount, 1)
  eq(tracker.tracked_buffers[buf2].global[1].refcount, 1)

  tracker.untrack(buf2)
  eq(tracker.tracked_buffers[buf1].global[1].refcount, 1)
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
  local tick_conv4 = tracker.ensure_tracked(buf, { id = conv4 })
  local tick_conv3 = tracker.ensure_tracked(buf, { id = conv3 })

  eq(tick_conv4, 0)
  eq(tick_conv3, 0)

  -- Make a non-tracked edit for conv4
  -- This should NOT increment conv4's tick, but SHOULD increment conv3's tick
  tracker.without_tracking(buf, conv4, function()
    vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "print(y)" })
  end)

  -- Wait for on_lines callback to process
  vim.wait(100, function()
    return tracker.user_tick(buf, conv3) == tick_conv3 + 1
  end)

  eq(tracker.user_tick(buf, conv4), tick_conv4) -- conv4 tick unchanged
  eq(tracker.user_tick(buf, conv3), tick_conv3 + 1) -- conv3 tick incremented

  -- Clean up
  tracker.untrack(buf, { id = conv4 })
  tracker.untrack(buf, { id = conv3 })
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tracker"]["without_tracking skips global but tracks other conversations"] = function()
  local buf = create_test_buffer({ "line 1", "line 2" })
  tracker.ensure_tracked(buf)

  local conv1 = 1
  local conv2 = 2
  tracker.ensure_tracked(buf, { id = conv1 })
  tracker.ensure_tracked(buf, { id = conv2 })

  tracker.without_tracking(buf, conv1, function()
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "modified line 1" })
  end)

  vim.wait(100)

  eq(tracker.user_tick(buf, conv1), 0)
  eq(tracker.user_tick(buf, conv2), 1)
  eq(tracker.tracked_buffers[buf].global[1].tick, 0)

  tracker.untrack(buf)
  tracker.untrack(buf, { id = conv1 })
  tracker.untrack(buf, { id = conv2 })
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tracker"]["region tracking"] = function()
  local buf = create_test_buffer({ "line 1", "line 2", "line 3", "line 4", "line 5" })

  -- Track a region for conv 1
  local conv1 = 1
  local tick1 = tracker.ensure_tracked(buf, { id = conv1, pos = { 2, 4 } })
  eq(tick1, 0)

  -- Track another region for conv 1
  local tick2 = tracker.ensure_tracked(buf, { id = conv1, pos = { 1, 2 } })
  eq(tick2, 0)

  -- Edit inside first region (line 3)
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "modified line 3" })
  vim.wait(100)

  -- First region should be ticked, second should not
  eq(tracker.user_tick(buf, conv1, { pos = { 2, 4 } }), 1)
  eq(tracker.user_tick(buf, conv1, { pos = { 1, 2 } }), 0)

  -- Edit overlapping both regions (line 2)
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "modified line 2" })
  vim.wait(100)

  -- Both regions should be ticked
  eq(tracker.user_tick(buf, conv1, { pos = { 2, 4 } }), 2)
  eq(tracker.user_tick(buf, conv1, { pos = { 1, 2 } }), 1)

  -- Clean up
  tracker.untrack(buf, { id = conv1, pos = { 2, 4 } })
  tracker.untrack(buf, { id = conv1, pos = { 1, 2 } })
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tracker"]["whole buffer overrides regions"] = function()
  local buf = create_test_buffer({ "line 1", "line 2", "line 3" })
  local conv1 = 1

  -- Track a region first
  tracker.ensure_tracked(buf, { id = conv1, pos = { 1, 2 } })

  -- Now track whole buffer - should clear region and reset tick
  local tick = tracker.ensure_tracked(buf, { id = conv1 })
  eq(tick, 0)

  -- Check that only whole buffer region exists
  eq(#tracker.tracked_buffers[buf].regions[conv1], 1)
  eq(tracker.tracked_buffers[buf].regions[conv1][1].pos, nil)

  -- Edit anywhere should increment whole buffer tick
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "modified line 3" })
  vim.wait(100)

  eq(tracker.user_tick(buf, conv1, {}), 1)

  -- Clean up
  tracker.untrack(buf, { id = conv1 })
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tracker"]["tick inheritance from global to conversation"] = function()
  local buf = create_test_buffer({ "line 1", "line 2", "line 3" })

  -- Track globally first
  tracker.ensure_tracked(buf, {})

  -- Make an edit to increment global tick
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "modified line 1" })
  vim.wait(100)

  -- Global tick should be 1
  local global_region = tracker.tracked_buffers[buf].global[1]
  eq(global_region.tick, 1)

  -- Now track for a conversation - should inherit tick
  local conv1 = 1
  local tick = tracker.ensure_tracked(buf, { id = conv1 })
  eq(tick, 1) -- Inherited from global

  -- Clean up
  tracker.untrack(buf, {})
  tracker.untrack(buf, { id = conv1 })
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tracker"]["region tick inheritance from global"] = function()
  local buf = create_test_buffer({ "line 1", "line 2", "line 3", "line 4" })

  -- Track a global region
  tracker.ensure_tracked(buf, { pos = { 2, 3 } })

  -- Make an edit in that region
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "modified line 2" })
  vim.wait(100)

  -- Global region tick should be 1
  eq(tracker.tracked_buffers[buf].global[1].tick, 1)

  -- Now track same region for a conversation - should inherit tick
  local conv1 = 1
  local tick = tracker.ensure_tracked(buf, { id = conv1, pos = { 2, 3 } })
  eq(tick, 1) -- Inherited from global region

  -- Clean up
  tracker.untrack(buf, { pos = { 2, 3 } })
  tracker.untrack(buf, { id = conv1, pos = { 2, 3 } })
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tracker"]["user_tick falls back to whole buffer"] = function()
  local buf = create_test_buffer({ "line 1", "line 2", "line 3" })
  local conv1 = 1

  -- Track whole buffer
  tracker.ensure_tracked(buf, { id = conv1 })

  -- Make an edit
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "modified line 1" })
  vim.wait(100)

  -- Query with a region should fall back to whole buffer tick
  eq(tracker.user_tick(buf, conv1, { pos = { 2, 3 } }), 1)

  -- Clean up
  tracker.untrack(buf, { id = conv1 })
  vim.api.nvim_buf_delete(buf, { force = true })
end
T["sia.tracker"]["user_tick returns -1 when no tracking information"] = function()
  local buf = create_test_buffer({ "line 1", "line 2" })
  local conv1 = 1
  local conv2 = 2

  -- No tracking at all should yield -1
  eq(tracker.user_tick(buf, conv1), -1)

  -- Track a region for another conversation only
  tracker.ensure_tracked(buf, { id = conv2, pos = { 1, 1 } })

  -- Still no info for conv1 or global, so user_tick should stay -1
  eq(tracker.user_tick(buf, conv1), -1)

  -- Clean up
  tracker.untrack(buf, { id = conv2, pos = { 1, 1 } })
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tracker"]["line number shifts invalidate regions below"] = function()
  local buf = create_test_buffer({ "line 1", "line 2", "line 3", "line 4", "line 5" })
  local conv1 = 1

  -- Track two regions: early and late
  tracker.ensure_tracked(buf, { id = conv1, pos = { 1, 2 } })
  tracker.ensure_tracked(buf, { id = conv1, pos = { 4, 5 } })

  -- Content-only edit on line 1 (no line delta)
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "modified line 1" })
  vim.wait(100)

  -- Only first region should be ticked
  eq(tracker.user_tick(buf, conv1, { pos = { 1, 2 } }), 1)
  eq(tracker.user_tick(buf, conv1, { pos = { 4, 5 } }), 0)

  -- Delete line 2 (line delta = -1)
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, {})
  vim.wait(100)

  -- First region ticked (overlaps), second region also ticked (line numbers shifted)
  eq(tracker.user_tick(buf, conv1, { pos = { 1, 2 } }), 2)
  eq(tracker.user_tick(buf, conv1, { pos = { 4, 5 } }), 1)

  -- Clean up
  tracker.untrack(buf, { id = conv1, pos = { 1, 2 } })
  tracker.untrack(buf, { id = conv1, pos = { 4, 5 } })
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tracker"]["edits after all regions don't invalidate"] = function()
  local buf = create_test_buffer({ "line 1", "line 2", "line 3", "line 4", "line 5" })
  local conv1 = 1

  -- Track early region
  tracker.ensure_tracked(buf, { id = conv1, pos = { 1, 2 } })

  -- Edit after the tracked region
  vim.api.nvim_buf_set_lines(buf, 4, 5, false, { "modified line 5" })
  vim.wait(100)

  -- Region should not be ticked
  eq(tracker.user_tick(buf, conv1, { pos = { 1, 2 } }), 0)

  -- Insert lines after the tracked region
  vim.api.nvim_buf_set_lines(buf, 4, 4, false, { "new line", "another new line" })
  vim.wait(100)

  -- Region should still not be ticked (line delta doesn't affect regions before the change)
  eq(tracker.user_tick(buf, conv1, { pos = { 1, 2 } }), 0)

  -- Clean up
  tracker.untrack(buf, { id = conv1, pos = { 1, 2 } })
  vim.api.nvim_buf_delete(buf, { force = true })
end

return T
