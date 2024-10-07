local utils = require("sia.utils")
local M = {}

--- @param file string
local function ensure_file_is_loaded(file)
  local bufnr = vim.fn.bufnr(file)
  print(bufnr, file)
  if bufnr == -1 or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    local status, err = pcall(function()
      bufnr = vim.fn.bufadd(file)
      vim.fn.bufload(bufnr)
      print("loaded ", file, "into", bufnr)
    end)
    if not status then
      vim.notify(err)
      return nil
    end
  end

  return bufnr
end

--- @return sia.config.Instruction
function M.current_args()
  --- @type sia.config.Instruction
  return {
    role = "user",
    id = function(ctx)
      return { vim.fn.argv() }
    end,
    available = function(opts)
      return vim.fn.argc() > 0 -- and all files exist
    end,
    persistent = true,
    description = function(opts)
      if vim.fn.argc() > 0 then
        local argv = vim.fn.argv() --[[@as string[] ]]
        return table.concat(argv, " ")
      end
      return vim.fn.argv() --[[@as string ]]
    end,
    content = function(ctx)
      local content = {}
      --- @type string[]
      local args
      if vim.fn.argc() == 1 then
        local arg = vim.fn.argv() --[[@as string ]]
        args = { arg }
      else
        args = vim.fn.argv() --[[@as string[] ]]
      end

      for _, arg in ipairs(args) do
        local buf = ensure_file_is_loaded(arg)
        if buf then
          print(vim.api.nvim_buf_is_valid(buf), vim.api.nvim_buf_is_loaded(buf), buf, arg)
          table.insert(
            content,
            string.format(
              "%s\n```%s\n%s\n```",
              arg,
              vim.bo[buf].ft,
              utils.get_code(1, -1, { buf = buf, show_line_numbers = false })
            )
          )
        end
      end
      return table.concat(content, "\n")
    end,
  }
end

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

function M.verbatim()
  return {
    role = "user",
    persisetent = true,
    id = function(ctx)
      return { "verbatim", vim.api.nvim_buf_get_name(ctx.buf), ctx.start_line, ctx.end_line }
    end,
    description = function(opts)
      return string.format("%s verbatim lines %d-%d", utils.get_filename(opts.buf, ":."), opts.pos[1], opts.pos[2])
    end,
    content = function(opts)
      local start_line, end_line = opts.pos[1], opts.pos[2]
      return table.concat(vim.api.nvim_buf_get_lines(opts.buf, start_line - 1, end_line, false), "\n")
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
