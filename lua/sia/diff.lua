local M = {}

--- @type table<integer, {original_content: string[], hunks: table}>
local buffer_diff_state = {}
local diff_ns = vim.api.nvim_create_namespace("sia_diff_highlights")

---@param buf integer
---@param original_content string[]
function M.show_diff_preview(buf, original_content)
  local timestamp = os.date("%H:%M:%S")
  vim.cmd("tabnew")
  local left_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, original_content)
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

---@param buf number Buffer handle
---@param original_content string[] Original content
function M.highlight_diff_changes(buf, original_content)
  local new_content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")

  if not buffer_diff_state[buf] then
    buffer_diff_state[buf] = {
      original_content = original_content,
      hunks = {},
    }
  end

  local baseline = table.concat(buffer_diff_state[buf].original_content, "\n")
  vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)

  local diff_result = vim.diff(baseline, new_content, {
    result_type = "indices",
    algorithm = "histogram",
  })

  --- @cast diff_result integer[]

  if not diff_result then
    buffer_diff_state[buf].hunks = {}
    return
  end

  local old_lines = buffer_diff_state[buf].original_content
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
          virt_lines_above = true,
          priority = 100,
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
          })
        end
      end
    end
  end

  buffer_diff_state[buf].hunks = hunks

  vim.api.nvim_create_autocmd("BufWritePost", {
    buffer = buf,
    once = true,
    callback = function()
      vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)
      buffer_diff_state[buf] = nil
    end,
  })
end

function M.accept_diff(buf)
  if buffer_diff_state[buf] then
    vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)
    buffer_diff_state[buf] = nil
    return true
  else
    return false
  end
end

function M.reject_diff(buf)
  if buffer_diff_state[buf] then
    vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, buffer_diff_state[buf].original_content)
    buffer_diff_state[buf] = nil
    return true
  else
    return false
  end
end

function M.show_diff_for_buffer(buf)
  if buffer_diff_state[buf] then
    local original_lines = buffer_diff_state[buf].original_content
    M.show_diff_preview(buf, original_lines)
    vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)
    buffer_diff_state[buf] = nil
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

  if not diff_state or #diff_state.hunks == 0 then
    return nil
  end

  local hunks = diff_state.hunks

  -- Find the first hunk after current line
  for i, hunk in ipairs(hunks) do
    local hunk_line = hunk.new_start
    if hunk_line > current_line then
      return { line = hunk_line, index = i }
    end
  end

  -- If no hunk found after current line, wrap to first hunk
  if #hunks > 0 then
    local first_hunk = hunks[1]
    return { line = first_hunk.new_start, index = 1 }
  end

  return nil
end

--- Get the previous diff hunk position relative to current line
--- @param buf number Buffer handle
--- @param current_line number Current cursor line (1-based)
--- @return { line: number, index: number }? hunk_info Position and index of previous hunk, or nil if none
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

return M
