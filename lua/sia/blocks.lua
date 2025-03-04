--- @class sia.Block
--- @field pos [integer, integer]
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
local function flash_highlight(bufnr, pos, timeout)
  local extmark = vim.api.nvim_buf_set_extmark(
    bufnr,
    ns_flash_id,
    pos[1],
    0,
    { end_line = pos[2] + 1, hl_eol = true, hl_group = "SiaInsert" }
  )

  local timer = vim.loop.new_timer()
  timer:start(
    timeout or 300,
    0,
    vim.schedule_wrap(function()
      pcall(vim.api.nvim_buf_del_extmark, bufnr, ns_flash_id, extmark)
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
  flash_highlight(buf, { line - 1, line + #block.code - 1 }, replace.timeout)
end

--- Insert the given block in the buffer below the specified line.
--- @param buf integer
--- @param line integer
--- @param block sia.Block
--- @param replace sia.config.Replace
function M.insert_block_below(buf, line, block, replace)
  vim.api.nvim_buf_set_lines(buf, line, line, false, block.code)
  flash_highlight(buf, { line, line + #block.code - 1 }, replace.timeout)
end

--- Insert a block replacing the lines between start and end.
--- @param buf integer
--- @param start_line integer
--- @param end_line integer
--- @param block sia.Block
--- @param replace sia.config.Replace
function M.insert_block_at(buf, start_line, end_line, block, replace)
  vim.api.nvim_buf_set_lines(buf, start_line - 1, end_line, false, block.code)
  flash_highlight(buf, { start_line - 1, start_line + #block.code - 2 }, replace.timeout)
end

--- Parse fenced code blocks.
--- @param start_line integer
--- @param response string[]
--- @return sia.Block[]
function M.parse_blocks(start_line, response)
  --- @type sia.Block?
  local block = nil

  --- @type sia.Block[]
  local blocks = {}

  for i, line in ipairs(response) do
    if block == nil then
      local tag = string.match(line, "^%s*```%s*[%w_]+%s*(.*)")

      if tag ~= nil then
        block = {
          pos = { i + start_line },
          tag = tag,
          code = {},
        }
      end
    else
      if string.match(line, "^%s*```%s*$") then
        block.pos[2] = i + start_line
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
--- @param opts {timeout: integer?, apply_marker: boolean?}?
function M.replace_all_blocks(block_action, blocks, opts)
  opts = opts or {}
  if block_action then
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
        if opts.apply_marker then
          block_action.apply_marker(edit)
        else
          local pos = block_action.apply_edit(edit)
          if pos then
            flash_highlight(edit.buf, { pos[1] - 1, pos[2] - 1 }, opts.timeout)
          end
        end
      end
    end
    for buf, _ in pairs(edit_bufs) do
      vim.api.nvim_exec_autocmds("User", {
        pattern = "SiaEditPost",
        data = { buf = buf, marker = opts.apply_marker },
      })
    end

    if #edits > 0 and opts.apply_marker then
      vim.fn.setqflist(edits, "r")
      vim.cmd("copen")
    end
  end
end

--- Given the specified action, find the target buffer and insert the block.
--- @param action sia.BlockAction
--- @param block sia.Block
--- @param opts {timeout: integer?, apply_marker: boolean?}?
function M.replace_block(action, block, opts)
  opts = opts or {}
  if block.code then
    local edit = action.find_edit(block)
    if edit and edit.buf and edit.search.pos then
      if opts.apply_marker then
        action.apply_marker(edit)
      else
        local pos = action.apply_edit(edit)
        if pos then
          flash_highlight(edit.buf, { pos[1] - 1, pos[2] - 1 }, opts.timeout)
          vim.api.nvim_exec_autocmds("User", { pattern = "SiaEditPost", data = { buf = edit.buf, marker = false } })
        end
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
    utils.select_other_buffer(vim.api.nvim_get_current_buf(), function(other)
      local start_range, _ = unpack(vim.api.nvim_win_get_cursor(other.win))
      if padding then
        start_range = start_range - padding
      end
      local edit = action.find_edit(block)
      if edit then
        -- We need to manually set the buffer which will be edited
        edit.buf = other.buf
        edit.search.pos = { start_range + 1, start_range }
        local pos = action.apply_edit(edit)
        if pos then
          flash_highlight(edit.buf, { pos[1] - 1, pos[2] - 1 }, replace.timeout)
          vim.api.nvim_exec_autocmds("User", { pattern = "SiaEditPost", data = { buf = edit.buf, marker = false } })
        end
      end
    end)
  end
end

--- @param b sia.Block
--- @return sia.BlockEdit?
local function search_replace_action(b)
  local file = string.match(b.tag, "file:(.+)")
  if not file then
    return nil
  end

  file = vim.fn.fnamemodify(file, ":p")
  local buf = utils.ensure_file_is_loaded(file)
  if not buf then
    return nil
  end

  local marker = utils.partition_marker(b.code, {
    before = "^<<<<<<?<?<?<?%s+SEARCH%s*",
    delimiter = "^======?=?=?=?%s*$",
    after = "^>>>>>>?>?>?>?>%s+REPLACE%s*",
  })

  -- If we didn't find a search/replace block try a more relaxed search
  -- of any markers
  if not marker.before and not marker.after then
    marker = utils.partition_marker(b.code)
  end

  -- if we still don't find anything, we abort.
  if not marker.before and not marker.after then
    return nil
  end

  -- if all lines in search are white space, empty the list
  -- The LLM is sometimes lazy, and outputs an empty line for search.
  -- This will match the first empty line, but we want to insert it
  -- at the end.
  local all_empty = true
  local search = marker.before or {}
  local replace = marker.after or {}
  for _, line in ipairs(search) do
    if not string.match(line, "^%s*$") then
      all_empty = false
      break
    end
  end
  if all_empty then
    search = {}
  end

  if vim.api.nvim_buf_is_loaded(buf) then
    local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local pos
    -- Empty search in an empty buffer, insert at the first line
    if #search == 0 and #content == 1 and content[1] == "" then
      pos = { 1, 1 }
    -- Empty search in a full buffer, insert after the last line
    elseif #search == 0 and #content > 1 then
      pos = { #content + 1, #content + 1 }
    else
      -- We try a few ways for finding the search region in order of complexity.
      -- First try with an exact match
      pos = matcher.find_subsequence_span(search, content, { ignore_whitespace = false })
      if not pos then
        -- If that fails, we try with a match ignoring empty lines
        pos = matcher.find_subsequence_span(search, content, { ignore_whitespace = true })
        if not pos then
          -- If that fails, we resort to an approximate match, without empty lines
          pos = matcher.find_subsequence_span(search, content, { ignore_whitespace = true, threshold = 0.8 })
          if not pos then
            -- If that fails, we resort to an even more approximate match where we don't have a
            -- hard threshold on specific lines but that the average score for the entire region
            -- needs on average 0.90.
            pos = matcher.find_best_subsequence_span(
              search,
              content,
              { ignore_whitespace = true, threshold = 0.9, limit = 1 }
            )
            if #pos > 0 then
              pos = pos[1].span
            else
              pos = nil
            end
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

--- @class sia.BlockEdit
--- @field buf integer?
--- @field search { pos: [integer, integer]?, content:string[]}
--- @field replace {pos: [integer, integer]?, content: string[]}}

--- @class sia.BlockAction
--- @field apply_edit fun(edit: sia.BlockEdit):[integer, integer]?
--- @field apply_marker fun(edit: sia.BlockEdit):[integer, integer]?
--- @field find_edit fun(block: sia.Block):sia.BlockEdit?

--- @type table<string, sia.BlockAction>
M.actions = {
  --- @type sia.BlockAction
  ["search_replace"] = {
    --- Find edits and their location
    find_edit = search_replace_action,
    --- @param edit sia.BlockEdit
    apply_edit = function(edit)
      if edit.buf and edit.search.pos then
        vim.api.nvim_buf_set_lines(edit.buf, edit.search.pos[1] - 1, edit.search.pos[2], false, edit.replace.content)
        return { edit.search.pos[1], edit.search.pos[1] + #edit.replace.content - 1 }
      end
    end,
    --- @param edit sia.BlockEdit
    apply_marker = function(edit)
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
    find_edit = function(block)
      return { search = { content = block.code }, replace = { content = block.code } }
    end,
    apply_edit = function(edit)
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
function M.custom_action(name, opts)
  local action = M.actions[name]
  if action then
    action = vim.deepcopy(action)
    action.automatic = opts.automatic or action.automatic
    return action
  end
  return nil
end

--- @param content string[]
function M.replace_blocks_callback(context, content)
  local blocks = M.parse_blocks(0, content)
  local action = M.actions["search_replace_edit"]

  if action and #blocks > 0 then
    vim.schedule(function()
      M.replace_all_blocks(action, blocks)
    end)
  else
    require("sia.utils").create_markdown_split(content, { cmd = "new|resize 20%" })
  end
end

M.actions["search_replace_edit"] = M.custom_action("search_replace", { automatic = true })

return M
