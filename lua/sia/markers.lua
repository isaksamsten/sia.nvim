local M = {}
local utils = require("sia.utils")

local OURS_PATTERN = "^<<<<<<< (%S+)"
local THEIRS_PATTERN = "^>>>>>>> (%S+)"
local DELIMITER_PATTERN = "^======="

local OURS_HEADER = 0
local OURS = 1
local DELIMITER = 2
local THEIRS = 3
local THEIRS_HEADER = 4

local HL_GROUPS = {
  [OURS_HEADER] = "SiaDiffDeleteHeader",
  [OURS] = "SiaDiffDelete",
  [THEIRS] = "SiaDiffChange",
  [THEIRS_HEADER] = "SiaDiffChangeHeader",
  [DELIMITER] = "SiaDiffDelimiter",
}

local MARKER_NAMESPACE = vim.api.nvim_create_namespace("SIA_MARKER")

local DIFF_WO = { "wrap", "linebreak", "breakindent", "breakindentopt", "showbreak" }

local timer = vim.uv.new_timer()
local cache = {}
local bufs_to_update = {}

local function find_conflict_under_cursor(positions)
  local pos = vim.fn.getpos(".")[2]
  for _, marker in pairs(positions) do
    if pos <= marker.after and pos >= marker.before then
      return marker
    end
  end
  return nil
end

function M.next()
  local pos = vim.fn.getpos(".")[2]
  local buf_cache = cache[vim.api.nvim_get_current_buf()]
  if buf_cache == nil or #buf_cache.positions == 0 then
    return
  end
  local closest = nil
  local min_positive_dist = nil
  local dist
  for _, marker in pairs(buf_cache.positions) do
    dist = marker.delimiter - pos
    if
      (dist > 0 and min_positive_dist == nil) or (min_positive_dist ~= nil and dist < min_positive_dist and dist > 0)
    then
      min_positive_dist = dist
      closest = marker.delimiter
    end
  end

  if closest ~= nil then
    vim.fn.cursor(closest, 0)
  end
end

function M.previous()
  local pos = vim.fn.getpos(".")[2]
  local buf_cache = cache[vim.api.nvim_get_current_buf()]
  if buf_cache == nil or #buf_cache.positions == 0 then
    return
  end
  local closest = nil
  local max_negative_dist = nil
  local dist
  for _, marker in pairs(buf_cache.positions) do
    dist = marker.delimiter - pos
    if
      (dist < 0 and max_negative_dist == nil) or (max_negative_dist ~= nil and dist > max_negative_dist and dist < 0)
    then
      max_negative_dist = dist
      closest = marker.delimiter
    end
  end

  if closest ~= nil then
    vim.fn.cursor(closest, 0)
  end
end

--- @param buf integer
function M.reject(buf)
  local buf_cache = cache[buf]
  if buf_cache == nil or #buf_cache.positions == 0 then
    return
  end
  local pos = find_conflict_under_cursor(buf_cache.positions)
  if pos then
    vim.api.nvim_buf_set_lines(
      buf,
      pos.before - 1,
      pos.after,
      false,
      vim.api.nvim_buf_get_lines(buf, pos.before, pos.delimiter - 1, false)
    )
  end
end

--- @param buf integer
function M.accept(buf)
  local buf_cache = cache[buf]
  if buf_cache == nil or #buf_cache.positions == 0 then
    return
  end
  local pos = find_conflict_under_cursor(buf_cache.positions)
  if pos then
    vim.api.nvim_buf_set_lines(
      buf,
      pos.before - 1,
      pos.after,
      false,
      vim.api.nvim_buf_get_lines(buf, pos.delimiter, pos.after - 1, false)
    )
  end
end

function M.diff(buf, opts)
  local buf_cache = cache[buf]
  if buf_cache == nil or #buf_cache.positions == 0 then
    return
  end
  local pos = find_conflict_under_cursor(buf_cache.positions)
  if pos then
    opts = opts or {}
    local win = vim.api.nvim_get_current_win()
    local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local current = vim.api.nvim_buf_get_lines(buf, pos.before, pos.delimiter - 1, false)
    local suggested = vim.api.nvim_buf_get_lines(buf, pos.delimiter, pos.after - 1, false)
    vim.cmd(opts.split or "vsplit")
    local diffwin = vim.api.nvim_get_current_win()
    local diffbuf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(diffwin, diffbuf)
    for _, opt in pairs(DIFF_WO) do
      vim.wo[diffwin][opt] = vim.wo[win][opt]
    end
    vim.bo[diffbuf].ft = vim.bo[buf].ft

    vim.api.nvim_buf_set_lines(buf, pos.before - 1, pos.after, false, current)
    vim.api.nvim_buf_set_lines(diffbuf, 0, -1, false, content)
    vim.api.nvim_buf_set_lines(diffbuf, pos.before - 1, pos.after, false, suggested)
    vim.api.nvim_set_current_win(diffwin)
    vim.cmd("diffthis")
    vim.api.nvim_set_current_win(win)
    vim.cmd("diffthis")
  end
end

local function update_buf_cache(buf)
  local buf_cache = cache[buf] or {}
  buf_cache.markers = buf_cache.markers or {}
  buf_cache.positions = buf_cache.positions or {}

  cache[buf] = buf_cache
end

local update_buf = vim.schedule_wrap(function(buf)
  local buf_cache = cache[buf]
  if buf_cache == nil then
    return
  end
  if not vim.api.nvim_buf_is_valid(buf) then
    cache[buf] = nil
    return
  end

  local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local markers = utils.partition_marker(content, {
    before = OURS_PATTERN,
    after = THEIRS_PATTERN,
    delimiter = DELIMITER_PATTERN,
    find_all = true,
  })

  buf_cache.markers = {}
  buf_cache.positions = {}
  for _, marker in ipairs(markers.all or {}) do
    local delimiter = marker.lnum + #marker.before + 1
    for i = marker.lnum, marker.lnum_end do
      buf_cache.markers[i] = {}
      if i == delimiter then
        buf_cache.markers[i].hl_group = DELIMITER
      elseif i < delimiter then
        buf_cache.markers[i].hl_group = OURS
      else
        buf_cache.markers[i].hl_group = THEIRS
      end
    end
    buf_cache.markers[marker.lnum] = { hl_group = OURS_HEADER, our_header = marker.before_tag }
    buf_cache.markers[marker.lnum_end] = { hl_group = THEIRS_HEADER, theirs_header = marker.after_tag }

    buf_cache.positions[#buf_cache.positions + 1] =
      { before = marker.lnum, after = marker.lnum_end, delimiter = delimiter }
  end
  buf_cache.needs_clear = true
end)

local process_scheduled_buffers = vim.schedule_wrap(function()
  for buf, _ in pairs(bufs_to_update) do
    update_buf(buf)
  end
  bufs_to_update = {}
end)

local schedule_marker_updates = vim.schedule_wrap(function(buf, delay)
  bufs_to_update[buf] = true
  timer:stop()
  timer:start(delay or 0, 0, process_scheduled_buffers)
end)

local function setup_autocommand(buf)
  local augroup = vim.api.nvim_create_augroup("SiaMarkers" .. buf, { clear = true })
  local buf_update = vim.schedule_wrap(function()
    update_buf_cache(buf)
  end)
  cache[buf].augroup = augroup
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = buf,
    group = augroup,
    callback = buf_update,
  })

  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "SiaEditPost",
    callback = function()
      schedule_marker_updates(buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufFilePost", {
    group = augroup,
    buffer = buf,
    callback = function(args)
      if cache[args.buf] ~= nil then
        M.disable(args.buf)
        M.enable(args.buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufDelete", {
    group = augroup,
    buffer = buf,
    callback = function(args)
      M.disable(args.buf)
    end,
  })
end

--- Clear all extmarks set for MARKER_NAMESPACE
local function clear_all_extarks(buf)
  pcall(vim.api.nvim_buf_clear_namespace, buf, MARKER_NAMESPACE, 0, -1)
end

--- Disable markers
function M.disable(buf)
  local buf_cache = cache[buf]
  if buf_cache == nil then
    return
  end
  buf_cache[buf] = nil

  pcall(vim.api.nvim_del_augroup_by_id, buf_cache.augroup)
  clear_all_extarks(buf)
end

function M.enable(buf)
  if vim.api.nvim_buf_is_loaded(buf) then
    -- enable the cache for buf
    update_buf_cache(buf)

    -- Add state watchers
    vim.api.nvim_buf_attach(buf, false, {
      on_lines = function(_, _, _, _, _, _, _, _, _)
        local buf_cache = cache[buf]
        if buf_cache == nil then
          return true
        end
        schedule_marker_updates(buf, 200)
      end,
      on_reload = function()
        schedule_marker_updates(buf)
      end,
      on_detach = function()
        M.disable(buf)
      end,
    })

    setup_autocommand(buf)
    schedule_marker_updates(buf, 0)
  end
end

local function set_decoration_provider(ns_id)
  vim.api.nvim_set_decoration_provider(ns_id, {
    on_win = function(_, _, buf, toprow, botrow)
      local buf_cache = cache[buf]
      if buf_cache == nil then
        return false
      end
      if buf_cache.needs_clear then
        buf_cache.needs_clear = nil
        clear_all_extarks(buf)
      end
      if vim.wo.diff then
        clear_all_extarks(buf)
        return
      end

      local markers = buf_cache.markers
      for i = toprow + 1, botrow + 1 do
        if markers[i] ~= nil then
          local extmark_opts = {
            hl_eol = true,
            hl_mode = "combine",
            end_row = i,
            hl_group = HL_GROUPS[markers[i].hl_group],
          }
          vim.api.nvim_buf_set_extmark(buf, MARKER_NAMESPACE, i - 1, 0, extmark_opts)

          if markers[i].our_header then
            vim.api.nvim_buf_set_extmark(buf, MARKER_NAMESPACE, i - 1, 0, {
              hl_eol = true,
              end_row = i,
              virt_text_pos = "overlay",
              virt_text = {
                { string.format("<<<<<<< %s (Current change)", markers[i].our_header), "SiaDiffDeleteHeader" },
              },
            })
          elseif markers[i].theirs_header then
            vim.api.nvim_buf_set_extmark(buf, MARKER_NAMESPACE, i - 1, 0, {
              hl_eol = true,
              end_row = i,
              virt_text_pos = "overlay",
              virt_text = {
                { string.format(">>>>>>> %s (Incoming change)", markers[i].theirs_header), "SiaDiffChangeHeader" },
              },
            })
          end
          markers[i] = nil
        end
      end
    end,
  })
end

local auto_enable = vim.schedule_wrap(function(data)
  local buf = data.buf

  -- The buffer has already been enabled.
  if cache[buf] ~= nil then
    return
  end

  if not (vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "" and vim.bo[buf].buflisted) then
    return
  end
  M.enable(buf)
end)

function M.setup()
  set_decoration_provider(MARKER_NAMESPACE)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    auto_enable({ buf = bufnr })
  end

  local augroup = vim.api.nvim_create_augroup("SiaMarkers", { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    callback = auto_enable,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = augroup,
    callback = function(args)
      for buf, _ in pairs(cache) do
        if vim.api.nvim_buf_is_valid(buf) then
          clear_all_extarks(buf)
          schedule_marker_updates(buf, 0)
        end
      end
    end,
  })
end

return M
