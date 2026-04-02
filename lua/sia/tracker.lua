local RELOAD_FULL_RANGE = 2 ^ 31

--- @class sia.tracker.Options
--- @field pos [integer, integer]?
--- @field id integer?
--- @field global boolean?

--- @class sia.tracker.Region
--- @field id integer?
--- @field pos [integer, integer]?
--- @field tick integer
--- @field refcount integer

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

--- @class sia.Tracker
--- @field buffers table<integer, sia.tracker.Region[]>
--- @field suppressed table<integer, boolean>
local Tracker = {}
Tracker.__index = Tracker

--- @type table<integer, sia.Tracker[]>
local buf_listeners = {}

--- @type table<integer, boolean>
local buf_attached = {}

--- @param regions sia.tracker.Region[]
--- @param first integer
--- @param last_old integer
--- @param last_new integer
local function update_tracker_ticks(regions, first, last_old, last_new)
  local change_start = first + 1
  local change_end = last_old
  local line_delta = last_new - last_old

  local function overlaps(region_start, region_end)
    return region_start <= change_end and change_start <= region_end
  end

  for _, region in ipairs(regions) do
    if region.pos == nil then
      region.tick = region.tick + 1
    elseif overlaps(region.pos[1], region.pos[2]) then
      region.tick = region.tick + 1
    elseif line_delta ~= 0 and region.pos[1] > change_end then
      region.tick = region.tick + 1
    end
  end
end

--- @param buf integer
local function shared_attach(buf)
  if buf_attached[buf] then
    return
  end
  buf_attached[buf] = true

  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function(_, _, _, first, last_old, last_new)
      local listeners = buf_listeners[buf]
      if not listeners or #listeners == 0 then
        buf_attached[buf] = nil
        buf_listeners[buf] = nil
        return true
      end
      for _, t in ipairs(listeners) do
        if not t.suppressed[buf] then
          local regions = t.buffers[buf]
          if regions then
            update_tracker_ticks(regions, first, last_old, last_new)
          end
        end
      end
    end,
    on_reload = function()
      local listeners = buf_listeners[buf]
      if not listeners or #listeners == 0 then
        return
      end
      for _, t in ipairs(listeners) do
        if not t.suppressed[buf] then
          local regions = t.buffers[buf]
          if regions then
            update_tracker_ticks(regions, 0, RELOAD_FULL_RANGE, RELOAD_FULL_RANGE)
          end
        end
      end
    end,
    on_detach = function()
      local listeners = buf_listeners[buf]
      if listeners then
        for _, t in ipairs(listeners) do
          t.buffers[buf] = nil
          t.suppressed[buf] = nil
        end
      end
      buf_listeners[buf] = nil
      buf_attached[buf] = nil
    end,
  })
end

--- @param buf integer
--- @param t sia.Tracker
local function register_listener(buf, t)
  if not buf_listeners[buf] then
    buf_listeners[buf] = {}
  end
  for _, existing in ipairs(buf_listeners[buf]) do
    if existing == t then
      return
    end
  end
  table.insert(buf_listeners[buf], t)
  shared_attach(buf)
end

--- @param buf integer
--- @param t sia.Tracker
local function unregister_listener(buf, t)
  local listeners = buf_listeners[buf]
  if not listeners then
    return
  end
  for i, existing in ipairs(listeners) do
    if existing == t then
      table.remove(listeners, i)
      break
    end
  end
end

--- @return sia.Tracker
function Tracker.new()
  return setmetatable({
    buffers = {},
    suppressed = {},
  }, Tracker)
end

--- @param buf integer
--- @param pos [integer, integer]?
--- @return integer tick
function Tracker:track(buf, pos)
  if not should_track_buffer(buf) then
    return 0
  end

  if not self.buffers[buf] then
    self.buffers[buf] = {}
    register_listener(buf, self)
  end

  local regions = self.buffers[buf]

  local whole_buffer_region = nil
  for _, region in ipairs(regions) do
    if region.pos == nil then
      whole_buffer_region = region
      break
    end
  end

  -- If tracking whole buffer and adding a specific region, just increment refcount
  if whole_buffer_region and pos then
    whole_buffer_region.refcount = whole_buffer_region.refcount + 1
    return whole_buffer_region.tick
  end

  -- If adding whole buffer when regions exist, replace with single whole-buffer entry
  if not pos and not whole_buffer_region then
    self.buffers[buf] = {
      { pos = nil, tick = 0, refcount = 1 },
    }
    return 0
  end

  -- If whole buffer already tracked, increment refcount
  if whole_buffer_region then
    whole_buffer_region.refcount = whole_buffer_region.refcount + 1
    return whole_buffer_region.tick
  end

  -- Check for exact region match
  for _, region in ipairs(regions) do
    if region.pos and pos and region.pos[1] == pos[1] and region.pos[2] == pos[2] then
      region.refcount = region.refcount + 1
      return region.tick
    end
  end

  -- New region
  table.insert(regions, {
    pos = pos,
    tick = 0,
    refcount = 1,
  })

  return 0
end

--- @param buf integer
--- @param tick integer
--- @param pos [integer, integer]?
--- @return boolean
function Tracker:is_stale(buf, tick, pos)
  local regions = self.buffers[buf]
  if not regions then
    return false
  end

  for _, region in ipairs(regions) do
    if region.pos == nil then
      return region.tick ~= tick
    end
    if pos and region.pos and region.pos[1] == pos[1] and region.pos[2] == pos[2] then
      return region.tick ~= tick
    end
  end

  return false
end

--- @param buf integer
--- @param pos [integer, integer]?
function Tracker:untrack(buf, pos)
  local regions = self.buffers[buf]
  if not regions then
    return
  end

  for i, region in ipairs(regions) do
    local matches = false
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
        table.remove(regions, i)
        if #regions == 0 then
          self.buffers[buf] = nil
          self.suppressed[buf] = nil
          unregister_listener(buf, self)
        end
      end
      return
    end
  end
end

--- @param buf integer
--- @param fn fun():any
--- @return any
function Tracker:suppress(buf, fn)
  self.suppressed[buf] = true
  local ok, result = pcall(fn)
  self.suppressed[buf] = nil
  if not ok then
    error(result)
  end
  return result
end

function Tracker:destroy()
  for buf, _ in pairs(self.buffers) do
    unregister_listener(buf, self)
  end
  self.buffers = {}
  self.suppressed = {}
end

return Tracker
