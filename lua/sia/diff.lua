local M = {}

--- @type vim.diff.Opts
local DIFF_OPTS = {
  result_type = "indices",
}

local MIN_LINE_LENGTH = 3
local MAX_LINE_LENGTH = 200
local REGION_GAP = 5

--- @class sia.diff.RefRange
--- @field old_lines string[] Lines removed from baseline (empty table for pure additions)
--- @field new_lines string[] Lines added in reference (empty table for pure deletions)

--- @class sia.diff.Hunk
--- @field old_start integer
--- @field old_count integer
--- @field new_start integer
--- @field new_count integer
--- @field type "change"|"add"|"delete"

--- @class sia.diff.ReferenceHunk : sia.diff.Hunk
--- @field char_diffs table<integer, sia.diff.Hunk[]>? Map from line offset (1-based) to character-level changes for that line pair

--- @class sia.diff.DiffState
--- @field baseline string[]
--- @field reference string[]
--- @field reference_hunks sia.diff.ReferenceHunk[]?
--- @field baseline_hunks sia.diff.Hunk[]?
--- @field autocommand_group integer?
--- @field reference_ranges sia.diff.RefRange[]? Cached ranges from baseline to reference

--- @type table<integer, sia.diff.DiffState>
local buffer_diff_state = {}
local diff_ns = vim.api.nvim_create_namespace("sia_diff")

-- Debounce timer for auto-updates
--- @type table<number, uv_timer_t>
local update_timers = {}

--- Clean up automatic diff updates for a buffer
--- @param buf integer Buffer handle
local function cleanup_auto_diff_updates(buf)
  local diff_state = buffer_diff_state[buf]
  if diff_state and diff_state.autocommand_group then
    vim.api.nvim_del_augroup_by_id(diff_state.autocommand_group)
    diff_state.autocommand_group = nil
  end

  if update_timers[buf] then
    update_timers[buf]:stop()
    update_timers[buf] = nil
  end
end

local function cleanup(buf)
  if not buffer_diff_state[buf] then
    return
  end
  cleanup_auto_diff_updates(buf)
  vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)
  buffer_diff_state[buf] = nil
end

--- Set up automatic diff updates for a buffer with diff state
--- @param buf integer Buffer handle
local function setup_auto_diff_updates(buf)
  local diff_state = buffer_diff_state[buf]
  if not diff_state or diff_state.autocommand_group then
    return
  end

  local group = vim.api.nvim_create_augroup("SiaDiffUpdates_" .. buf, { clear = true })
  diff_state.autocommand_group = group

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    group = group,
    callback = function()
      if not buffer_diff_state[buf] then
        return
      end

      if update_timers[buf] then
        update_timers[buf]:stop()
        update_timers[buf] = nil
      end

      update_timers[buf] = vim.defer_fn(function()
        update_timers[buf] = nil
        if buffer_diff_state[buf] then
          local hunks_changed = M.update_diff(buf)
          if hunks_changed then
            M.highlight_hunks(buf)
          end
          if not buffer_diff_state[buf].reference_hunks then
            cleanup(buf)
          end
        end
      end, 500)
    end,
  })

  vim.api.nvim_create_autocmd("BufDelete", {
    buffer = buf,
    group = group,
    once = true,
    callback = function()
      if update_timers[buf] then
        update_timers[buf]:stop()
        update_timers[buf] = nil
      end
    end,
  })
end

--- @param content string[]
local function has_trailing_nl(content)
  return #content > 0 and content[#content]:sub(-1) == ""
end

--- Expand the last hunk to include newline differences
--- @generic T : sia.diff.Hunk
--- @param hunk T
--- @param baseline string[]
--- @param current string[]
--- @return T new_hunk
local function expand_hunk(hunk, baseline, current)
  local baseline_has_nl = has_trailing_nl(baseline)
  local current_has_nl = has_trailing_nl(current)
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
    char_diffs = hunk.char_diffs,
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

--- Denoise  diffs by merging close hunks
--- @param char_changes sia.diff.Hunk[]
--- @return sia.diff.Hunk[]
local function denoise_char_diffs(char_changes)
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
local function compute_char_diff(old_line, new_line)
  if #old_line < MIN_LINE_LENGTH or #new_line < MIN_LINE_LENGTH then
    return nil
  end

  if #old_line > MAX_LINE_LENGTH or #new_line > MAX_LINE_LENGTH then
    return nil
  end

  local old_chars = table.concat(vim.split(old_line, ""), "\n")
  local new_chars = table.concat(vim.split(new_line, ""), "\n")

  local char_indices = vim.diff(old_chars, new_chars, DIFF_OPTS) or {}
  --- @cast char_indices integer[][]

  if #char_indices == 0 then
    return nil
  end

  --- @type sia.diff.Hunk[]
  local char_changes = {}

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
    table.insert(char_changes, hunk)
  end

  return denoise_char_diffs(char_changes)
end

--- Check if a hunk matches a reference range by comparing content line-by-line
--- Returns false immediately if any line doesn't match (early abort)
---@param hunk sia.diff.Hunk
---@param reference_range sia.diff.RefRange
---@param current_lines string[] Current buffer content
---@param baseline_lines string[] Baseline content
---@return boolean is_reference_change True if this hunk matches the reference change
local function is_reference_hunk(hunk, reference_range, current_lines, baseline_lines)
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

--- Compute reference ranges from baseline to reference
--- This is cached to avoid recomputing on every text change
---@param baseline string[]
---@param reference string[]
---@return sia.diff.RefRange[]
local function compute_reference_ranges(baseline, reference)
  local baseline_content = table.concat(baseline, "\n")
  local reference_content = table.concat(reference, "\n")
  local reference_hunk_indices = vim.diff(
    baseline_content,
    reference_content,
    DIFF_OPTS
  ) or {}
  --- @cast reference_hunk_indices integer[][]

  --- @type sia.diff.RefRange[]
  local reference_ranges = {}
  for _, hunk in ipairs(reference_hunk_indices) do
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
    })
  end
  return reference_ranges
end

--- Compare two hunk arrays for equality (ignoring char_diffs for performance)
--- This is used to detect if hunks changed and highlights need updating
---@param hunks1 sia.diff.ReferenceHunk[]?
---@param hunks2 sia.diff.ReferenceHunk[]?
---@return boolean equal True if hunks are equivalent
local function hunks_equal(hunks1, hunks2)
  if hunks1 == hunks2 then
    return true
  end
  if not hunks1 or not hunks2 then
    return true
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
      or h1.type ~= h2.type
    then
      return false
    end
  end

  return true
end

--- Create diff hunks between baseline and current, categorized by AI vs user changes
---@param buf number Buffer handle
---@return boolean should_update_highlights
function M.update_diff(buf)
  if not buffer_diff_state[buf] then
    return false
  end

  local show_char_diff = require("sia.config").options.defaults.ui.char_diff

  local current_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local current_content = table.concat(current_lines, "\n")
  local diff_state = buffer_diff_state[buf]
  local baseline = table.concat(diff_state.baseline, "\n")

  local total_hunk_indices = vim.diff(baseline, current_content, DIFF_OPTS) or {}

  --- @cast total_hunk_indices integer[][]

  local reference_ranges = diff_state.reference_ranges or {}

  local reference_hunks = {}
  local baseline_hunks = {}
  for _, hunk in ipairs(total_hunk_indices) do
    local old_start, old_count = hunk[1], hunk[2]
    local new_start, new_count = hunk[3], hunk[4]

    --- @type sia.diff.Hunk|sia.diff.ReferenceHunk
    local final_hunk = {
      old_start = old_start,
      old_count = old_count,
      new_start = new_start,
      new_count = new_count,
      type = old_count > 0 and new_count > 0 and "change"
        or (new_count > 0 and "add" or "delete"),
    }
    local reference_change = false
    for _, reference_range in ipairs(reference_ranges) do
      if
        is_reference_hunk(
          final_hunk,
          reference_range,
          current_lines,
          diff_state.baseline
        )
      then
        reference_change = true
        break
      end
    end

    if reference_change and show_char_diff then
      if final_hunk.old_count == final_hunk.new_count and final_hunk.old_count > 0 then
        local char_diffs = {}
        local has_char_diffs = false

        for i = 1, final_hunk.old_count do
          local old_line_idx = final_hunk.old_start + i - 1
          local new_line_idx = final_hunk.new_start + i - 1

          if
            old_line_idx <= #diff_state.baseline and new_line_idx <= #current_lines
          then
            local old_line = diff_state.baseline[old_line_idx]
            local new_line = current_lines[new_line_idx]

            local char_changes = compute_char_diff(old_line, new_line)
            if char_changes then
              char_diffs[i] = char_changes
              has_char_diffs = true
            end
          end
        end

        if has_char_diffs then
          final_hunk.char_diffs = char_diffs
        end
      end

      table.insert(reference_hunks, final_hunk)
    else
      table.insert(baseline_hunks, final_hunk)
    end
  end

  local prev_reference_hunks = diff_state.reference_hunks
  diff_state.reference_hunks = #reference_hunks > 0 and reference_hunks or nil
  diff_state.baseline_hunks = #baseline_hunks > 0 and baseline_hunks or nil
  return not hunks_equal(prev_reference_hunks, diff_state.reference_hunks)
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

function M.init_change_tracking(buf)
  local diff_state = buffer_diff_state[buf]
  if not diff_state then
    local current_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    buffer_diff_state[buf] = {
      baseline = vim.deepcopy(current_lines),
      reference = current_lines,
      reference_hunks = {},
      autocommand_group = nil,
      reference_ranges = {},
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
    diff_state.reference_ranges =
      compute_reference_ranges(diff_state.baseline, diff_state.reference)
  end
end

--- Get the diff state for a buffer
---@param buf number Buffer handle
---@return sia.diff.DiffState?
function M.get_diff_state(buf)
  return buffer_diff_state[buf]
end

--- Update the reference baseline to current buffer state
---@param buf number Buffer handle
function M.update_reference_content(buf)
  local diff_state = buffer_diff_state[buf]
  if not diff_state then
    return
  end
  diff_state.reference = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  diff_state.reference_ranges =
    compute_reference_ranges(diff_state.baseline, diff_state.reference)
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

--- Highlight the diff hunks in the buffer
---@param buf number Buffer handle
function M.highlight_hunks(buf)
  vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)
  if not buffer_diff_state[buf] then
    return
  end

  local diff_state = buffer_diff_state[buf]
  local hunks = diff_state.reference_hunks

  if not hunks or #hunks == 0 then
    return
  end

  local show_signs = require("sia.config").options.defaults.ui.show_signs

  local old_lines = diff_state.baseline
  for _, hunk in ipairs(hunks) do
    local buf_line_count = vim.api.nvim_buf_line_count(buf)
    if hunk.old_count > 0 then
      local old_text_lines = {}
      for i = 0, hunk.old_count - 1 do
        local old_line_idx = hunk.old_start + i
        if old_line_idx <= #old_lines then
          table.insert(old_text_lines, old_lines[old_line_idx])
        end
      end

      local line_idx = math.max(0, hunk.new_start - 1)
      if line_idx <= buf_line_count then
        local virt_lines = {}
        for _, old_line in ipairs(old_text_lines) do
          local pad = string.rep(" ", vim.o.columns - #old_line)
          table.insert(virt_lines, { { old_line .. pad, "SiaDiffDelete" } })
        end

        vim.api.nvim_buf_set_extmark(buf, diff_ns, line_idx, 0, {
          virt_lines = virt_lines,
          virt_lines_above = true,
          priority = 300,
          undo_restore = false,
        })
      end
    end

    if hunk.new_count > 0 then
      local start_row = hunk.new_start - 1
      local end_row = start_row + hunk.new_count
      if start_row < buf_line_count then
        if end_row > buf_line_count then
          end_row = buf_line_count
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
          vim.api.nvim_buf_set_extmark(buf, diff_ns, i, 0, {
            end_line = i + 1,
            sign_text = sign,
            sign_hl_group = sign_hl,
            hl_group = hl_group,
            hl_eol = true,
            priority = 100,
          })
        end

        if hunk.char_diffs then
          for line_offset, char_changes in pairs(hunk.char_diffs) do
            local row = start_row + line_offset - 1
            if row < buf_line_count then
              for _, char_change in ipairs(char_changes) do
                if char_change.new_count > 0 then
                  local inline_hl_group = char_change.type == "change"
                      and "SiaDiffInlineChange"
                    or "SiaDiffInlineAdd"
                  local start_col = char_change.new_start - 1
                  local end_col = start_col + char_change.new_count
                  vim.api.nvim_buf_set_extmark(buf, diff_ns, row, start_col, {
                    end_col = end_col,
                    hl_group = inline_hl_group,
                    hl_mode = "replace",
                    priority = 101,
                    hl_eol = false,
                  })
                end
              end
            end
          end
        end
      end
    end
  end
end

---@param buf number
function M.update_and_highlight_diff(buf)
  local hunks_changed = M.update_diff(buf)
  if hunks_changed then
    M.highlight_hunks(buf)
  end
end

function M.accept_diff(buf)
  if buffer_diff_state[buf] then
    cleanup(buf)
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

  cleanup(buf)
  return true
end

function M.show_diff_for_buffer(buf)
  if buffer_diff_state[buf] then
    M.show_diff_preview(buf)
    cleanup(buf)
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

  local hunks_changed = M.update_diff(buf)
  if hunks_changed then
    M.highlight_hunks(buf)
  end
  if not diff_state.reference_hunks then
    cleanup(buf)
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

  local hunks_changed = M.update_diff(buf)
  if hunks_changed then
    M.highlight_hunks(buf)
  end
  if not diff_state.reference_hunks then
    cleanup(buf)
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
