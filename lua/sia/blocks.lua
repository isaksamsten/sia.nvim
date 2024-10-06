--- @class sia.Block
--- @field source {buf: integer, pos: [integer, integer] }
--- @field target {buf: integer?, pos: [integer?,integer?]}?
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
      local target, target_start, target_end = string.match(line, "^%s*```.+%s+(%d+)%s+replace%-range:(%d+),(%d+)")
      if target and target_start and target_end then
        block = {
          source = { buf = source, pos = { i } },
          target = { buf = tonumber(target), pos = { tonumber(target_start), tonumber(target_end) } },
          code = {},
        }
      elseif string.match(line, "^%s*```%w+%s*$") then
        block = {
          source = { source = source, pos = { i } },
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

--- @param block sia.Block
--- @param replace sia.config.Replace
function M.replace_block(block, replace)
  if block.code then
    if block.target.buf and vim.api.nvim_buf_is_loaded(block.target.buf) then
      local source_line_count = #block.code
      vim.api.nvim_buf_set_lines(block.target.buf, block.target.pos[1] - 1, block.target.pos[2], false, block.code)
      flash_highlight(
        block.target.buf,
        { block.target.pos[1] - 1, block.target.pos[1] + source_line_count - 2 },
        replace.timeout,
        replace.highlight
      )
    end
  end
end

--- @param block sia.Block
--- @param replace sia.config.Replace
--- @param padding integer?
function M.insert_block(block, replace, padding)
  if block.code then
    local source_line_count = #block.code
    if block.target and block.target.buf and vim.api.nvim_buf_is_loaded(block.target.buf) then
      local win = utils.get_window_for_buffer(block.target.buf)
      if win then
        local start_range, _ = unpack(vim.api.nvim_win_get_cursor(win))
        if padding then
          start_range = start_range - padding
        end
        vim.api.nvim_buf_set_lines(block.target.buf, start_range, start_range, false, block.code)
        flash_highlight(
          block.target.buf,
          { start_range, start_range + source_line_count - 1 },
          replace.timeout,
          replace.highlight
        )
        return
      end
    end

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

return M
