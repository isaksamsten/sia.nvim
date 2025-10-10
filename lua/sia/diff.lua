local M = {}

--- @type vim.diff.Opts
local DIFF_OPTS = {
  result_type = "indices",
}
local MAX_DISTANCE = 2 ^ 31 - 1
local MIN_LINE_LENGTH = 3
local MAX_LINE_LENGTH = 200
local REGION_GAP = 5

--- @class sia.diff.Reference
--- @field old_lines string[] Lines removed from baseline (empty for additions)
--- @field new_lines string[] Lines added in reference (empty for deletions)
--- @field old_start number Original line number in baseline where change was applied
--- @field new_start number Original line number in reference where change was applied

--- @class sia.diff.Hunk
--- @field old_start integer
--- @field old_count integer
--- @field new_start integer
--- @field new_count integer
--- @field type "change"|"add"|"delete"
--- @field char_hunks table<integer, sia.diff.Hunk[]>? Map from line offset (1-based) to character-level changes for that line pair

--- @class sia.diff.DiffState
--- @field baseline string[]
--- @field reference string[]
--- @field reference_hunks sia.diff.Hunk[]?
--- @field baseline_hunks sia.diff.Hunk[]?
--- @field markers table<integer,{col:integer?, args: vim.api.keyset.set_extmark}[]?>?
--- @field needs_clear boolean?
--- @field autocommand_group integer?
--- @field reference_cache sia.diff.Reference[]? Cached ranges from baseline to reference

--- @type table<integer, sia.diff.DiffState>
local buffer_diff_state = {}
local diff_ns = vim.api.nvim_create_namespace("sia_diff")

local update_timer = vim.uv.new_timer()

local bufs_to_update = {}

vim.api.nvim_set_decoration_provider(diff_ns, {
  on_win = function(_, _, buf, toprow, botrow)
    local state = buffer_diff_state[buf]
    if not state then
      return
    end
    if state.needs_clear then
      state.needs_clear = nil
      vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)
    end
    if vim.wo.diff then
      vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)
      return
    end

    local markers = state.markers
    if not markers then
      return
    end

    if vim.tbl_isempty(markers) then
      return
    end

    for i = toprow + 1, botrow + 1 do
      local line_markers = markers[i]
      if line_markers then
        for _, line_marker in ipairs(line_markers) do
          vim.api.nvim_buf_set_extmark(
            buf,
            diff_ns,
            i - 1,
            line_marker.col or 0,
            line_marker.args
          )
        end
      end
      markers[i] = nil
    end
  end,
})

--- @param buf integer
local redraw_buffer = function(buf)
  vim.api.nvim__buf_redraw_range(buf, 0, -1)
  vim.cmd("redrawstatus")
end

if vim.api.nvim__redraw ~= nil then
  redraw_buffer = function(buf)
    vim.api.nvim__redraw({ buf = buf, valid = true, statusline = true })
  end
end

--- Clean up automatic diff updates for a buffer
--- @param buf integer Buffer handle
local function cleanup_auto_diff_updates(buf)
  local diff_state = buffer_diff_state[buf]
  if diff_state and diff_state.autocommand_group then
    vim.api.nvim_del_augroup_by_id(diff_state.autocommand_group)
    diff_state.autocommand_group = nil
  end
end

local function cleanup_diff_state(buf)
  if not buffer_diff_state[buf] then
    return
  end
  cleanup_auto_diff_updates(buf)
  vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)
  buffer_diff_state[buf] = nil
end

local process_scheduled_buffers = vim.schedule_wrap(function()
  for buf, _ in pairs(bufs_to_update) do
    local diff_state = buffer_diff_state[buf]
    if diff_state then
      M.update_diff(buf)
      if not diff_state.reference_hunks then
        cleanup_diff_state(buf)
      end
    end
  end
  bufs_to_update = {}
end)

local function schedule_diff_update(buf, delay)
  bufs_to_update[buf] = true
  update_timer:stop()
  update_timer:start(delay or 0, 0, process_scheduled_buffers)
end

--- Set up automatic diff updates for a buffer with diff state
--- @param buf integer Buffer handle
local function setup_auto_diff_updates(buf)
  if vim.api.nvim_buf_is_loaded(buf) then
    vim.api.nvim_buf_attach(buf, false, {
      on_lines = function(_, _, _, _, _, _, _, _, _)
        local diff_state = buffer_diff_state[buf]
        if diff_state == nil then
          return true
        end
        schedule_diff_update(buf, 500)
      end,
      on_reload = function()
        schedule_diff_update(buf)
      end,
      on_detach = function()
        cleanup_diff_state(buf)
      end,
    })
    local diff_state = buffer_diff_state[buf]
    local group =
      vim.api.nvim_create_augroup("SiaDiffUpdates_" .. buf, { clear = true })
    diff_state.autocommand_group = group

    vim.api.nvim_create_autocmd("BufWinEnter", {
      buffer = buf,
      group = group,
      callback = function()
        schedule_diff_update(buf)
      end,
    })

    vim.api.nvim_create_autocmd("BufDelete", {
      buffer = buf,
      group = group,
      once = true,
      callback = function()
        cleanup_diff_state(buf)
      end,
    })
    schedule_diff_update(buf, 500)
  end
end

--- @param content string[]
local function has_trailing_newline(content)
  return #content > 0 and content[#content]:sub(-1) == ""
end

--- Expand the last hunk to include newline differences
--- @generic T : sia.diff.Hunk
--- @param hunk T
--- @param baseline string[]
--- @param current string[]
--- @return T new_hunk
local function expand_hunk(hunk, baseline, current)
  local baseline_has_nl = has_trailing_newline(baseline)
  local current_has_nl = has_trailing_newline(current)
  if baseline_has_nl == current_has_nl then
    return hunk
  end
  local baseline_end = hunk.old_start + hunk.old_count - 1
  local current_end = hunk.new_start + hunk.new_count - 1

  local new_count = hunk.new_count
  local old_count = hunk.old_count
  if current_has_nl and not baseline_has_nl and current_end == #current - 1 then
    new_count = new_count + 1
  end

  if baseline_has_nl and not current_has_nl and baseline_end == #baseline - 1 then
    old_count = old_count + 1
  end
  return {
    new_start = hunk.new_start,
    new_count = new_count,
    old_start = hunk.old_start,
    old_count = old_count,
    type = hunk.type,
    char_hunks = hunk.char_hunks,
  }
end

--- Apply a set of hunks to the baseline using current buffer content (modifies in place)
--- @param baseline_lines string[] The baseline to modify in place
--- @param hunks sia.diff.Hunk[] List of hunks to apply
--- @param current_content string[] Current buffer content to get new lines from
local function apply_hunks_to_baseline(baseline_lines, hunks, current_content)
  local sorted_hunks = {}
  for _, hunk in ipairs(hunks) do
    table.insert(sorted_hunks, hunk)
  end
  table.sort(sorted_hunks, function(a, b)
    return a.old_start > b.old_start
  end)

  for _, hunk in ipairs(sorted_hunks) do
    if hunk.type == "add" then
      local lines_to_insert = {}
      for i = 0, hunk.new_count - 1 do
        local line_idx = hunk.new_start + i
        if line_idx <= #current_content then
          table.insert(lines_to_insert, current_content[line_idx])
        end
      end

      local insert_pos = hunk.old_start + 1
      for i = #lines_to_insert, 1, -1 do
        table.insert(baseline_lines, insert_pos, lines_to_insert[i])
      end
    elseif hunk.type == "delete" then
      for i = hunk.old_count, 1, -1 do
        local line_idx = hunk.old_start + i - 1
        if baseline_lines[line_idx] ~= nil then
          table.remove(baseline_lines, line_idx)
        end
      end
    else -- "change"
      local replacement_lines = {}
      for i = 0, hunk.new_count - 1 do
        local line_idx = hunk.new_start + i
        if line_idx <= #current_content then
          table.insert(replacement_lines, current_content[line_idx])
        end
      end

      for i = hunk.old_count, 1, -1 do
        local line_idx = hunk.old_start + i - 1
        if baseline_lines[line_idx] ~= nil then
          table.remove(baseline_lines, line_idx)
        end
      end

      for i = #replacement_lines, 1, -1 do
        table.insert(baseline_lines, hunk.old_start, replacement_lines[i])
      end
    end
  end
end

--- @param char_changes sia.diff.Hunk[]
--- @return sia.diff.Hunk[]
local function merge_nearby_char_hunks(char_changes)
  if #char_changes == 0 then
    return char_changes
  end

  --- @type sia.diff.Hunk[]
  local ret = { char_changes[1] }

  for j = 2, #char_changes do
    local h, n = ret[#ret], char_changes[j]
    if not h or not n then
      break
    end

    if n.new_start - h.new_start - h.new_count < REGION_GAP then
      h.new_count = n.new_start + n.new_count - h.new_start
      h.old_count = n.old_start + n.old_count - h.old_start
      h.type = h.old_count > 0 and h.new_count > 0 and "change"
        or (h.new_count > 0 and "add" or "delete")
    else
      ret[#ret + 1] = n
    end
  end

  return ret
end

--- Compute character-level diffs for a pair of lines
--- @param old_line string
--- @param new_line string
--- @return sia.diff.Hunk[]? char_changes
local function get_intraline_char_hunks(old_line, new_line)
  if #old_line < MIN_LINE_LENGTH or #new_line < MIN_LINE_LENGTH then
    return nil
  end

  if #old_line > MAX_LINE_LENGTH or #new_line > MAX_LINE_LENGTH then
    return nil
  end

  local old_chars = table.concat(vim.split(old_line, ""), "\n")
  local new_chars = table.concat(vim.split(new_line, ""), "\n")

  local char_indices = vim.diff(old_chars, new_chars, DIFF_OPTS) or {} --[[@as integer[][]]

  if #char_indices == 0 then
    return nil
  end

  --- @type sia.diff.Hunk[]
  local char_hunks = {}

  for _, char_hunk in ipairs(char_indices) do
    local old_start, old_count, new_start, new_count =
      char_hunk[1], char_hunk[2], char_hunk[3], char_hunk[4]
    local hunk = {
      old_start = old_start,
      old_count = old_count,
      new_start = new_start,
      new_count = new_count,
      type = old_count > 0 and new_count > 0 and "change"
        or (new_count > 0 and "add" or "delete"),
    }
    table.insert(char_hunks, hunk)
  end

  return merge_nearby_char_hunks(char_hunks)
end

---@param hunk sia.diff.Hunk
---@param reference_range sia.diff.Reference
---@param current_lines string[] Current buffer content
---@param baseline_lines string[] Baseline content
---@return boolean is_reference_change True if this hunk matches the reference change
local function hunk_content_match(hunk, reference_range, current_lines, baseline_lines)
  if hunk.old_count ~= #reference_range.old_lines then
    return false
  end
  if hunk.new_count ~= #reference_range.new_lines then
    return false
  end

  for i = 0, hunk.old_count - 1 do
    local baseline_line = baseline_lines[hunk.old_start + i] or ""
    local ref_line = reference_range.old_lines[i + 1]
    if baseline_line ~= ref_line then
      return false
    end
  end

  for i = 0, hunk.new_count - 1 do
    local current_line = current_lines[hunk.new_start + i] or ""
    local ref_line = reference_range.new_lines[i + 1]
    if current_line ~= ref_line then
      return false
    end
  end

  return true
end

---@param baseline string[]
---@param reference string[]
---@return sia.diff.Reference[]
local function extract_references(baseline, reference)
  local baseline_content = table.concat(baseline, "\n")
  local reference_content = table.concat(reference, "\n")
  local hunk_indices = vim.diff(baseline_content, reference_content, DIFF_OPTS) or {} --[[@as integer[][]]

  --- @type sia.diff.Reference[]
  local reference_ranges = {}
  for _, hunk in ipairs(hunk_indices) do
    local old_start, old_count = hunk[1], hunk[2]
    local new_start, new_count = hunk[3], hunk[4]

    local old_lines = {}
    for i = old_start, old_start + old_count - 1 do
      table.insert(old_lines, baseline[i] or "")
    end

    local new_lines = {}
    for i = new_start, new_start + new_count - 1 do
      table.insert(new_lines, reference[i] or "")
    end

    table.insert(reference_ranges, {
      old_lines = old_lines,
      new_lines = new_lines,
      old_start = old_start,
      new_start = new_start,
    })
  end
  return reference_ranges
end

---@param hunks1 sia.diff.Hunk[]?
---@param hunks2 sia.diff.Hunk[]?
---@return boolean equal True if hunks are equivalent
local function hunks_equal(hunks1, hunks2)
  if not hunks1 or not hunks2 then
    return false
  end

  if #hunks1 ~= #hunks2 then
    return false
  end

  for i, h1 in ipairs(hunks1) do
    local h2 = hunks2[i]
    if
      h1.old_start ~= h2.old_start
      or h1.old_count ~= h2.old_count
      or h1.new_start ~= h2.new_start
      or h1.new_count ~= h2.new_count
    then
      return false
    end
  end

  return true
end

--- @param references sia.diff.Reference[]
--- @param current_lines string[][]
--- @param baseline string[][]
--- @return fun(hunk: sia.diff.Hunk):boolean
local function create_reference_matcher(references, current_lines, baseline)
  local available_indices = {}
  for i = 1, #references do
    available_indices[i] = true
  end

  return function(hunk)
    local matching_indices = {}
    for i, reference in ipairs(references) do
      local content_match = hunk_content_match(hunk, reference, current_lines, baseline)
      if available_indices[i] and content_match then
        table.insert(matching_indices, i)
      end
    end

    if #matching_indices > 0 then
      local best_index = matching_indices[1]

      if #matching_indices > 1 then
        local min_distance = MAX_DISTANCE
        for _, idx in ipairs(matching_indices) do
          local reference = references[idx]
          -- Compare hunk position to original reference position
          -- Use new_start for additions/changes, old_start for deletions
          local ref_pos = reference.new_start > 0 and reference.new_start
            or reference.old_start
          local hunk_pos = hunk.new_start > 0 and hunk.new_start or hunk.old_start
          local distance = math.abs(ref_pos - hunk_pos)
          if distance < min_distance then
            min_distance = distance
            best_index = idx
          end
        end
      end

      available_indices[best_index] = false
      return true
    end
    return false
  end
end

--- Highlight the diff hunks in the buffer
--- @param baseline string[]
--- @param max_lines integer
--- @param hunks sia.diff.Hunk[]?
---@return table<integer, {col: integer?, args:vim.api.keyset.set_extmark}[]?>?
local function get_hunk_highlights(baseline, max_lines, hunks)
  if not hunks or #hunks == 0 then
    return nil
  end

  local show_signs = require("sia.config").options.defaults.ui.show_signs
  ---@type table<integer, {col: integer?, args:vim.api.keyset.set_extmark}[]?>?
  local extmarks = {}

  for _, hunk in ipairs(hunks) do
    if hunk.old_count > 0 then
      local old_text_lines = {}
      for i = 0, hunk.old_count - 1 do
        local old_line_idx = hunk.old_start + i
        if old_line_idx <= #baseline then
          table.insert(old_text_lines, baseline[old_line_idx])
        end
      end

      local line_idx = math.max(1, hunk.new_start)
      if line_idx <= max_lines then
        local virt_lines = {}
        for _, old_line in ipairs(old_text_lines) do
          local pad = string.rep(" ", vim.o.columns - #old_line)
          table.insert(virt_lines, { { old_line .. pad, "SiaDiffDelete" } })
        end

        extmarks[line_idx] = {
          {
            args = {
              virt_lines = virt_lines,
              virt_lines_above = true,
              priority = 300,
              undo_restore = false,
            },
          },
        }
      end
    end

    if hunk.new_count > 0 then
      local start_row = hunk.new_start
      local end_row = start_row + hunk.new_count
      if start_row <= max_lines then
        if end_row > max_lines then
          end_row = max_lines
        end
        local is_change = hunk.old_count > 0
        local hl_group = is_change and "SiaDiffChange" or "SiaDiffAdd"
        local sign_hl = is_change and "SiaDiffChangeSign" or "SiaDiffAddSign"
        --- @type string?
        local sign = is_change and "▎" or "▎"
        if not show_signs then
          sign = nil
        end
        for i = start_row, end_row - 1, 1 do
          local extmark = {
            args = {
              end_line = i,
              sign_text = sign,
              sign_hl_group = sign_hl,
              hl_group = hl_group,
              hl_eol = true,
              priority = 100,
            },
          }
          if extmarks[i] then
            table.insert(extmarks[i], extmark)
          else
            extmarks[i] = { extmark }
          end

          -- Add char-level highlighting if available for this line
          if hunk.char_hunks then
            local line_offset = i - start_row + 1
            local char_changes = hunk.char_hunks[line_offset]
            if char_changes then
              for _, char_hunk in ipairs(char_changes) do
                if char_hunk.new_count > 0 then
                  local inline_hl_group = char_hunk.type == "change"
                      and "SiaDiffInlineChange"
                    or "SiaDiffInlineAdd"
                  local start_col = char_hunk.new_start - 1
                  local end_col = start_col + char_hunk.new_count
                  table.insert(extmarks[i], {
                    col = start_col,
                    args = {
                      end_col = end_col,
                      hl_group = inline_hl_group,
                      priority = 101,
                      hl_eol = false,
                    },
                  })
                end
              end
            end
          end
        end
      end
    end
  end
  return extmarks
end

--- Create diff hunks between baseline and current, categorized by AI vs user changes
---@param buf number Buffer handle
function M.update_diff(buf)
  local diff_state = buffer_diff_state[buf]
  if not diff_state then
    return
  end

  local show_char_diff = require("sia.config").options.defaults.ui.char_diff

  local current_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local current_content = table.concat(current_lines, "\n")

  local baseline_lines = diff_state.baseline
  local baseline_content = table.concat(diff_state.baseline, "\n")

  local hunk_indices = vim.diff(baseline_content, current_content, DIFF_OPTS) or {} --[[@as integer[][]]

  local reference_cache = diff_state.reference_cache or {}

  local is_reference_hunk =
    create_reference_matcher(reference_cache, current_lines, baseline_lines)

  local reference_hunks = {}
  local baseline_hunks = {}
  for _, hunk_idx in ipairs(hunk_indices) do
    local old_start, old_count = hunk_idx[1], hunk_idx[2]
    local new_start, new_count = hunk_idx[3], hunk_idx[4]

    --- @type sia.diff.Hunk
    local hunk = {
      old_start = old_start,
      old_count = old_count,
      new_start = new_start,
      new_count = new_count,
      type = old_count > 0 and new_count > 0 and "change"
        or (new_count > 0 and "add" or "delete"),
    }

    if is_reference_hunk(hunk) then
      if show_char_diff and hunk.old_count == hunk.new_count and hunk.old_count > 0 then
        local char_diffs = {}
        local has_char_diffs = false

        for i = 1, hunk.old_count do
          local old_line_idx = hunk.old_start + i - 1
          local new_line_idx = hunk.new_start + i - 1

          if old_line_idx <= #baseline_lines and new_line_idx <= #current_lines then
            local old_line = baseline_lines[old_line_idx]
            local new_line = current_lines[new_line_idx]

            local char_hunks = get_intraline_char_hunks(old_line, new_line)
            if char_hunks then
              char_diffs[i] = char_hunks
              has_char_diffs = true
            end
          end
        end

        if has_char_diffs then
          hunk.char_hunks = char_diffs
        end
      end

      table.insert(reference_hunks, hunk)
    else
      table.insert(baseline_hunks, hunk)
    end
  end

  local prev_reference_hunks = diff_state.reference_hunks
  diff_state.reference_hunks = #reference_hunks > 0 and reference_hunks or nil
  diff_state.baseline_hunks = #baseline_hunks > 0 and baseline_hunks or nil
  diff_state.markers = get_hunk_highlights(
    diff_state.baseline,
    vim.api.nvim_buf_line_count(buf),
    diff_state.reference_hunks
  )

  if not hunks_equal(prev_reference_hunks, diff_state.reference_hunks) then
    diff_state.needs_clear = true
    redraw_buffer(buf)
  end
end

---@param buf integer
function M.show_diff_preview(buf)
  local diff_state = buffer_diff_state[buf]
  if not diff_state then
    return
  end
  local timestamp = os.date("%H:%M:%S")
  vim.cmd("tabnew")
  local left_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, diff_state.baseline)
  vim.api.nvim_buf_set_name(
    left_buf,
    string.format("%s [ORIGINAL @ %s]", vim.api.nvim_buf_get_name(buf), timestamp)
  )
  vim.bo[left_buf].buftype = "nofile"
  vim.bo[left_buf].buflisted = false
  vim.bo[left_buf].swapfile = false
  vim.bo[left_buf].ft = vim.bo[buf].ft

  vim.cmd("vsplit")
  local right_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(right_win, buf)
  vim.api.nvim_set_current_win(right_win)
  vim.cmd("diffthis")
  vim.api.nvim_set_current_win(vim.fn.win_getid(vim.fn.winnr("#")))
  vim.cmd("diffthis")
  vim.bo[left_buf].modifiable = false
  vim.api.nvim_set_current_win(right_win)
end

function M.update_baseline(buf)
  local diff_state = buffer_diff_state[buf]
  if not diff_state then
    local current_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    buffer_diff_state[buf] = {
      baseline = vim.deepcopy(current_lines),
      reference = current_lines,
      reference_hunks = {},
      autocommand_group = nil,
      reference_cache = {},
    }
    setup_auto_diff_updates(buf)
  else
    M.update_diff(buf)
    local baseline_hunks = diff_state.baseline_hunks
    if not baseline_hunks then
      return
    end

    local current_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    apply_hunks_to_baseline(diff_state.baseline, baseline_hunks, current_content)
    diff_state.baseline_hunks = nil
    diff_state.reference_cache =
      extract_references(diff_state.baseline, diff_state.reference)
    schedule_diff_update(buf, 500)
  end
end

--- Get the diff state for a buffer
---@param buf number Buffer handle
---@return sia.diff.DiffState?
function M.get_diff_state(buf)
  return buffer_diff_state[buf]
end

---@param buf number Buffer handle
function M.update_reference(buf)
  local diff_state = buffer_diff_state[buf]
  if not diff_state then
    return
  end
  diff_state.reference = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  diff_state.reference_cache =
    extract_references(diff_state.baseline, diff_state.reference)
  schedule_diff_update(buf, 500)
end

--- @return sia.diff.Hunk[]?
function M.get_hunks(buf)
  local diff_state = buffer_diff_state[buf]
  if not diff_state then
    return nil
  end
  return diff_state.reference_hunks
end

--- @return string[]?
function M.get_baseline(buf)
  local diff_state = buffer_diff_state[buf]
  if not diff_state then
    return nil
  end
  return diff_state.baseline
end

function M.accept_diff(buf)
  if buffer_diff_state[buf] then
    cleanup_diff_state(buf)
    return true
  else
    return false
  end
end

function M.reject_diff(buf)
  local diff_state = buffer_diff_state[buf]
  if not diff_state then
    return false
  end

  if not diff_state.reference_hunks then
    return true
  end

  while diff_state.reference_hunks and #diff_state.reference_hunks > 0 do
    M.reject_single_hunk(buf, 1)
  end

  cleanup_diff_state(buf)
  return true
end

function M.show_diff_for_buffer(buf)
  if buffer_diff_state[buf] then
    M.show_diff_preview(buf)
    -- cleanup_diff_state(buf)
    return true
  else
    return false
  end
end

--- Get the next diff hunk position relative to current line
--- @param buf number Buffer handle
--- @param current_line number Current cursor line (1-based)
--- @return { line: number, index: number }? hunk_info Position and index of next hunk, or nil if none
function M.get_next_hunk(buf, current_line)
  local diff_state = buffer_diff_state[buf]
  if not diff_state then
    return nil
  end

  local hunks = diff_state.reference_hunks
  if not hunks then
    return nil
  end

  for i, hunk in ipairs(hunks) do
    local hunk_line = hunk.new_start
    if hunk_line > current_line then
      return { line = hunk_line, index = i }
    end
  end

  if #hunks > 0 then
    local first_hunk = hunks[1]
    return { line = first_hunk.new_start, index = 1 }
  end

  return nil
end

--- Get the previous diff hunk position relative to current line
--- @param buf number Buffer handle
--- @param current_line number Current cursor line (1-based)
--- @return { line: number, index: number }? hunk_info
function M.get_prev_hunk(buf, current_line)
  local diff_state = buffer_diff_state[buf]
  if not diff_state then
    return nil
  end

  local hunks = diff_state.reference_hunks
  if not hunks then
    return nil
  end

  for i = #hunks, 1, -1 do
    local hunk = hunks[i]
    local hunk_line = hunk.new_start
    if hunk_line < current_line then
      return { line = hunk_line, index = i }
    end
  end

  if #hunks > 0 then
    local last_hunk = hunks[#hunks]
    return { line = last_hunk.new_start, index = #hunks }
  end

  return nil
end

--- Get the total number of hunks for a buffer
--- @param buf number Buffer handle
--- @return number count Number of hunks (0 if no diff state)
function M.get_hunk_count(buf)
  local diff_state = buffer_diff_state[buf]
  if not diff_state then
    return 0
  end
  return diff_state.reference_hunks and #diff_state.reference_hunks or 0
end

--- Get all diff hunks for quickfix list
--- @param buf number? Buffer handle (if nil, gets hunks from all buffers)
--- @return table[] quickfix_items List of quickfix items for all hunks
function M.get_all_hunks_for_quickfix(buf)
  local quickfix_items = {}

  if buf then
    local diff_state = buffer_diff_state[buf]
    if diff_state and diff_state.reference_hunks then
      local bufname = vim.api.nvim_buf_get_name(buf)
      local line_count = vim.api.nvim_buf_line_count(buf)

      for i, hunk in ipairs(diff_state.reference_hunks) do
        if hunk.new_start > 0 and hunk.new_start <= line_count then
          local hunk_type = hunk.type == "add" and "Added"
            or (hunk.type == "delete" and "Deleted" or "Changed")
          local text = string.format(
            "Edit %d/%d: %s lines %d-%d",
            i,
            #diff_state.reference_hunks,
            hunk_type,
            hunk.new_start,
            hunk.new_start + hunk.new_count - 1
          )

          table.insert(quickfix_items, {
            filename = bufname,
            lnum = hunk.new_start,
            col = 1,
            text = text,
            type = "I",
          })
        end
      end
    end
  else
    for buffer_id, diff_state in pairs(buffer_diff_state) do
      if diff_state.reference_hunks and vim.api.nvim_buf_is_valid(buffer_id) then
        local bufname = vim.api.nvim_buf_get_name(buffer_id)
        local line_count = vim.api.nvim_buf_line_count(buffer_id)

        for i, hunk in ipairs(diff_state.reference_hunks) do
          if hunk.new_start > 0 and hunk.new_start <= line_count then
            local hunk_type = hunk.type == "add" and "Added"
              or (hunk.type == "delete" and "Deleted" or "Changed")
            local text = string.format(
              "Edit %d/%d: %s lines %d-%d",
              i,
              #diff_state.reference_hunks,
              hunk_type,
              hunk.new_start,
              hunk.new_start + hunk.new_count - 1
            )

            table.insert(quickfix_items, {
              filename = bufname,
              lnum = hunk.new_start,
              col = 1,
              text = text,
              type = "I",
            })
          end
        end
      end
    end
  end

  return quickfix_items
end

--- Accept a single hunk by applying it to the baseline and removing it from hunks
--- @param buf number Buffer handle
--- @param hunk_index number 1-based index of the hunk to accept
--- @return boolean success True if hunk was successfully accepted
function M.accept_single_hunk(buf, hunk_index)
  local diff_state = buffer_diff_state[buf]
  if
    not diff_state
    or not diff_state.reference_hunks
    or hunk_index < 1
    or hunk_index > #diff_state.reference_hunks
  then
    return false
  end

  local hunk = diff_state.reference_hunks[hunk_index]
  local current_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if hunk_index == #diff_state.reference_hunks then
    hunk = expand_hunk(hunk, diff_state.baseline, current_content)
  end
  apply_hunks_to_baseline(diff_state.baseline, { hunk }, current_content)
  diff_state.reference_cache =
    extract_references(diff_state.baseline, diff_state.reference)

  M.update_diff(buf)
  if not diff_state.reference_hunks then
    cleanup_diff_state(buf)
  end
  return true
end

--- Reject a single hunk by reverting it to the original content
--- @param buf number Buffer handle
--- @param hunk_index number 1-based index of the hunk to reject
--- @return boolean success True if hunk was successfully rejected
function M.reject_single_hunk(buf, hunk_index)
  local diff_state = buffer_diff_state[buf]
  if
    not diff_state
    or not diff_state.reference_hunks
    or hunk_index < 1
    or hunk_index > #diff_state.reference_hunks
  then
    return false
  end

  local hunk = diff_state.reference_hunks[hunk_index]
  if hunk_index == #diff_state.reference_hunks then
    hunk = expand_hunk(
      hunk,
      diff_state.baseline,
      vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    )
  end
  local baseline = diff_state.baseline

  local replacement_lines = {}
  if hunk.old_count > 0 then
    for i = 0, hunk.old_count - 1 do
      local line_idx = hunk.old_start + i
      if line_idx <= #baseline then
        table.insert(replacement_lines, baseline[line_idx])
      end
    end
  end

  local start_line, end_line

  if hunk.type == "delete" then
    -- Find the position where the deleted lines should be inserted
    -- by looking at the line that should come after the deleted content
    local insert_pos = 0

    -- If there are lines after the deleted section in original
    if hunk.old_start + hunk.old_count <= #baseline then
      local next_original_line = baseline[hunk.old_start + hunk.old_count]
      local current_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

      for i, line in ipairs(current_content) do
        if line == next_original_line then
          insert_pos = i - 1
          break
        end
      end
    else
      insert_pos = vim.api.nvim_buf_line_count(buf)
    end

    start_line = insert_pos
    end_line = start_line
  elseif hunk.type == "add" then
    start_line = hunk.new_start - 1
    end_line = start_line + hunk.new_count
    replacement_lines = {}
  else -- "change"
    start_line = hunk.new_start - 1
    end_line = start_line + hunk.new_count
  end

  vim.api.nvim_buf_set_lines(buf, start_line, end_line, false, replacement_lines)

  M.update_diff(buf)
  if not diff_state.reference_hunks then
    cleanup_diff_state(buf)
  end
  return true
end

--- Get the hunk at a specific line position
--- @param buf number Buffer handle
--- @param line number 1-based line number
--- @return number? hunk_index 1-based index of the hunk at this line, or nil if no hunk found
function M.get_hunk_at_line(buf, line)
  local diff_state = buffer_diff_state[buf]
  if not diff_state or not diff_state.reference_hunks then
    return nil
  end

  for i, hunk in ipairs(diff_state.reference_hunks) do
    local is_end_line = hunk.new_count == 0 and line == hunk.new_start
      or line < (hunk.new_start + hunk.new_count)
    if is_end_line and line >= hunk.new_start then
      return i
    end
  end

  return nil
end

return M
