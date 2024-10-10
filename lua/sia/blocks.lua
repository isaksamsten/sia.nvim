--- @class sia.Block
--- @field source {buf: integer, pos: [integer, integer] }
--- @field tag string?
--- @field code string[]

local M = {}

local utils = require("sia.utils")
local matcher = require("sia.matcher")

local ns_flash_id = vim.api.nvim_create_namespace("sia_flash") -- Create a namespace for the highlight

--- Flash hl_group over the lines between pos[1] and pos[2] for timeout.
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

--- Select a block and execute the callback with the block as argument.
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

--- Insert a given block in the buffer above the specified line.
--- @param buf integer
--- @param line integer
--- @param block sia.Block
--- @param replace sia.config.Replace
function M.insert_block_above(buf, line, block, replace)
  vim.api.nvim_buf_set_lines(buf, line - 1, line - 1, false, block.code)
  flash_highlight(buf, { line - 1, line + #block.code - 1 }, replace.timeout, replace.highlight)
end

--- Insert the given block in the buffer below the specified line.
--- @param buf integer
--- @param line integer
--- @param block sia.Block
--- @param replace sia.config.Replace
function M.insert_block_below(buf, line, block, replace)
  vim.api.nvim_buf_set_lines(buf, line, line, false, block.code)
  flash_highlight(buf, { line, line + #block.code - 1 }, replace.timeout, replace.highlight)
end

--- Insert a block replacing the lines between start and end.
--- @param buf integer
--- @param start_line integer
--- @param end_line integer
--- @param block sia.Block
--- @param replace sia.config.Replace
function M.insert_block_at(buf, start_line, end_line, block, replace)
  vim.api.nvim_buf_set_lines(buf, start_line - 1, end_line, false, block.code)
  flash_highlight(buf, { start_line - 1, start_line + #block.code - 2 }, replace.timeout, replace.highlight)
end

--- Parse fenced code blocks.
--- @param source integer
--- @param start_line integer
--- @param response string[]
--- @return sia.Block[]
function M.parse_blocks(source, start_line, response)
  --- @type sia.Block?
  local block = nil

  --- @type sia.Block[]
  local blocks = {}

  for i, line in ipairs(response) do
    if block == nil then
      local tag = string.match(line, "^%s*```.+%s*(.*)")

      if tag ~= nil then
        block = {
          source = { buf = source, pos = { i + start_line } },
          tag = tag,
          code = {},
        }
      end
    else
      if string.match(line, "^%s*```%s*$") then
        block.source.pos[2] = i + start_line
        blocks[#blocks + 1] = block
        block = nil
      else
        table.insert(block.code, line)
      end
    end
  end
  return blocks
end

--- Given the specified action, find the target buffer and insert the block.
--- Adds all edits to the quickfix list.
--- @param block_action sia.BlockAction
--- @param blocks sia.Block[]
function M.replace_all_blocks(block_action, blocks)
  if block_action and block_action.automatic_edit then
    local edits = {}
    local edit_bufs = {}
    for _, block in ipairs(blocks) do
      local edit = block_action.find_edit(block)
      if edit and edit.buf and edit.search.pos then
        edits[#edits + 1] = {
          bufnr = edit.buf,
          filename = vim.api.nvim_buf_get_name(edit.buf),
          lnum = edit.replace.pos[1],
          text = edit.search.content[1] or "",
        }
        edit_bufs[edit.buf] = true
        block_action.automatic_edit(edit)
      end
    end
    for buf, _ in pairs(edit_bufs) do
      vim.api.nvim_exec_autocmds("User", { pattern = "SiaEditPost", data = { buf = buf } })
    end

    if #edits > 0 then
      vim.fn.setqflist(edits, "r")
      vim.cmd("copen")
    end
  end
end

--- Given the specified action, find the target buffer and insert the block.
--- @param action sia.BlockAction
--- @param block sia.Block
--- @param replace sia.config.Replace
function M.replace_block(action, block, replace)
  if block.code then
    local edit = action.find_edit(block)
    if edit and edit.buf and edit.search.pos then
      local pos = action.manual_edit(edit)
      if pos then
        flash_highlight(edit.buf, { pos[1] - 1, pos[2] - 1 }, replace.timeout, replace.highlight)
        vim.api.nvim_exec_autocmds("User", { pattern = "SiaEditPost", data = { buf = edit.buf } })
      end
    end
  end
end

--- @param action sia.BlockAction
--- @param block sia.Block
--- @param replace sia.config.Replace
--- @param padding integer?
function M.insert_block(action, block, replace, padding)
  if block.code then
    utils.select_other_buffer(block.source.buf, function(other)
      local start_range, _ = unpack(vim.api.nvim_win_get_cursor(other.win))
      if padding then
        start_range = start_range - padding
      end
      local edit = action.find_edit(block)
      if edit then
        edit.buf = other.buf
        edit.search.pos = { start_range + 1, start_range }
        local pos = action.manual_edit(edit)
        if pos then
          flash_highlight(edit.buf, { pos[1] - 1, pos[2] - 1 }, replace.timeout, replace.highlight)
          vim.api.nvim_exec_autocmds("User", { pattern = "SiaEditPost", data = { buf = edit.buf } })
          vim.api.nvim_exec_autocmds("User", { pattern = "SiaEditPost", data = { buf = other.buf } })
        end
      end
    end)
  end
end

local SEARCH = 1
local REPLACE = 2
local NONE = 3

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

  -- TODO: we assume that the code block only contains one search/replace block
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
      --- Never match an empty search in a non-empty file
      if #search == 0 and #content > 1 then
        pos = nil
      else
        pos = matcher.find_subsequence_span(search, content, { ignore_whitespace = false })
        if not pos then
          pos = matcher.find_subsequence_span(search, content, { ignore_whitespace = true })
          if not pos then
            pos = matcher.find_subsequence_span(search, content, { ignore_whitespace = true, threshold = 0.8 })
          end
        end
      end
    end

    if pos then
      return {
        buf = buf,
        search = { pos = pos, content = search },
        replace = { pos = { pos[1], pos[1] + #replace }, content = replace },
      }
    else
      return {
        buf = buf,
        search = { content = search },
        replace = { content = replace },
      }
    end
  else
    return {
      buf = buf,
      search = { content = search },
      replace = { content = replace },
    }
  end
end

--- @alias sia.BlockEdit {buf: integer?, search: { pos: [integer, integer]?, content:string[]}, replace: {pos: [integer, integer]?, content: string[]}}
--- @alias sia.BlockAction { automatic: boolean, manual_edit: (fun(edit:sia.BlockEdit):[integer,integer]?), automatic_edit: (fun(edit: sia.BlockEdit):[integer, integer]?)?, find_edit: (fun(block: sia.Block):sia.BlockEdit?) }

--- @type table<string, sia.BlockAction>
M.actions = {
  ["search_replace"] = {
    --- Should the split strategy automatically trigger it?
    automatic = false,

    --- Find edits and their location
    find_edit = search_replace_action,
    --- @param edit sia.BlockEdit
    manual_edit = function(edit)
      if edit.buf and edit.search.pos then
        vim.api.nvim_buf_set_lines(edit.buf, edit.search.pos[1] - 1, edit.search.pos[2], false, edit.replace.content)
        return { edit.search.pos[1], edit.search.pos[1] + #edit.replace.content - 1 }
      end
    end,
    --- @param edit sia.BlockEdit
    automatic_edit = function(edit)
      if edit.buf and edit.search.pos then
        local content = { "<<<<<<< User" }
        for _, line in ipairs(edit.search.content) do
          content[#content + 1] = line
        end
        content[#content + 1] = "======="
        for _, line in ipairs(edit.replace.content) do
          content[#content + 1] = line
        end
        content[#content + 1] = ">>>>>>> Sia"

        vim.api.nvim_buf_set_lines(edit.buf, edit.search.pos[1] - 1, edit.search.pos[2], false, content)
        return { edit.search.pos[1], edit.search.pos[1] + #content - 1 }
      end
    end,
  },
  verbatim = {
    automatic = false,
    find_edit = function(block)
      return { search = { content = block.code }, replace = { content = block.code } }
    end,
    automatic_edit = nil,
    manual_edit = function(edit)
      if edit.buf and edit.search.pos then
        vim.api.nvim_buf_set_lines(edit.buf, edit.search.pos[1] - 1, edit.search.pos[2], false, edit.replace.content)
        return { edit.search.pos[1], edit.search.pos[1] + #edit.replace.content - 1 }
      end
    end,
  },
}

--- @param name string
--- @param opts { automatic: boolean? }
--- @return sia.BlockAction?
function M.customize_action(name, opts)
  local action = M.actions[name]
  if action then
    action = vim.deepcopy(action)
    action.automatic = opts.automatic or action.automatic
    return action
  end
  return nil
end

return M
