local M = {}

local RELOAD_FULL_RANGE = 2 ^ 31

--- @class sia.tracker.Options
--- @field pos [integer, integer]?
--- @field id integer?

--- @class sia.tracker.Region
--- @field id integer?
--- @field pos [integer, integer]?
--- @field tick integer
--- @field refcount integer

--- @class sia.tracker.BufferTracker
--- @field global sia.tracker.Region[]?
--- @field global_skip_tracking boolean
--- @field regions table<integer, sia.tracker.Region[]>
--- @field skip_tracking table<integer, boolean>
--- @field marked_for_deletion boolean

--- @type table<integer, sia.tracker.BufferTracker>
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

--- Update ticks for regions that overlap with the changed lines
--- @param tracker sia.tracker.BufferTracker
--- @param first integer 0-indexed, inclusive start line
--- @param last_old integer 0-indexed, exclusive end line (before change)
--- @param last_new integer 0-indexed, exclusive end line (after change)
local function update_tick(tracker, first, last_old, last_new)
  local change_start = first + 1
  local change_end = last_old
  local line_delta = last_new - last_old

  local function overlaps(region_start, region_end)
    return region_start <= (change_end - 1) and change_start <= region_end
  end

  for id, regions_array in pairs(tracker.regions) do
    if not tracker.skip_tracking[id] then
      for _, region in ipairs(regions_array) do
        if region.pos == nil then
          region.tick = region.tick + 1
        elseif overlaps(region.pos[1], region.pos[2]) then
          region.tick = region.tick + 1
        elseif line_delta ~= 0 and region.pos[1] > change_end then
          region.tick = region.tick + 1
        end
      end
    end
  end

  if tracker.global and not tracker.global_skip_tracking then
    for _, region in ipairs(tracker.global) do
      if region.pos == nil then
        region.tick = region.tick + 1
      elseif overlaps(region.pos[1], region.pos[2]) then
        region.tick = region.tick + 1
      elseif line_delta ~= 0 and region.pos[1] > change_end then
        region.tick = region.tick + 1
      end
    end
  end
end

local function attach(buf)
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function(_, _, _, first, last_old, last_new)
      local tracker = M.tracked_buffers[buf]
      if not tracker or tracker.marked_for_deletion then
        return true
      end
      update_tick(tracker, first, last_old, last_new)
    end,
    on_reload = function()
      local tracker = M.tracked_buffers[buf]
      if not tracker or tracker.marked_for_deletion then
        return
      end
      -- On reload, treat as if the entire buffer changed
      -- Use a large finite range to avoid math.huge - math.huge precision issues
      update_tick(tracker, 0, RELOAD_FULL_RANGE, RELOAD_FULL_RANGE)
    end,
    on_detach = function()
      M.tracked_buffers[buf] = nil
    end,
  })
end

--- Track a buffer or region for a conversation
--- @param buf integer
--- @param opts sia.tracker.Options?
--- @return integer current_tick
function M.ensure_tracked(buf, opts)
  opts = opts or {}
  local id = opts.id
  local pos = opts.pos

  if not should_track_buffer(buf) then
    return 0
  end

  if not M.tracked_buffers[buf] then
    M.tracked_buffers[buf] = {
      global = nil,
      global_skip_tracking = false,
      regions = {},
      skip_tracking = {},
      marked_for_deletion = false,
    }
    attach(buf)
  end

  local tracker = M.tracked_buffers[buf]
  if tracker.marked_for_deletion then
    tracker.marked_for_deletion = false
  end

  -- Get the appropriate regions array
  local regions_array
  if id then
    regions_array = tracker.regions[id]
    if not regions_array then
      regions_array = {}
      tracker.regions[id] = regions_array
    end
  else
    regions_array = tracker.global
    if not regions_array then
      regions_array = {}
      tracker.global = regions_array
    end
  end

  -- Check if already tracking whole buffer for this conversation
  local whole_buffer_region = nil
  for _, region in ipairs(regions_array) do
    if region.pos == nil then
      whole_buffer_region = region
      break
    end
  end

  -- If tracking whole buffer and trying to add a new region then we just increment
  -- whole buffer refcount
  if whole_buffer_region and pos then
    whole_buffer_region.refcount = whole_buffer_region.refcount + 1
    return whole_buffer_region.tick
  end

  -- If adding whole buffer when regions exist then we remove all regions
  if not pos and not whole_buffer_region then
    -- Inherit tick from global if this is a conversation tracking
    local inherited_tick = 0
    if id and tracker.global then
      for _, global_region in ipairs(tracker.global) do
        if global_region.pos == nil then
          inherited_tick = global_region.tick
          break
        end
      end
    end

    if id then
      tracker.regions[id] = {
        {
          id = id,
          pos = nil,
          tick = inherited_tick,
          refcount = 1,
        },
      }
    else
      tracker.global = {
        {
          id = nil,
          pos = nil,
          tick = 0,
          refcount = 1,
        },
      }
    end

    return inherited_tick
  end

  -- If buffer or region is already tracked we increment refcount
  if whole_buffer_region then
    whole_buffer_region.refcount = whole_buffer_region.refcount + 1
    return whole_buffer_region.tick
  end

  for _, region in ipairs(regions_array) do
    if region.pos and pos and region.pos[1] == pos[1] and region.pos[2] == pos[2] then
      region.refcount = region.refcount + 1
      return region.tick
    end
  end

  -- For new region we inherit tick from global if that exists
  local inherited_tick = 0
  if id and tracker.global then
    for _, region in ipairs(tracker.global) do
      if region.pos and pos and region.pos[1] == pos[1] and region.pos[2] == pos[2] then
        inherited_tick = region.tick
        break
      end
    end
  end

  table.insert(regions_array, {
    id = id,
    pos = pos,
    tick = inherited_tick,
    refcount = 1,
  })

  return inherited_tick
end

--- Untrack a buffer or region
--- @param buf integer
--- @param opts sia.tracker.Options? {pos, id}
function M.untrack(buf, opts)
  opts = opts or {}
  local id = opts.id
  local pos = opts.pos

  local tracker = M.tracked_buffers[buf]
  if not tracker or tracker.marked_for_deletion then
    return
  end

  local regions_array
  -- First try to find the regions for the provided id
  if id then
    regions_array = tracker.regions[id]
  end

  -- If id==nil, or there are no regions for id
  if not regions_array then
    id = nil -- ensure that we clean up global later
    regions_array = tracker.global
  end

  if not regions_array then
    return
  end

  for i, region in ipairs(regions_array) do
    local matches = false

    -- Check if we have a full region or perfect match
    if pos == nil and region.pos == nil then
      matches = true
    elseif
      pos
      and region.pos
      and pos[1] == region.pos[1]
      and pos[2] == region.pos[2]
    then
      matches = true
    end

    if matches then
      region.refcount = region.refcount - 1
      if region.refcount <= 0 then
        table.remove(regions_array, i)

        -- If no regions left for this conversation, clean up
        if #regions_array == 0 then
          if id then
            tracker.regions[id] = nil
          else
            tracker.global = nil
          end

          -- Check if any (other) conversation still has regions
          local has_any_tracking = tracker.global ~= nil
          if not has_any_tracking then
            for _, _ in pairs(tracker.regions) do
              has_any_tracking = true
              break
            end
          end

          if not has_any_tracking then
            tracker.marked_for_deletion = true
          end
        end
      end
      return
    end
  end
end

--- Execute a callback without tracking edits for a conversation
--- @param buf integer
--- @param id integer
--- @param callback fun():any
--- @return any
function M.without_tracking(buf, id, callback)
  local tracker = M.tracked_buffers[buf]
  if tracker then
    tracker.global_skip_tracking = true
    tracker.skip_tracking[id] = true
  end

  local ok, result = pcall(callback)

  if tracker then
    tracker.global_skip_tracking = false
    tracker.skip_tracking[id] = nil
  end

  if not ok then
    error(result)
  end

  return result
end

local function resolve_tick(regions, pos)
  if not regions then
    return nil
  end

  local fallback_tick
  for _, region in ipairs(regions) do
    if region.pos == nil then
      return region.tick
    end

    if pos and region.pos and region.pos[1] == pos[1] and region.pos[2] == pos[2] then
      return region.tick
    end

    if not fallback_tick or region.tick > fallback_tick then
      fallback_tick = region.tick
    end
  end

  return fallback_tick
end

--- Get the current tick for a buffer or region
--- @param buf integer
--- @param id integer conversation id
--- @param pos [integer,integer]?
--- @return integer tick
function M.user_tick(buf, id, pos)
  local tracker = M.tracked_buffers[buf]
  if not tracker or tracker.marked_for_deletion then
    return -1
  end

  local tick = resolve_tick(tracker.regions[id], pos)
    or resolve_tick(tracker.global, pos)

  if tick == nil then
    return -1
  end

  return tick
end

return M
