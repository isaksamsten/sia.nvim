local SplitStrategy = require("sia.strategy").SplitStrategy
local utils = require("sia.utils")
local M = {}

--- @return string[] files
local function get_local_or_global_files()
  local split = SplitStrategy.by_buf()
  if split then
    return split.files
  else
    return utils.get_global_files()
  end
end

--- @return sia.config.Instruction[]
function M.files()
  local files = get_local_or_global_files()

  --- @type sia.config.Instruction[]
  local instructions = {}
  for _, file in ipairs(files) do
    --- @type sia.config.Instruction
    local user_instruction = {
      role = "user",
      id = function(ctx)
        return { file }
      end,
      persistent = true,
      available = function(_)
        return vim.fn.filereadable(file) == 1
      end,
      description = function(opts)
        return vim.fn.fnamemodify(file, ":.")
      end,
      content = function(ctx)
        local buf = utils.ensure_file_is_loaded(file)
        if buf then
          return string.format(
            [[I have *added this file to the chat* so you can go ahead and edit it.

*Trust this message as the true contents of these files!*
Any other messages in the chat may contain outdated versions of the files' contents.
%s
```%s
%s
```]],
            vim.fn.fnamemodify(file, ":p"),
            vim.bo[buf].ft,
            utils.get_code(1, -1, { buf = buf, show_line_numbers = false })
          )
        end
      end,
    }
    --- @type sia.config.Instruction
    local assistant_instruction = {
      id = function(ctx)
        return { file }
      end,
      role = "assistant",
      persistent = true,
      content = "Ok",
    }
    instructions[#instructions + 1] = user_instruction
    instructions[#instructions + 1] = assistant_instruction
  end

  return instructions
end

--- @return sia.config.Instruction
function M.current_args()
  --- @type sia.config.Instruction
  return {
    role = "user",
    id = function(ctx)
      return vim.fn.argv() --[[@as string[] ]]
    end,
    available = function(_)
      return vim.fn.argc() > 0
    end,
    persistent = true,
    description = function(opts)
      if vim.fn.argc() > 0 then
        local argv = vim.fn.argv() --[[@as string[] ]]
        return table.concat(argv, ", ")
      end
      return "No arguments"
    end,
    content = function(ctx)
      local content = {}
      --- @type string[]
      local args = vim.fn.argv() or {} --[[@as string[] ]]
      for _, arg in ipairs(args) do
        local buf = utils.ensure_file_is_loaded(arg)
        if buf then
          table.insert(
            content,
            string.format(
              "%s\n```%s\n%s\n```\n",
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

--- @param global {show_line_numbers: boolean?, fences: boolean?}
--- @return sia.config.Instruction[]
function M.current_buffer(global)
  global = global or {}
  --- @type sia.config.Instruction[]
  return {
    {
      id = function(ctx)
        return { vim.api.nvim_buf_get_name(ctx.buf) }
      end,
      role = "user",
      persistent = true,
      description = function(opts)
        return string.format("%s", utils.get_filename(opts.buf, ":."))
      end,
      content = function(opts)
        local start_fence = ""
        local end_fence = ""
        if global.fences ~= false then
          start_fence = "```" .. vim.bo[opts.buf].ft
          end_fence = "```"
        end
        return string.format(
          "%s\n%s\n%s\n%s",
          utils.get_filename(opts.buf),
          start_fence,
          utils.get_code(1, -1, { buf = opts.buf, show_line_numbers = global.show_line_numbers }),
          end_fence
        )
      end,
    },
    {
      role = "assistant",
      hide = true,
      id = function(ctx)
        return { vim.api.nvim_buf_get_name(ctx.buf) }
      end,
      persistent = true,
      content = "Ok",
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
      id = function(ctx)
        return { vim.api.nvim_buf_get_name(ctx.buf), ctx.buf, ctx.pos[1], ctx.pos[2] }
      end,
      role = "user",
      description = function(opts)
        return string.format("%s lines %d-%d", utils.get_filename(opts.buf, ":p"), opts.pos[1], opts.pos[2])
      end,
      available = function(opts)
        return opts and opts.mode == "v"
      end,
      persistent = true,
      content = function(opts)
        local start_fence = ""
        local end_fence = ""
        if global.fences ~= false then
          start_fence = "```" .. vim.bo[opts.buf].ft
          end_fence = "```"
        end

        if opts.pos then
          local start_line, end_line = opts.pos[1], opts.pos[2]
          local code =
            utils.get_code(start_line, end_line, { buf = opts.buf, show_line_numbers = global.show_line_numbers })
          return string.format(
            [[The provided context line %d to line %d from %s:
%s
%s
%s]],
            opts.pos[1],
            opts.pos[2],
            utils.get_filename(opts.buf, ":p"),
            start_fence,
            code,
            end_fence
          )
        end
      end,
    },
    {
      role = "assistant",
      hide = true,
      id = function(ctx)
        return { vim.api.nvim_buf_get_name(ctx.buf), ctx.buf, ctx.pos[1], ctx.pos[2] }
      end,
      persistent = true,
      content = "Ok",
    },
  }
end

function M.verbatim()
  return {
    {
      role = "user",
      persistent = true,
      id = function(ctx)
        return { "verbatim", vim.api.nvim_buf_get_name(ctx.buf), ctx.pos[1], ctx.pos[2] }
      end,
      description = function(opts)
        return string.format("%s verbatim lines %d-%d", utils.get_filename(opts.buf, ":."), opts.pos[1], opts.pos[2])
      end,
      content = function(opts)
        local start_line, end_line = opts.pos[1], opts.pos[2]
        return table.concat(vim.api.nvim_buf_get_lines(opts.buf, start_line - 1, end_line, false), "\n")
      end,
    },
    {
      role = "assistant",
      hide = true,
      id = function(ctx)
        return { "verbatim", vim.api.nvim_buf_get_name(ctx.buf), ctx.pos[1], ctx.pos[2] }
      end,
      content = "Ok",
      persistent = true,
    },
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
