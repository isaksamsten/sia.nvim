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
        if vim.api.nvim_buf_is_valid(ctx.buf) and vim.api.nvim_buf_is_loaded(ctx.buf) then
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
        if ctx.pos[2] == -1 then
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
          local start_line, end_line = ctx.pos[1], ctx.pos[2]
          local instruction = string.format("Here is %s (lines %d to %d)", filename, start_line, end_line)
          if ctx.pos[2] == -1 then
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
          local content =
            string.format("The conversation was initiated from the file: %s", utils.get_filename(ctx.buf, ":p"))

          if ctx.cursor then
            content = string.format("%s with the cursor at %d", content, ctx.cursor[1])
          end
          return content
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

return M
