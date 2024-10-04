local utils = require("sia.utils")
local M = {}

--- @param show_line_numbers boolean?
--- @return sia.config.Instruction
function M.current_buffer(show_line_numbers)
  --- @type sia.config.Instruction
  return {
    id = function(ctx)
      return { vim.api.nvim_buf_get_name(ctx.buf) }
    end,
    role = "user",
    persistent = true,
    description = function(opts)
      return string.format("%s", utils.get_filename(opts.buf, ":."))
    end,
    content = function(opts)
      return string.format(
        "This is the complete buffer %d (%s)\n```%s\n%s\n```",
        opts.buf,
        utils.get_filename(opts.buf),
        vim.bo[opts.buf].ft,
        utils.get_code(1, -1, { buf = opts.buf, show_line_numbers = show_line_numbers })
      )
    end,
  }
end

--- @param show_line_numbers boolean?
--- @return sia.config.Instruction
function M.current_context(show_line_numbers)
  --- @type sia.config.Instruction
  return {
    id = function(ctx)
      return { vim.api.nvim_buf_get_name(ctx.buf), ctx.buf, ctx.start_line, ctx.end_line }
    end,
    role = "user",
    description = function(opts)
      return string.format("%s lines %d-%d", utils.get_filename(opts.buf, ":."), opts.pos[1], opts.pos[2])
    end,
    available = function(opts)
      print(vim.inspect(opts))
      return opts and opts.mode == "v"
    end,
    persistent = true,
    content = function(opts)
      if opts.pos then
        local start_line, end_line = opts.pos[1], opts.pos[2]
        local code = utils.get_code(start_line, end_line, { buf = opts.buf, show_line_numbers = show_line_numbers })
        return string.format(
          [[The provided context from buffer %d (%s):
```%s
%s
```]],
          opts.buf,
          utils.get_filename(opts.buf),
          vim.bo[opts.buf].ft,
          code
        )
      end
    end,
  }
end

--- @param fname string
--- @return sia.config.Instruction
function M.read_file(fname)
  --- @type sia.config.Instruction
  return {
    id = function(ctx)
      return { fname }
    end,
    role = "user",
    description = function(opts)
      return vim.fn.fnamemodify(fname, ":.")
    end,
    available = function(opts)
      return vim.fn.filereadable(fname) == 1
    end,
    persistent = true,
    content = function(opts)
      if vim.fn.filereadable(fname) == 1 then
        return string.format(
          "This is the complete file %s:\n```%s\n%s\n```",
          fname,
          vim.filetype.match({ filename = fname }) or "",
          table.concat(vim.fn.readfile(fname, ""), "\n")
        )
      end
    end,
  }
end

return M
