local utils = require("sia.utils")
local M = {}

--- @param global {show_line_numbers: boolean?, include_cursor: boolean?}
--- @return sia.config.Instruction[]
function M.current_buffer(global)
  global = global or {}
  --- @type sia.config.Instruction[]
  return {
    {
      role = "user",
      persistent = true,
      kind = "buffer",
      description = function(ctx)
        return string.format("%s", utils.get_filename(ctx.buf, ":."))
      end,
      content = function(ctx)
        if not vim.api.nvim_buf_is_loaded(ctx.buf) then
          return nil
        end
        local filename = utils.get_filename(ctx.buf, ":p")
        local line_count = vim.api.nvim_buf_line_count(ctx.buf)
        local instruction = string.format("Here is %s (lines 1 to %d)", filename, line_count)

        if global.show_line_numbers then
          instruction = instruction .. " as shown by cat -n"
        end

        if global.include_cursor and ctx.cursor then
          local cursor_line, cursor_col = ctx.cursor[1], ctx.cursor[2]
          instruction = instruction .. string.format(" - cursor is at line %d, column %d", cursor_line, cursor_col + 1)
        end

        local code = utils.get_content(
          ctx.buf,
          0,
          line_count,
          { show_line_numbers = global.show_line_numbers, max_line_length = 2000 }
        )

        return string.format("%s\n%s", instruction, table.concat(code, "\n"))
      end,
    },
  }
end

--- @param global {show_line_numbers: boolean?}
--- @return sia.config.Instruction[]
function M.current_context(global)
  global = global or {}
  --- @type sia.config.Instruction[]
  return {
    {
      role = "user",
      kind = "context",
      description = function(ctx)
        if ctx.mode == "n" then
          return string.format("Conversation initialized from %s", utils.get_filename(ctx.buf, ":p"))
        end
        if ctx.pos == nil or ctx.pos[2] == -1 then
          return string.format("%s", utils.get_filename(ctx.buf, ":p"))
        end
        return string.format("%s lines %d-%d", utils.get_filename(ctx.buf, ":p"), ctx.pos[1], ctx.pos[2])
      end,
      hide = true,
      content = function(ctx)
        if not vim.api.nvim_buf_is_loaded(ctx.buf) then
          return nil
        end
        local filename = utils.get_filename(ctx.buf, ":p")
        if ctx.mode == "v" then
          local start_line, end_line = 0, -1
          if ctx.pos then
            start_line, end_line = ctx.pos[1], ctx.pos[2]
          end
          local instruction = string.format("Here is %s (lines %d to %d)", filename, start_line, end_line)
          if end_line == -1 then
            start_line = 1
            end_line = vim.api.nvim_buf_line_count(ctx.buf)
            instruction = string.format("Here is %s (lines %d to %d)", filename, start_line, end_line)
          end
          local code = utils.get_content(
            ctx.buf,
            start_line - 1,
            end_line,
            { show_line_numbers = global.show_line_numbers, max_line_length = 2000 }
          )
          if global.show_line_numbers then
            instruction = instruction .. " as shown by cat -n"
          end

          return string.format("%s\n%s", instruction, table.concat(code, "\n"))
        else
          -- local content =
          --   string.format("The conversation was initiated from the file: %s", utils.get_filename(ctx.buf, ":p"))
          --
          -- if ctx.cursor then
          --   content = string.format("%s with the cursor at %d", content, ctx.cursor[1])
          -- end
          return nil
        end
      end,
    },
  }
end

--- @return sia.config.Instruction[]
function M.verbatim()
  return {
    {
      role = "user",
      hide = true,
      kind = "context",
      description = function(ctx)
        return string.format("%s verbatim lines %d-%d", utils.get_filename(ctx.buf, ":."), ctx.pos[1], ctx.pos[2])
      end,
      content = function(ctx)
        if vim.api.nvim_buf_is_loaded(ctx.buf) and vim.api.nvim_buf_is_valid(ctx.buf) and ctx and ctx.mode == "v" then
          return nil
        end
        local start_line, end_line = ctx.pos[1], ctx.pos[2]
        return table.concat(vim.api.nvim_buf_get_lines(ctx.buf, start_line - 1, end_line, false), "\n")
      end,
    },
  }
end

--- @return sia.config.Instruction[]
function M.visible_buffers()
  --- @type sia.config.Instruction[]
  return {
    {
      role = "user",
      persistent = true,
      hide = true,
      description = "Visible buffers in current tab with cursor positions",
      content = function(ctx)
        if ctx.mode ~= "n" then
          return nil
        end
        local buffers = {}
        local current_tab = vim.api.nvim_get_current_tabpage()
        local windows = vim.api.nvim_tabpage_list_wins(current_tab)
        local current_win = vim.api.nvim_get_current_win()

        local buffer_info = {}
        for _, win in ipairs(windows) do
          local buf = vim.api.nvim_win_get_buf(win)
          if vim.api.nvim_buf_is_loaded(buf) and not buffer_info[buf] then
            local relative_name = utils.get_filename(buf, ":.")
            local cursor = vim.api.nvim_win_get_cursor(win)
            local line_count = vim.api.nvim_buf_line_count(buf)
            local is_current = win == current_win

            buffer_info[buf] = {
              relative_name = relative_name,
              hide = vim.bo[buf].buflisted or vim.bo[buf].buftype ~= "" or relative_name == "",
              buf = buf,
              cursor_line = cursor[1],
              cursor_col = cursor[2] + 1,
              line_count = line_count,
              is_current = is_current,
            }
          end
        end

        table.insert(buffers, "Currently visible buffers with cursor positions:")
        for _, info in pairs(buffer_info) do
          if not info.hide then
            local status = info.is_current and " (current)" or ""
            local position_info =
              string.format("line %d, col %d (of %d lines)", info.cursor_line, info.cursor_col, info.line_count)
            table.insert(buffers, string.format("- %s: %s%s", info.relative_name, position_info, status))
          end
        end

        if #buffers == 1 then
          return nil
        end

        return table.concat(buffers, "\n")
      end,
    },
  }
end

return M
