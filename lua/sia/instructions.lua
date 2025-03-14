local SplitStrategy = require("sia.strategy").SplitStrategy
local utils = require("sia.utils")
local M = {}

--- @param conversation sia.Conversation
--- @return sia.config.Instruction[]
function M.files(conversation)
  local files = utils.get_global_files()
  if conversation.files then
    files = conversation.files
  end

  --- @type sia.config.Instruction[]
  local instructions = {}
  for _, file in ipairs(files) do
    --- @type sia.config.Instruction
    local user_instruction = {
      role = "user",
      id = function(ctx)
        return { "user", file }
      end,
      persistent = true,
      available = function(_)
        return vim.fn.filereadable(file) == 1
      end,
      description = function(ctx)
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
        return { "assistant", file }
      end,
      available = function(_)
        return vim.fn.filereadable(file) == 1
      end,
      role = "assistant",
      persistent = true,
      hide = true,
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
    description = function(ctx)
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
        return { "buffer", "user", ctx.buf }
      end,
      available = function(ctx)
        return vim.api.nvim_buf_is_valid(ctx.buf) and vim.api.nvim_buf_is_loaded(ctx.buf)
      end,
      role = "user",
      persistent = true,
      description = function(ctx)
        return string.format("%s", utils.get_filename(ctx.buf, ":."))
      end,
      content = function(ctx)
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
    {
      role = "assistant",
      hide = true,
      id = function(ctx)
        return { "buffer", "assistant", ctx.buf }
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
        return { "user", ctx.buf, ctx.pos[1], ctx.pos[2] }
      end,
      role = "user",
      description = function(ctx)
        return string.format("%s lines %d-%d", utils.get_filename(ctx.buf, ":p"), ctx.pos[1], ctx.pos[2])
      end,
      available = function(ctx)
        return vim.api.nvim_buf_is_valid(ctx.buf) and vim.api.nvim_buf_is_loaded(ctx.buf) and ctx and ctx.mode == "v"
      end,
      persistent = true,
      content = function(ctx)
        local start_fence = ""
        local end_fence = ""
        if global.fences then
          start_fence = "```" .. vim.bo[ctx.buf].ft
          end_fence = "```"
        end

        if ctx.pos then
          local start_line, end_line = ctx.pos[1], ctx.pos[2]
          local code =
            utils.get_code(start_line, end_line, { buf = ctx.buf, show_line_numbers = global.show_line_numbers })
          return string.format(
            [[The provided context line %d to line %d from %s (%s):
%s
%s
%s]],
            ctx.pos[1],
            ctx.pos[2],
            utils.get_filename(ctx.buf, ":p"),
            vim.bo[ctx.buf].ft,
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
        return { "assistant", ctx.buf, ctx.pos[1], ctx.pos[2] }
      end,
      available = function(ctx)
        return vim.api.nvim_buf_is_valid(ctx.buf) and vim.api.nvim_buf_is_loaded(ctx.buf) and ctx and ctx.mode == "v"
      end,
      persistent = true,
      content = "Ok",
    },
  }
end

--- @return sia.config.Instruction[]
function M.buffer(bufnr, global)
  global = global or {}
  --- @type sia.config.Instruction[]
  return {
    {
      persistent = true,
      role = "user",
      id = function(ctx)
        return { "user", "buffer", bufnr }
      end,
      description = function(ctx)
        return string.format("%s", utils.get_filename(bufnr, ":."))
      end,
      available = function(ctx)
        return vim.api.nvim_buf_is_loaded(bufnr) and vim.api.nvim_buf_is_valid(bufnr)
      end,
      content = function(ctx)
        local start_fence = ""
        local end_fence = ""
        if global.fences ~= false then
          start_fence = "```" .. vim.bo[bufnr].ft
          end_fence = "```"
        end
        return string.format(
          "%s\n%s\n%s\n%s",
          utils.get_filename(bufnr, ":p"),
          start_fence,
          utils.get_code(1, -1, { buf = bufnr, show_line_numbers = global.show_line_numbers }),
          end_fence
        )
      end,
    },
    {
      role = "assistant",
      hide = true,
      id = function(ctx)
        return { "buffer", "assistant", bufnr }
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
        return { "verbatim", ctx.buf, ctx.pos[1], ctx.pos[2] }
      end,
      available = function(ctx)
        return vim.api.nvim_buf_is_loaded(ctx.buf) and vim.api.nvim_buf_is_valid(ctx.buf) and ctx and ctx.mode == "v"
      end,
      description = function(ctx)
        return string.format("%s verbatim lines %d-%d", utils.get_filename(ctx.buf, ":."), ctx.pos[1], ctx.pos[2])
      end,
      content = function(ctx)
        local start_line, end_line = ctx.pos[1], ctx.pos[2]
        return table.concat(vim.api.nvim_buf_get_lines(ctx.buf, start_line - 1, end_line, false), "\n")
      end,
    },
    {
      role = "assistant",
      hide = true,
      available = function(ctx)
        return vim.api.nvim_buf_is_loaded(ctx.buf) and vim.api.nvim_buf_is_valid(ctx.buf) and ctx and ctx.mode == "v"
      end,
      id = function(ctx)
        return { "verbatim", vim.api.nvim_buf_get_name(ctx.buf), ctx.pos[1], ctx.pos[2] }
      end,
      content = "Ok",
      persistent = true,
    },
  }
end

--- @param opts {mark: string, mark_lnum: integer}?
--- @return sia.config.Instruction[]
function M.context(buf, pos, opts)
  opts = opts or {}
  --- @type sia.config.Instruction[]
  return {
    {
      role = "user",
      persistent = true,
      available = function()
        return vim.api.nvim_buf_is_loaded(buf)
      end,
      description = function()
        return string.format("%s verbatim lines %d-%d", utils.get_filename(buf, ":."), pos[1], pos[2])
      end,
      content = function()
        local lines = vim.api.nvim_buf_get_lines(buf, pos[1] - 1, pos[2] - 1, false)
        if opts.mark then
          local mark = opts.mark_lnum - (pos[1] - 1)
          table.insert(lines, mark, "█" .. opts.mark)
        end
        local c = string.format(
          "The provided context from line %d to line %d in %s\n```%s\n%s\n```",
          pos[1],
          pos[2],
          utils.get_filename(buf, ":."),
          vim.bo[buf].ft,
          table.concat(lines, "\n")
        )
        return c
      end,
    },
    {
      role = "assistant",
      persistent = true,
      id = function()
        return { "context", pos, vim.api.nvim_buf_get_name(buf) }
      end,
      available = function()
        return vim.api.nvim_buf_is_loaded(buf)
      end,
      hide = true,
      content = "Ok",
    },
  }
end

return M
