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

T["sia.tracker"]["untrack with id never touches global"] = function()
  local buf = create_test_buffer({ "line 1", "line 2", "line 3" })
  local conv1 = 1

  -- Track globally (simulating initial user message with pos={1,1})
  tracker.ensure_tracked(buf, { pos = { 1, 1 } })
  eq(tracker.tracked_buffers[buf].global[1].refcount, 1)

  -- Track conv1 whole buffer (simulating read tool)
  tracker.ensure_tracked(buf, { id = conv1 })

  -- Untrack conv1 (simulating dropped message)
  tracker.untrack(buf, { id = conv1 })
  -- conv1 regions should be cleaned up
  eq(tracker.tracked_buffers[buf].regions[conv1], nil)

  -- A second untrack with id=conv1 must NOT touch global at all
  tracker.untrack(buf, { id = conv1 })
  -- Global should still exist!
  eq(tracker.tracked_buffers[buf].global ~= nil, true)
  eq(tracker.tracked_buffers[buf].global[1].refcount, 1)

  -- Also test with pos — conv-specific untrack with pos must not touch global
  tracker.untrack(buf, { id = conv1, pos = { 1, 1 } })
  eq(tracker.tracked_buffers[buf].global ~= nil, true)
  eq(tracker.tracked_buffers[buf].global[1].refcount, 1)

  -- Clean up
  tracker.untrack(buf, { pos = { 1, 1 } })
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tracker"]["ensure_tracked inherits max global tick for whole buffer"] = function()
  local buf = create_test_buffer({ "line 1", "line 2", "line 3", "line 4", "line 5" })
  local conv1 = 1

  -- Global tracks pos={1,1} (initial user message from normal mode on line 1)
  tracker.ensure_tracked(buf, { pos = { 1, 1 } })

  -- LLM reads file (whole buffer, conv-specific), tick starts at 0
  local read_tick = tracker.ensure_tracked(buf, { id = conv1 })
  eq(read_tick, 0)

  -- LLM makes edits via without_tracking (doesn't increment ticks)
  tracker.without_tracking(buf, conv1, function()
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "modified line 1" })
  end)
  vim.wait(100)

  -- Untrack the read (simulating set_message_status("outdated"))
  tracker.untrack(buf, { id = conv1 })

  -- External edits happen (undo, user edits, etc.) incrementing global
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "line 1 v2" })
  vim.wait(100)
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "line 1 v3" })
  vim.wait(100)
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "line 1 v4" })
  vim.wait(100)
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "line 1" })
  vim.wait(100)

  -- Global tick for pos={1,1} is now 4
  eq(tracker.tracked_buffers[buf].global[1].tick, 4)

  -- LLM reads file again (whole buffer, conv-specific)
  local new_tick = tracker.ensure_tracked(buf, { id = conv1 })
  local ut = tracker.user_tick(buf, conv1)

  -- CRITICAL: ensure_tracked must return same tick as user_tick,
  -- otherwise the message is immediately outdated.
  -- The bug: ensure_tracked only inherits from global whole-buffer (pos=nil),
  -- but global only has pos={1,1}. So it returns 0.
  -- user_tick falls back to global's max tick (4).
  eq(new_tick, ut)

  -- Clean up
  tracker.untrack(buf, { id = conv1 })
  tracker.untrack(buf, { pos = { 1, 1 } })
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tracker"]["re-ensure_tracked on existing conv region inherits updated global"] = function()
  local buf = create_test_buffer({ "line 1", "line 2", "line 3" })
  local conv1 = 1

  -- Global tracks pos={1,1}
  tracker.ensure_tracked(buf, { pos = { 1, 1 } })

  -- Conv tracks whole buffer, inherits 0
  tracker.ensure_tracked(buf, { id = conv1 })

  -- External edits increment global tick
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "modified line 1" })
  vim.wait(100)
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "line 1 again" })
  vim.wait(100)

  eq(tracker.tracked_buffers[buf].global[1].tick, 2)

  -- Re-call ensure_tracked for the same conv (simulating second read tool call).
  -- The existing whole-buffer region has tick=0 (conv was skipped during edits
  -- if without_tracking was used, or the edits didn't match). But global advanced.
  -- ensure_tracked should return a tick consistent with user_tick.
  local tick = tracker.ensure_tracked(buf, { id = conv1 })
  local ut = tracker.user_tick(buf, conv1)
  eq(tick, ut)

  -- Clean up
  tracker.untrack(buf, { id = conv1 })
  tracker.untrack(buf, { id = conv1 }) -- second refcount
  tracker.untrack(buf, { pos = { 1, 1 } })
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tracker"]["ensure_tracked inherits fallback tick from global region"] = function()
  -- Reproduces the bug scenario:
  -- 1. Chat starts, global tracks pos={13,13}
  -- 2. LLM reads file (whole buffer, conv-specific) -> ensure_tracked returns 0
  -- 3. LLM makes edits via without_tracking
  -- 4. Messages get untracked (dropped/outdated), conv regions cleared
  -- 5. User undoes changes, global tick increments to 2
  -- 6. LLM reads file again -> ensure_tracked should return tick consistent with user_tick
  --
  -- The bug: ensure_tracked only inherits from global whole-buffer (pos=nil),
  -- but global only has pos={13,13}. So it returns 0.
  -- user_tick falls back to global's fallback tick (2), causing immediate "outdated".

  local buf = create_test_buffer({
    "line 1",
    "line 2",
    "line 3",
    "line 4",
    "line 5",
    "line 6",
    "line 7",
    "line 8",
    "line 9",
    "line 10",
    "line 11",
    "line 12",
    "line 13",
  })
  local conv1 = 1

  -- Step 1: Global tracks pos={13,13} (user cursor on line 13)
  tracker.ensure_tracked(buf, { pos = { 13, 13 } })

  -- Step 2: LLM reads file (whole buffer for conv1)
  local tick = tracker.ensure_tracked(buf, { id = conv1 })
  eq(tick, 0)

  -- Step 3: LLM makes edits via without_tracking
  tracker.without_tracking(buf, conv1, function()
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "modified line 1" })
  end)
  vim.wait(100)

  -- Step 4: Message gets untracked (simulating set_message_status("dropped"))
  tracker.untrack(buf, { id = conv1 })
  eq(tracker.tracked_buffers[buf].regions[conv1], nil)

  -- Step 5: User undoes changes (two edits that increment global tick)
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "line 1 undo 1" })
  vim.wait(100)
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "line 1" })
  vim.wait(100)

  -- Verify global tick is 2
  eq(tracker.tracked_buffers[buf].global[1].tick, 2)
  -- Verify state matches the reported bug scenario
  eq(#vim.tbl_keys(tracker.tracked_buffers[buf].regions), 0)

  -- Step 6: LLM reads file again (whole buffer for conv1)
  local new_tick = tracker.ensure_tracked(buf, { id = conv1 })
  local ut = tracker.user_tick(buf, conv1)

  -- CRITICAL: ensure_tracked must return same tick as user_tick
  eq(new_tick, ut)

  -- Both should be 2 (inherited from global's fallback)
  eq(new_tick, 2)

  -- Clean up
  tracker.untrack(buf, { id = conv1 })
  tracker.untrack(buf, { pos = { 13, 13 } })
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tracker"]["untrack with id+pos is no-op when conv regions absent"] = function()
  -- With tracker_id stored in context, untrack always uses the correct id.
  -- When conv regions don't exist, untrack with id simply returns (no fallthrough).
  -- This test verifies that global tracking is never accidentally destroyed.

  local buf = create_test_buffer({
    "line 1",
    "line 2",
    "line 3",
    "line 4",
    "line 5",
    "line 6",
    "line 7",
    "line 8",
    "line 9",
    "line 10",
    "line 11",
    "line 12",
    "line 13",
  })
  local conv1 = 1

  -- Step 1: Global tracks pos={13,13}
  tracker.ensure_tracked(buf, { pos = { 13, 13 } })
  eq(tracker.tracked_buffers[buf].global[1].tick, 0)

  -- Step 2: LLM reads file → tracks whole buffer for conv1
  tracker.ensure_tracked(buf, { id = conv1 })

  -- Step 3: LLM makes edits via without_tracking
  tracker.without_tracking(buf, conv1, function()
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "modified line 1" })
  end)
  vim.wait(100)

  -- Messages get dropped → conv1 regions untracked
  tracker.untrack(buf, { id = conv1 })
  eq(tracker.tracked_buffers[buf].regions[conv1], nil)

  -- Step 4: User undoes changes
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "line 1 undo 1" })
  vim.wait(100)
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "line 1" })
  vim.wait(100)
  eq(tracker.tracked_buffers[buf].global[1].tick, 2)

  -- Step 5-6: mark_outdated_messages finds initial context message outdated
  -- and calls untrack(buf, {id=conv1, pos={13,13}})
  -- This MUST NOT fall through to global and destroy it!
  tracker.untrack(buf, { id = conv1, pos = { 13, 13 } })

  -- Global must still exist
  eq(tracker.tracked_buffers[buf].global ~= nil, true)
  eq(tracker.tracked_buffers[buf].global[1].tick, 2)
  eq(tracker.tracked_buffers[buf].global[1].refcount, 1)
  eq(tracker.tracked_buffers[buf].marked_for_deletion, false)

  -- Step 7: LLM reads file again
  local tick = tracker.ensure_tracked(buf, { id = conv1 })
  local ut = tracker.user_tick(buf, conv1)

  -- Both must agree and not be -1
  eq(tick, ut)
  eq(tick >= 0, true)

  -- Clean up
  tracker.untrack(buf, { id = conv1 })
  tracker.untrack(buf, { pos = { 13, 13 } })
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tracker"]["global untrack does not require conversation id"] = function()
  local buf = create_test_buffer({ "line 1", "line 2", "line 3" })

  -- Track globally (nil id, simulating initial user context)
  tracker.ensure_tracked(buf, { pos = { 1, 2 } })
  eq(tracker.tracked_buffers[buf].global ~= nil, true)
  eq(tracker.tracked_buffers[buf].global[1].refcount, 1)

  -- Untrack globally (nil id) — should work
  tracker.untrack(buf, { pos = { 1, 2 } })
  eq(tracker.tracked_buffers[buf].marked_for_deletion, true)

  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tracker"]["conv-specific untrack does not affect other conversations"] = function()
  local buf = create_test_buffer({ "line 1", "line 2", "line 3" })
  local conv1 = 1
  local conv2 = 2

  -- Track globally
  tracker.ensure_tracked(buf, { pos = { 1, 1 } })

  -- Track for both conversations
  tracker.ensure_tracked(buf, { id = conv1 })
  tracker.ensure_tracked(buf, { id = conv2 })

  -- Untrack conv1 — should not affect conv2 or global
  tracker.untrack(buf, { id = conv1 })
  eq(tracker.tracked_buffers[buf].regions[conv1], nil)
  eq(tracker.tracked_buffers[buf].regions[conv2] ~= nil, true)
  eq(tracker.tracked_buffers[buf].global ~= nil, true)
  eq(tracker.tracked_buffers[buf].marked_for_deletion, false)

  -- Untrack conv2 — should not affect global
  tracker.untrack(buf, { id = conv2 })
  eq(tracker.tracked_buffers[buf].regions[conv2], nil)
  eq(tracker.tracked_buffers[buf].global ~= nil, true)
  eq(tracker.tracked_buffers[buf].marked_for_deletion, false)

  -- Clean up
  tracker.untrack(buf, { pos = { 1, 1 } })
  vim.api.nvim_buf_delete(buf, { force = true })
end

return T
