local M = {}

local OURS_PATTERN = "<<<<<<< User"
local THEIRS_PATTERN = ">>>>>>> Sia"
local DELIMITER_PATTERN = "======="

local NONE = 0
local OURS = 1
local THEIRS = 2

--- @param buf integer
--- @return boolean
local function detect_conflict_markers(buf)
  local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local state = NONE
  for _, line in ipairs(content) do
    if state == NONE then
      if string.match(line, OURS_PATTERN) then
        state = OURS
      else
        goto continue
      end
    else
      if state == OURS then
        if string.match(line, DELIMITER_PATTERN) then
          state = THEIRS
        end
      elseif state == THEIRS then
        if string.match(line, THEIRS_PATTERN) then
          return true
        else
        end
      end
    end
    ::continue::
  end
  return false
end

local function current_conflict_begin()
  local begin = vim.fn.searchpos(OURS_PATTERN, "bcnW")[1]
  local before_end = vim.fn.searchpos(THEIRS_PATTERN, "bnW")[1]

  if begin == 0 or (before_end ~= 0 and before_end > begin) then
    return nil
  end

  return begin
end

local function current_conflict_end()
  local after_begin = vim.fn.searchpos(OURS_PATTERN, "nW")[1]
  local end_pos = vim.fn.searchpos(THEIRS_PATTERN, "cnW")[1]

  if end_pos == 0 or (after_begin ~= 0 and end_pos > after_begin) then
    return nil
  end

  return end_pos
end

local function current_conflict_separator(before_begin, after_end)
  -- when separator is before cursor
  local before_sep = vim.fn.searchpos(DELIMITER_PATTERN, "bcnW")[1]
  if before_sep and before_begin and before_begin < before_sep then
    return before_sep
  end

  -- when separator is after cursor
  local after_sep = vim.fn.searchpos(DELIMITER_PATTERN, "cnW")[1]
  if after_sep and after_end and after_sep < after_end then
    return after_sep
  end

  return nil
end

--- @return [integer, integer, integer]?
local function markers()
  local begin = current_conflict_begin()
  local ending = current_conflict_end()
  local middle = current_conflict_separator(begin, ending)

  if begin and ending and middle then
    return { begin, middle, ending }
  else
    return nil
  end
end

local conflicts = {}

--- @param buf integer
function M.reject(buf)
  if conflicts[buf] then
    local pos = markers()
    if pos then
      vim.api.nvim_buf_set_lines(
        buf,
        pos[1] - 1,
        pos[3],
        false,
        vim.api.nvim_buf_get_lines(buf, pos[1], pos[2] - 1, false)
      )
    end
  end
end

--- @param buf integer
function M.accept(buf)
  if conflicts[buf] then
    local pos = markers()
    if pos then
      vim.api.nvim_buf_set_lines(
        buf,
        pos[1] - 1,
        pos[3],
        false,
        vim.api.nvim_buf_get_lines(buf, pos[2], pos[3] - 1, false)
      )
    end
  end
end

function M.setup()
  local augroup = vim.api.nvim_create_augroup("SiaMarkers", { clear = true })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = augroup,
    pattern = "*",
    callback = function(args)
      conflicts[args.buf] = nil
    end,
  })
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = augroup,
    pattern = "*",
    callback = function(args)
      conflicts[args.buf] = detect_conflict_markers(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "SiaEditPost",
    callback = function(data)
      conflicts[data.data.buf] = detect_conflict_markers(data.data.buf)
    end,
  })
end

M.conflicts = conflicts
return M
