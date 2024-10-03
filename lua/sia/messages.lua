local utils = require("sia.utils")
local M = {}

function M.current_buffer(show_line_numbers)
  return {
    role = "user",
    hidden = function(opts)
      return string.format("%s is included in the conversation.", utils.get_filename(opts.buf))
    end,
    persistent = true,
    --- @param opts sia.Context
    content = function(opts)
      return string.format(
        "This is the complete buffer %d (%s) written in %s:\n%s",
        opts.buf,
        utils.get_filename(opts.buf),
        vim.bo[opts.buf].ft,
        utils.get_code(1, -1, { buf = opts.buf, show_line_numbers = show_line_numbers })
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
    persistent = true,
    --- @param opts sia.Context
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

return M
