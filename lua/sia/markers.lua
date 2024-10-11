local M = {}
local utils = require("sia.utils")

local OURS_PATTERN = "<<<<<<< User"
local THEIRS_PATTERN = ">>>>>>> Sia"
local DELIMITER_PATTERN = "======="

local NONE = 0
local OURS = 1
local THEIRS = 2

--- Detect if the buffer contains conflict markers
--- @param buf integer
--- @return boolean
local function detect_conflict_markers(buf)
  local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local before, after = utils.partition_marker(content, {
    before = OURS_PATTERN,
    delimiter = DELIMITER_PATTERN,
    after = THEIRS_PATTERN,
  })
  return #before > 0 or #after > 0
end

--- @return integer? pos
local function current_conflict_begin()
  local begin = vim.fn.searchpos(OURS_PATTERN, "bcnW")[1]
  local before_end = vim.fn.searchpos(THEIRS_PATTERN, "bnW")[1]

  if begin == 0 or (before_end ~= 0 and before_end > begin) then
    return nil
  end

  return begin
end

--- @return integer? pos
local function current_conflict_end()
  local after_begin = vim.fn.searchpos(OURS_PATTERN, "nW")[1]
  local end_pos = vim.fn.searchpos(THEIRS_PATTERN, "cnW")[1]

  if end_pos == 0 or (after_begin ~= 0 and end_pos > after_begin) then
    return nil
  end

  return end_pos
end

--- @return integer? pos
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

--- @return [integer, integer, integer]? pos start, middle and end position
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

--- @param buf integer
local function on_detect_conflict_markers(buf)
  conflicts[buf] = detect_conflict_markers(buf)
  local spell = vim.o.spell
  if not spell then
    local win = vim.fn.bufwinid(buf)
    if win ~= -1 then
      spell = vim.wo[win].spell
    end
  end
  if conflicts[buf] then
    vim.api.nvim_buf_call(buf, function()
      vim.cmd([[
    syntax match ConflictMarkerBegin containedin=ALL /^<<<<<<<\+/
    syntax match ConflictMarkerEnd containedin=ALL /^>>>>>>>\+/
    syntax match ConflictMarkerSeparator containedin=ALL /^=======\+$/
    syntax region ConflictMarkerOurs contained containedin=ALL start=/^<<<<<<<\+/hs=e+1 end=/^=======\+$\&/
    syntax region ConflictMarkerTheirs contained containedin=ALL start=/^=======\+/hs=e+1 end=/^>>>>>>>\+\&/
    highlight default link ConflictMarkerBegin DiffDelete
    highlight default link ConflictMarkerOurs DiffDelete
    highlight default link ConflictMarkerSeparator NoneText
    highlight default link ConflictMarkerEnd DiffAdd
    highlight default link ConflictMarkerTheirs DiffAdd
]])
    end)
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
      on_detect_conflict_markers(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "SiaEditPost",
    callback = function(args)
      on_detect_conflict_markers(args.data.buf)
    end,
  })
  vim.api.nvim_create_autocmd("OptionSet", {
    group = augroup,
    pattern = "spell",
    callback = function()
      for buf, _ in pairs(conflicts) do
        on_detect_conflict_markers(buf)
      end
    end,
  })
end

return M
