local utils = require("sia.utils")
local M = {}

--- @param global {show_line_numbers: boolean?, fences: boolean?}
--- @return sia.config.Instruction[]
function M.current_buffer(global)
  global = global or {}
  --- @type sia.config.Instruction[]
  return {
    {
      role = "user",
      persistent = true,
      description = function(ctx)
        return string.format("%s", utils.get_filename(ctx.buf, ":."))
      end,
      content = function(ctx)
        if vim.api.nvim_buf_is_valid(ctx.buf) and vim.api.nvim_buf_is_loaded(ctx.buf) then
          return nil
        end
        local start_fence = ""
        local end_fence = ""
        if global.fences then
          start_fence = "```" .. vim.bo[ctx.buf].ft
          end_fence = "```"
        end
        return string.format(
          "%s (%s)\n%s\n%s\n%s",
          utils.get_filename(ctx.buf, ":p"),
          vim.bo[ctx.buf].ft,
          start_fence,
          utils.get_code(1, -1, { buf = ctx.buf, show_line_numbers = global.show_line_numbers }),
          end_fence
        )
      end,
    },
  }
end

--- @param global {show_line_numbers: boolean?, fences: boolean?}
--- @return sia.config.Instruction[]
function M.current_context(global)
  global = global or {}
  --- @type sia.config.Instruction[]
  return {
    {
      role = "user",
      description = function(ctx)
        if ctx.pos[2] == -1 then
          return string.format("%s", utils.get_filename(ctx.buf, ":p"))
        end
        return string.format("%s lines %d-%d", utils.get_filename(ctx.buf, ":p"), ctx.pos[1], ctx.pos[2])
      end,
      hide = true,
      content = function(ctx)
        if not vim.api.nvim_buf_is_loaded(ctx.buf) then
          return ""
        end
        local start_fence = ""
        local end_fence = ""
        if global.fences then
          start_fence = "```" .. vim.bo[ctx.buf].ft
          end_fence = "```"
        end
        if ctx.mode == "v" or ctx.pos[2] > 0 then
          local start_line, end_line = ctx.pos[1], ctx.pos[2]
          local instruction = string.format(
            [[
I have *added this file (lines %d to %d) to the chat* so you can go ahead and edit it.
%s]],
            start_line,
            end_line,
            utils.get_filename(ctx.buf, ":p")
          )
          if ctx.pos[2] == -1 then
            start_line = 1
            end_line = vim.api.nvim_buf_line_count(ctx.buf)
            instruction = string.format(
              [[
I have *added this file to the chat* so you can go ahead and edit it.
%s]],
              utils.get_filename(ctx.buf, ":p")
            )
          end
          local code =
            utils.get_code(start_line, end_line, { buf = ctx.buf, show_line_numbers = global.show_line_numbers })
          return string.format(
            [[%s
%s
%s
%s]],
            instruction,
            start_fence,
            code,
            end_fence
          )
        else
          return string.format(
            "The conversation was initiated from the file: %s. This is only a snapshot and I might discuss other files later",
            utils.get_filename(ctx.buf, ":p")
          )
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
