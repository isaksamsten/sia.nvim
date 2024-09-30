local utils = require("sia.utils")
local M = {}

function M.current_buffer(show_line_numbers)
  return {
    role = "user",
    hidden = function(opts)
      return string.format("%s is included in the conversation.", utils.get_filename(opts.buf))
    end,
    reuse = true,
    content = function(opts)
      return string.format(
        "This is the complete buffer %d (%s) written in %s:\n%s",
        opts.buf,
        utils.get_filename(opts.buf),
        opts.ft,
        utils.get_code(1, -1, { bufnr = opts.buf, show_line_numbers = show_line_numbers })
      )
    end,
  }
end

function M.current_context(show_line_numbers)
  return {
    role = "user",
    hidden = function(opts)
      if opts.mode == "v" then
        local end_line = opts.end_line
        if opts.context_is_buffer then
          end_line = vim.api.nvim_buf_line_count(opts.buf)
        end
        return string.format(
          "Lines %d to %d from %s is included in the conversation",
          opts.start_line,
          end_line,
          utils.get_filename(opts.buf)
        )
      else
        return nil
      end
    end,
    reuse = true,
    content = function(opts)
      if opts.mode == "v" or opts.bang then
        local code =
          utils.get_code(opts.start_line, opts.end_line, { bufnr = opts.buf, show_line_numbers = show_line_numbers })
        return string.format(
          [[The provided context from buffer %d (%s) is written in %s:
%s]],
          opts.buf,
          utils.get_filename(opts.buf),
          opts.ft,
          code
        )
      else
        return "The context is written in " .. opts.ft
      end
    end,
  }
end

return M
