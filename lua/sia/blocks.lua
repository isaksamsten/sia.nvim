--- @class sia.Block
--- @field source {buf: integer, pos: [integer, integer] }
--- @field tag string?
--- @field code string[]

local M = {}

local utils = require("sia.utils")

local ns_flash_id = vim.api.nvim_create_namespace("sia_flash") -- Create a namespace for the highlight

--- @param bufnr integer
--- @param pos [integer, integer]
--- @param timeout integer?
--- @param hl_group string?
local function flash_highlight(bufnr, pos, timeout, hl_group)
  for line = pos[1], pos[2] do
    vim.api.nvim_buf_add_highlight(bufnr, ns_flash_id, hl_group or "DiffAdd", line, 0, -1)
  end

  local timer = vim.loop.new_timer()
  timer:start(
    timeout or 300,
    0,
    vim.schedule_wrap(function()
      vim.api.nvim_buf_clear_namespace(bufnr, ns_flash_id, pos[1], pos[2] + 1)
      timer:stop()
      timer:close()
    end)
  )
end

--- @param blocks sia.Block[]
--- @param callback fun(block: sia.Block, single: boolean?):nil
function M.select_block(blocks, callback)
  if #blocks == 1 then
    callback(blocks[1], true)
  else
    vim.ui.select(blocks, {
      format_item = function(item)
        return table.concat(item.code, " ", 1, 3) .. "..."
      end,
    }, function(block)
      callback(block)
    end)
  end
end

--- @param buf integer
--- @param line integer
--- @param block sia.Block
--- @param replace sia.config.Replace
function M.insert_block_above(buf, line, block, replace)
  vim.api.nvim_buf_set_lines(buf, line - 1, line - 1, false, block.code)
  flash_highlight(buf, { line - 1, line + #block.code - 1 }, replace.timeout, replace.highlight)
end

--- @param buf integer
--- @param line integer
--- @param block sia.Block
--- @param replace sia.config.Replace
function M.insert_block_below(buf, line, block, replace)
  vim.api.nvim_buf_set_lines(buf, line, line, false, block.code)
  flash_highlight(buf, { line, line + #block.code - 1 }, replace.timeout, replace.highlight)
end

--- @param buf integer
--- @param start_line integer
--- @param end_line integer
--- @param block sia.Block
--- @param replace sia.config.Replace
function M.insert_block_at(buf, start_line, end_line, block, replace)
  vim.api.nvim_buf_set_lines(buf, start_line - 1, end_line, false, block.code)
  flash_highlight(buf, { start_line - 1, start_line + #block.code - 2 }, replace.timeout, replace.highlight)
end

--- @param source integer
--- @param response string[]
--- @return sia.Block[]
function M.parse_blocks(source, response)
  --- @type sia.Block?
  local block = nil

  --- @type sia.Block[]
  local blocks = {}

  for i, line in pairs(response) do
    if block == nil then
      local tag = string.match(line, "^%s*```.+%s+(.*)")

      if tag ~= nil then
        block = {
          source = { buf = source, pos = { i } },
          tag = tag,
          code = {},
        }
      end
    else
      if string.match(line, "^%s*```%s*$") then
        block.source.pos[2] = i
        blocks[#blocks + 1] = block
        block = nil
      else
        table.insert(block.code, line)
      end
    end
  end
  return blocks
end

--- @param action sia.BlockAction
--- @param block sia.Block
--- @param replace sia.config.Replace
function M.replace_block(action, block, replace)
  if block.code then
    local edit = action.execute(block)
    if edit then
      flash_highlight(edit.buf, { edit.replace[1] - 1, edit.replace[2] - 1 }, replace.timeout, replace.highlight)
    end
  end
end

--- @param block sia.Block
--- @param replace sia.config.Replace
--- @param padding integer?
function M.insert_block(block, replace, padding)
  if block.code then
    local source_line_count = #block.code
    -- if the LLM generated bad destination buffer or if no buffer was provided.
    utils.select_other_buffer(block.source.buf, function(other)
      local start_range, _ = unpack(vim.api.nvim_win_get_cursor(other.win))
      if padding then
        start_range = start_range - padding
      end
      vim.api.nvim_buf_set_lines(other.buf, start_range, start_range, false, block.code)
      flash_highlight(
        other.buf,
        { start_range, start_range + source_line_count - 1 },
        replace.timeout,
        replace.highlight
      )
    end)
  end
end

local SEARCH = 1
local REPLACE = 2
local NONE = 3

--- Finds the exact match of sequence of lines from search in content.
--- @param content string[] The haystack
--- @param search string[] The needle
--- @return [integer, integer]? pos The start and end line indices of the match
local function find_exact_match(content, search)
  local pos = {}
  for i, line in pairs(content) do
    if line == search[1] then
      local found = true
      pos[1] = i
      if #search > #content - i + 1 then
        found = false
        break
      end

      for j = 2, #search do
        if content[i + j - 1] ~= search[j] then
          found = false
          break
        end
      end
      if found then
        pos[2] = i + #search
        break
      end
    end
  end
  if #pos == 2 then
    return pos
  else
    return nil
  end
end

local function find_deindented_match(content, search)
  local search_trim = {}
  for i, line in pairs(search) do
    search_trim[i] = line:gsub("^%s*", "")
  end

  local content_trim = {}
  for i, line in pairs(content) do
    content_trim[i] = line:gsub("^%s*", "")
  end
  return find_exact_match(content_trim, search_trim)
end

--- @param b sia.Block
--- @return sia.BlockEdit?
local function search_replace_action(b)
  local file = vim.fn.fnamemodify(string.match(b.tag, "file:(.+)"), ":p")
  local buf = utils.ensure_file_is_loaded(file)
  if not buf then
    return nil
  end

  local search = {}
  local replace = {}

  local state = NONE

  for _, line in pairs(b.code) do
    if state == NONE then
      if string.match(line, "^<<<<<<?<?<?<?%s+SEARCH%s*$") then
        state = SEARCH
      else
        goto continue
      end
    else
      if state == SEARCH then
        if string.match(line, "^======?=?=?=?%s*$") then
          state = REPLACE
        else
          search[#search + 1] = line
        end
      elseif state == REPLACE then
        if string.match(line, "^>>>>>>?>?>?>?>%s+REPLACE%s*$") then
          break
        else
          replace[#replace + 1] = line
        end
      end
    end
    ::continue::
  end

  if vim.api.nvim_buf_is_loaded(buf) then
    local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local pos
    -- An empty search should only match an empty file/buffer
    if #search == 0 and #content == 1 and content[1] == "" then
      pos = { 1, 1 }
    else
      pos = find_exact_match(content, search)
      if not pos then
        pos = find_deindented_match(content, search)
      end
    end

    if pos then
      return {
        buf = buf,
        search = { pos = pos, content = search },
        replace = { pos = { pos[1], pos[1] + #replace }, content = replace },
      }
    end
  end
  return nil
end

--- @alias sia.BlockEdit {buf: integer, search: { pos: [integer, integer], content:string[]}, replace: {pos: [integer, integer], content: string[]}}
--- @alias sia.BlockAction { automatic: boolean, manual: boolean, execute_edit: (fun(edit: sia.BlockEdit):nil), find_edit: (fun(block: sia.Block):sia.BlockEdit?) }

--- @type table<string, sia.BlockAction>
M.actions = {
  ["search_replace"] = {
    automatic = true,
    manual = false,
    find_edit = search_replace_action,
    --- @type
    execute_edit = function(ctx)
      local content = { "<<<<<<< User" }
      for _, line in ipairs(ctx.search.content) do
        content[#content + 1] = line
      end
      content[#content + 1] = "======="
      for _, line in ipairs(ctx.replace.content) do
        content[#content + 1] = line
      end
      content[#content + 1] = ">>>>>>> Sia"

      vim.api.nvim_buf_set_lines(ctx.buf, ctx.search.pos[1] - 1, ctx.search.pos[2] - 1, false, content)
      vim.api.nvim_exec_autocmds("User", { pattern = "SiaEditPost", data = { buf = ctx.buf } })
    end,
  },
}

return M
