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
      kind = "buffer",
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
          return ""
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
            end_line - 1,
            { show_line_numbers = global.show_line_numbers, max_line_length = 2000 }
          )
          if global.show_line_numbers then
            instruction = instruction .. " as shown by cat -n"
          end

          return string.format(
            [[%s
%s]],
            instruction,
            table.concat(code, "\n")
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
