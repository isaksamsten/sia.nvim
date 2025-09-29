local M = {}

--- @alias sia.diff.Hunk {old_start: integer, old_count: integer, new_start: integer, new_count: integer, type: "change"|"add"|"delete"}
--- @type table<integer, {original_content: string[], hunks: sia.diff.Hunk[], autocommand_group: integer?, user_changes: boolean?}>
local buffer_diff_state = {}
local diff_ns = vim.api.nvim_create_namespace("sia_diff_highlights")

-- Debounce timer for auto-updates
local update_timers = {}

--- Set up automatic diff updates for a buffer with diff state
--- @param buf integer Buffer handle
local function setup_auto_diff_updates(buf)
  local diff_state = buffer_diff_state[buf]
  if not diff_state or diff_state.autocommand_group then
    return -- Already set up or no diff state
  end

  local group = vim.api.nvim_create_augroup("SiaDiffUpdates_" .. buf, { clear = true })
  diff_state.autocommand_group = group

  -- Update diff on text changes with debouncing
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    group = group,
    callback = function()
      if not buffer_diff_state[buf] then
        return
      end
      buffer_diff_state[buf].user_changes = true

      if update_timers[buf] then
        update_timers[buf]:stop()
        update_timers[buf] = nil
      end

      update_timers[buf] = vim.defer_fn(function()
        update_timers[buf] = nil
        if buffer_diff_state[buf] then
          M.update_diff(buf)
          M.highlight_hunks(buf)
        end
      end, 150)
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
  cleanup_auto_diff_updates(buf)
  vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)
  buffer_diff_state[buf] = nil
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
  vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, diff_state.original_content)
  vim.api.nvim_buf_set_name(left_buf, string.format("%s [ORIGINAL @ %s]", vim.api.nvim_buf_get_name(buf), timestamp))
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

function M.init_baseline(buf)
  if not buffer_diff_state[buf] then
    buffer_diff_state[buf] = {
      original_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
      hunks = {},
      autocommand_group = nil,
    }
    -- Set up automatic diff updates for this buffer
    setup_auto_diff_updates(buf)
  end
end

--- Create diff hunks between the original content and current buffer content
---@param buf number Buffer handle
---@return boolean
function M.update_diff(buf)
  if not buffer_diff_state[buf] then
    return false
  end

  local new_content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  local diff_state = buffer_diff_state[buf]
  local baseline = table.concat(diff_state.original_content, "\n")

  local diff_result = vim.diff(baseline, new_content, {
    result_type = "indices",
    algorithm = "patience",
    linematch = true,
  })

  --- @cast diff_result integer[]

  if not diff_result then
    return {}
  end

  local hunks = {}
  for _, hunk in ipairs(diff_result) do
    local old_start, old_count, new_start, new_count = hunk[1], hunk[2], hunk[3], hunk[4]

    local hunk_info = {
      old_start = old_start,
      old_count = old_count,
      new_start = new_start,
      new_count = new_count,
      type = old_count > 0 and new_count > 0 and "change" or (new_count > 0 and "add" or "delete"),
    }
    table.insert(hunks, hunk_info)
  end

  diff_state.hunks = hunks
  if #diff_state.hunks == 0 then
    cleanup(buf)
  end
  return true
end

--- @return sia.diff.Hunk[]?
function M.get_hunks(buf)
  local diff_state = buffer_diff_state[buf]
  if not diff_state then
    return nil
  end
  return diff_state.hunks
end

--- @return string[]?
function M.get_baseline(buf)
  local diff_state = buffer_diff_state[buf]
  if not diff_state then
    return nil
  end
  return diff_state.original_content
end

--- Highlight the diff hunks in the buffer
---@param buf number Buffer handle
---@param hunks sia.diff.Hunk[]? Optional hunks array (if nil, uses stored hunks from diff state)
function M.highlight_hunks(buf)
  vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)
  if not buffer_diff_state[buf] then
    return
  end

  local diff_state = buffer_diff_state[buf]
  local hunks = diff_state.hunks

  if not hunks or #hunks == 0 then
    return
  end

  local old_lines = diff_state.original_content

  for _, hunk in ipairs(hunks) do
    local old_start, old_count, new_start, new_count = hunk.old_start, hunk.old_count, hunk.new_start, hunk.new_count

    if old_count > 0 then
      local old_text_lines = {}
      for i = 0, old_count - 1 do
        local old_line_idx = old_start + i
        if old_line_idx <= #old_lines then
          table.insert(old_text_lines, old_lines[old_line_idx])
        end
      end

      local line_idx = math.max(0, new_start - 1)
      if line_idx <= vim.api.nvim_buf_line_count(buf) then
        local virt_lines = {}
        for _, old_line in ipairs(old_text_lines) do
          table.insert(virt_lines, { { old_line, "DiffDelete" } })
        end

        vim.api.nvim_buf_set_extmark(buf, diff_ns, line_idx, 0, {
          virt_lines = virt_lines,
          virt_lines_above = false,
          priority = 100,
          undo_restore = false,
        })
      end
    end

    if new_count > 0 then
      for i = 0, new_count - 1 do
        local line_idx = new_start - 1 + i
        if line_idx < vim.api.nvim_buf_line_count(buf) then
          local hl_group = (old_count > 0) and "DiffChange" or "DiffAdd"
          vim.api.nvim_buf_set_extmark(buf, diff_ns, line_idx, 0, {
            end_col = 0,
            hl_group = hl_group,
            line_hl_group = hl_group,
            priority = 100,
            undo_restore = false,
          })
        end
      end
    end
  end
end

--- Legacy function that combines diff and highlight for backward compatibility
---@param buf number Buffer handle
function M.highlight_diff_changes(buf)
  M.update_diff(buf)
  M.highlight_hunks(buf)
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
  if buffer_diff_state[buf] then
    -- TODO: We should not drop user changes....
    if not buffer_diff_state[buf].user_changes then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, buffer_diff_state[buf].original_content)
    end
    cleanup(buf)
    return true
  else
    return false
  end
end

function M.show_diff_for_buffer(buf)
  if buffer_diff_state[buf] then
    M.show_diff_preview(buf)
    cleanup_auto_diff_updates(buf)
    vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)
    buffer_diff_state[buf] = nil
    return true
  else
    return false
  end
end

--- Check if a buffer has active diff state with auto-updates
--- @param buf integer Buffer handle
--- @return boolean
function M.has_active_diff(buf)
  return buffer_diff_state[buf] ~= nil
end

--- Get the next diff hunk position relative to current line
--- @param buf number Buffer handle
--- @param current_line number Current cursor line (1-based)
--- @return { line: number, index: number }? hunk_info Position and index of next hunk, or nil if none
function M.get_next_hunk(buf, current_line)
  local diff_state = buffer_diff_state[buf]

  if not diff_state or #diff_state.hunks == 0 then
    return nil
  end

  local hunks = diff_state.hunks

  -- Find the first hunk after current line
  for i, hunk in ipairs(hunks) do
    local hunk_line = hunk.new_start
    if hunk.type == "delete" then
      hunk_line = hunk.old_start
    end
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

  if not diff_state or #diff_state.hunks == 0 then
    return nil
  end

  local hunks = diff_state.hunks

  -- Find the last hunk before current line
  for i = #hunks, 1, -1 do
    local hunk = hunks[i]
    local hunk_line = hunk.new_start
    if hunk_line < current_line then
      return { line = hunk_line, index = i }
    end
  end

  -- If no hunk found before current line, wrap to last hunk
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
  return #diff_state.hunks
end

--- Get all diff hunks for quickfix list
--- @param buf number? Buffer handle (if nil, gets hunks from all buffers)
--- @return table[] quickfix_items List of quickfix items for all hunks
function M.get_all_hunks_for_quickfix(buf)
  local quickfix_items = {}

  if buf then
    local diff_state = buffer_diff_state[buf]
    if diff_state and diff_state.hunks then
      local bufname = vim.api.nvim_buf_get_name(buf)
      local line_count = vim.api.nvim_buf_line_count(buf)

      for i, hunk in ipairs(diff_state.hunks) do
        if hunk.new_start > 0 and hunk.new_start <= line_count then
          local hunk_type = hunk.type == "add" and "Added" or (hunk.type == "delete" and "Deleted" or "Changed")
          local text = string.format(
            "Edit %d/%d: %s lines %d-%d",
            i,
            #diff_state.hunks,
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
      if diff_state.hunks and vim.api.nvim_buf_is_valid(buffer_id) then
        local bufname = vim.api.nvim_buf_get_name(buffer_id)
        local line_count = vim.api.nvim_buf_line_count(buffer_id)

        for i, hunk in ipairs(diff_state.hunks) do
          if hunk.new_start > 0 and hunk.new_start <= line_count then
            local hunk_type = hunk.type == "add" and "Added" or (hunk.type == "delete" and "Deleted" or "Changed")
            local text = string.format(
              "Edit %d/%d: %s lines %d-%d",
              i,
              #diff_state.hunks,
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
  if not diff_state or not diff_state.hunks or hunk_index < 1 or hunk_index > #diff_state.hunks then
    return false
  end

  local hunk = diff_state.hunks[hunk_index]
  local original_content = vim.tbl_deep_extend("force", {}, diff_state.original_content)
  local current_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  if hunk.type == "add" then
    local lines_to_insert = {}
    for i = 0, hunk.new_count - 1 do
      local line_idx = hunk.new_start + i
      if current_content[line_idx] then
        table.insert(lines_to_insert, current_content[line_idx])
      end
    end

    local insert_pos = hunk.old_start + 1
    for i = #lines_to_insert, 1, -1 do
      table.insert(original_content, insert_pos, lines_to_insert[i])
    end
  elseif hunk.type == "delete" then
    for i = hunk.old_count, 1, -1 do
      local line_idx = hunk.old_start + i - 1
      if original_content[line_idx] then
        table.remove(original_content, line_idx)
      end
    end
  else -- "change"
    local replacement_lines = {}
    for i = 0, hunk.new_count - 1 do
      local line_idx = hunk.new_start + i
      if current_content[line_idx] then
        table.insert(replacement_lines, current_content[line_idx])
      end
    end

    for i = hunk.old_count, 1, -1 do
      local line_idx = hunk.old_start + i - 1
      if original_content[line_idx] then
        table.remove(original_content, line_idx)
      end
    end

    for i = #replacement_lines, 1, -1 do
      table.insert(original_content, hunk.old_start, replacement_lines[i])
    end
  end

  diff_state.original_content = original_content

  M.update_diff(buf)
  M.highlight_hunks(buf)

  return true
end

--- Reject a single hunk by reverting it to the original content
--- @param buf number Buffer handle
--- @param hunk_index number 1-based index of the hunk to reject
--- @return boolean success True if hunk was successfully rejected
function M.reject_single_hunk(buf, hunk_index)
  local diff_state = buffer_diff_state[buf]
  if not diff_state or not diff_state.hunks or hunk_index < 1 or hunk_index > #diff_state.hunks then
    return false
  end

  local hunk = diff_state.hunks[hunk_index]
  local original_content = diff_state.original_content

  local replacement_lines = {}
  if hunk.old_count > 0 then
    for i = 0, hunk.old_count - 1 do
      local line_idx = hunk.old_start + i
      if original_content[line_idx] then
        table.insert(replacement_lines, original_content[line_idx])
      end
    end
  end

  -- Handle different hunk types
  local start_line, end_line

  if hunk.type == "delete" then
    -- For deletion hunks, we need to insert the deleted lines back at the correct position
    -- We need to map the original position to current buffer considering previous changes
    -- The safest approach is to find where to insert by looking at surrounding context

    -- Find the position where the deleted lines should be inserted
    -- by looking at the line that should come after the deleted content
    local insert_pos = 0

    -- If there are lines after the deleted section in original
    if hunk.old_start + hunk.old_count <= #original_content then
      local next_original_line = original_content[hunk.old_start + hunk.old_count]
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
  M.highlight_hunks(buf)

  return true
end

--- Get the hunk at a specific line position
--- @param buf number Buffer handle
--- @param line number 1-based line number
--- @return number? hunk_index 1-based index of the hunk at this line, or nil if no hunk found
function M.get_hunk_at_line(buf, line)
  local diff_state = buffer_diff_state[buf]
  if not diff_state or not diff_state.hunks then
    return nil
  end

  for i, hunk in ipairs(diff_state.hunks) do
    if hunk.type == "delete" then
      if line == hunk.old_start then
        return i
      end
    else
      if line >= hunk.new_start and line < (hunk.new_start + hunk.new_count) then
        return i
      end
    end
  end

  return nil
end

return M
