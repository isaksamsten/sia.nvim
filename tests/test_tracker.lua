local Tracker = require("sia.tracker")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["sia.tracker"] = MiniTest.new_set()

local function create_test_buffer(lines)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, "test_" .. buf .. ".lua")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

T["sia.tracker"]["track returns tick 0 for new whole-buffer tracking"] = function()
  local buf = create_test_buffer({ "line 1", "line 2" })
  local tracker = Tracker.new()

  local tick = tracker:track(buf)
  eq(0, tick)
  eq(true, tracker.buffers[buf] ~= nil)

  tracker:destroy()
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tracker"]["refcounting tracks and untracks"] = function()
  local buf = create_test_buffer({ "line 1", "line 2" })
  local tracker = Tracker.new()

  -- First track
  local tick1 = tracker:track(buf)
  eq(0, tick1)
  eq(1, tracker.buffers[buf][1].refcount)

  -- Second track increments refcount
  local tick2 = tracker:track(buf)
  eq(0, tick2)
  eq(2, tracker.buffers[buf][1].refcount)

  -- First untrack decrements
  tracker:untrack(buf)
  eq(1, tracker.buffers[buf][1].refcount)

  -- Second untrack cleans up
  tracker:untrack(buf)
  eq(nil, tracker.buffers[buf])

  tracker:destroy()
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tracker"]["refcounting handles multiple buffers"] = function()
  local buf1 = create_test_buffer({ "buffer 1" })
  local buf2 = create_test_buffer({ "buffer 2" })
  local tracker = Tracker.new()

  tracker:track(buf1)
  tracker:track(buf2)
  tracker:track(buf1) -- buf1 now has refcount 2

  eq(2, tracker.buffers[buf1][1].refcount)
  eq(1, tracker.buffers[buf2][1].refcount)

  tracker:untrack(buf1)
  eq(1, tracker.buffers[buf1][1].refcount)
  eq(1, tracker.buffers[buf2][1].refcount)

  tracker:untrack(buf2)
  eq(nil, tracker.buffers[buf2])
  eq(1, tracker.buffers[buf1][1].refcount)

  tracker:untrack(buf1)
  eq(nil, tracker.buffers[buf1])

  tracker:destroy()
  vim.api.nvim_buf_delete(buf1, { force = true })
  vim.api.nvim_buf_delete(buf2, { force = true })
end

T["sia.tracker"]["untrack on non-tracked buffer is safe"] = function()
  local buf = create_test_buffer({ "test" })
  local tracker = Tracker.new()

  -- Should not error
  tracker:untrack(buf)
  eq(nil, tracker.buffers[buf])

  tracker:destroy()
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tracker"]["is_stale detects changes to whole buffer"] = function()
  local buf = create_test_buffer({ "line 1", "line 2", "line 3" })
  local tracker = Tracker.new()

  local tick = tracker:track(buf)
  eq(false, tracker:is_stale(buf, tick))

  -- Make an edit
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "modified line 1" })
  vim.wait(100)

  -- Tick should now be stale
  eq(true, tracker:is_stale(buf, tick))

  tracker:destroy()
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tracker"]["suppress prevents tick increment during edits"] = function()
  local buf = create_test_buffer({ "line 1", "line 2", "line 3" })
  local tracker = Tracker.new()

  local tick = tracker:track(buf)

  -- Edit inside suppress should not increment tick
  tracker:suppress(buf, function()
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "modified line 1" })
  end)

  eq(false, tracker:is_stale(buf, tick))

  -- Edit outside suppress should increment tick
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "modified line 2" })
  vim.wait(100)

  eq(true, tracker:is_stale(buf, tick))

  tracker:destroy()
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tracker"]["region tracking"] = function()
  local buf = create_test_buffer({ "line 1", "line 2", "line 3", "line 4", "line 5" })
  local tracker = Tracker.new()

  -- Track two different regions
  local tick1 = tracker:track(buf, { 2, 4 })
  local tick2 = tracker:track(buf, { 1, 2 })

  eq(0, tick1)
  eq(0, tick2)

  -- Edit inside first region (line 3)
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "modified line 3" })
  vim.wait(100)

  -- First region should be stale, second should not
  eq(true, tracker:is_stale(buf, tick1, { 2, 4 }))
  eq(false, tracker:is_stale(buf, tick2, { 1, 2 }))

  -- Edit overlapping both regions (line 2)
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "modified line 2" })
  vim.wait(100)

  -- Both regions should be stale now
  eq(true, tracker:is_stale(buf, tick1, { 2, 4 }))
  eq(true, tracker:is_stale(buf, tick2, { 1, 2 }))

  tracker:destroy()
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tracker"]["whole buffer overrides regions"] = function()
  local buf = create_test_buffer({ "line 1", "line 2", "line 3" })
  local tracker = Tracker.new()

  -- Track a region first
  tracker:track(buf, { 1, 2 })

  -- Now track whole buffer - should replace with single whole-buffer entry
  local tick = tracker:track(buf)
  eq(0, tick)

  -- Should have one entry (whole buffer)
  eq(1, #tracker.buffers[buf])
  eq(nil, tracker.buffers[buf][1].pos)

  -- Edit anywhere should be detected
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "modified line 3" })
  vim.wait(100)

  eq(true, tracker:is_stale(buf, tick))

  tracker:destroy()
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tracker"]["line number shifts invalidate regions below"] = function()
  local buf = create_test_buffer({ "line 1", "line 2", "line 3", "line 4", "line 5" })
  local tracker = Tracker.new()

  -- Track two regions: early and late
  local tick1 = tracker:track(buf, { 1, 2 })
  local tick2 = tracker:track(buf, { 4, 5 })

  -- Content-only edit on line 1 (no line delta)
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "modified line 1" })
  vim.wait(100)

  -- Only first region should be stale
  eq(true, tracker:is_stale(buf, tick1, { 1, 2 }))
  eq(false, tracker:is_stale(buf, tick2, { 4, 5 }))

  -- Delete line 2 (line delta = -1)
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, {})
  vim.wait(100)

  -- First region ticked again (overlaps), second region also ticked (line numbers shifted)
  eq(true, tracker:is_stale(buf, tick1, { 1, 2 }))
  eq(true, tracker:is_stale(buf, tick2, { 4, 5 }))

  tracker:destroy()
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tracker"]["edits after all regions don't invalidate"] = function()
  local buf = create_test_buffer({ "line 1", "line 2", "line 3", "line 4", "line 5" })
  local tracker = Tracker.new()

  -- Track early region
  local tick = tracker:track(buf, { 1, 2 })

  -- Edit after the tracked region (content only, no line shift)
  vim.api.nvim_buf_set_lines(buf, 4, 5, false, { "modified line 5" })
  vim.wait(100)

  -- Region should not be stale
  eq(false, tracker:is_stale(buf, tick, { 1, 2 }))

  tracker:destroy()
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tracker"]["multiple trackers are independent"] = function()
  local buf = create_test_buffer({ "line 1", "line 2", "line 3" })
  local tracker1 = Tracker.new()
  local tracker2 = Tracker.new()

  local tick1 = tracker1:track(buf)
  local tick2 = tracker2:track(buf)

  -- Suppress on tracker1 should not affect tracker2
  tracker1:suppress(buf, function()
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "modified line 1" })
  end)
  vim.wait(100)

  eq(false, tracker1:is_stale(buf, tick1))
  eq(true, tracker2:is_stale(buf, tick2))

  tracker1:destroy()
  tracker2:destroy()
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tracker"]["destroy cleans up all tracking"] = function()
  local buf = create_test_buffer({ "line 1", "line 2" })
  local tracker = Tracker.new()

  tracker:track(buf)
  tracker:track(buf, { 1, 1 })
  eq(true, tracker.buffers[buf] ~= nil)

  tracker:destroy()
  eq(true, vim.tbl_isempty(tracker.buffers))

  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tracker"]["duplicate region tracking increments refcount"] = function()
  local buf = create_test_buffer({ "line 1", "line 2", "line 3" })
  local tracker = Tracker.new()

  local tick1 = tracker:track(buf, { 1, 2 })
  local tick2 = tracker:track(buf, { 1, 2 })

  eq(tick1, tick2)
  eq(2, tracker.buffers[buf][1].refcount)

  -- Untrack once, should still be tracked
  tracker:untrack(buf, { 1, 2 })
  eq(1, tracker.buffers[buf][1].refcount)

  -- Untrack again, should be gone
  tracker:untrack(buf, { 1, 2 })
  eq(nil, tracker.buffers[buf])

  tracker:destroy()
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tracker"]["whole buffer tracking after region adds refcount"] = function()
  local buf = create_test_buffer({ "line 1", "line 2", "line 3" })
  local tracker = Tracker.new()

  -- Track whole buffer first
  tracker:track(buf)
  eq(1, tracker.buffers[buf][1].refcount)

  -- Adding a region when whole buffer already tracked just bumps refcount
  local tick = tracker:track(buf, { 1, 2 })
  eq(0, tick)
  eq(2, tracker.buffers[buf][1].refcount)

  tracker:destroy()
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tracker"]["is_stale returns false for untracked buffer"] = function()
  local buf = create_test_buffer({ "line 1" })
  local tracker = Tracker.new()

  -- No tracking at all
  eq(false, tracker:is_stale(buf, 0))
  eq(false, tracker:is_stale(buf, 0, { 1, 1 }))

  tracker:destroy()
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tracker"]["suppress error propagation"] = function()
  local buf = create_test_buffer({ "line 1", "line 2" })
  local tracker = Tracker.new()

  tracker:track(buf)

  -- Errors in suppress should be re-raised
  local ok, err = pcall(function()
    tracker:suppress(buf, function()
      error("intentional error")
    end)
  end)

  eq(false, ok)
  eq(true, string.find(err, "intentional error") ~= nil)

  -- Buffer should no longer be suppressed after error
  eq(nil, tracker.suppressed[buf])

  tracker:destroy()
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tracker"]["insertions after region do not invalidate with line delta"] = function()
  local buf = create_test_buffer({ "line 1", "line 2", "line 3", "line 4", "line 5" })
  local tracker = Tracker.new()

  local tick = tracker:track(buf, { 1, 2 })

  -- Insert lines after the tracked region (line delta but no overlap)
  vim.api.nvim_buf_set_lines(buf, 4, 4, false, { "new line", "another new line" })
  vim.wait(100)

  -- Region should not be stale (change is entirely after region)
  eq(false, tracker:is_stale(buf, tick, { 1, 2 }))

  tracker:destroy()
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tracker"]["insertions before region invalidate it"] = function()
  local buf = create_test_buffer({ "line 1", "line 2", "line 3", "line 4", "line 5" })
  local tracker = Tracker.new()

  local tick = tracker:track(buf, { 4, 5 })

  -- Insert lines before the tracked region
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "inserted line" })
  vim.wait(100)

  -- Region should be stale (line numbers shifted)
  eq(true, tracker:is_stale(buf, tick, { 4, 5 }))

  tracker:destroy()
  vim.api.nvim_buf_delete(buf, { force = true })
end

return T
