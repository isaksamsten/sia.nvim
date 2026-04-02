local M = {}

--- @param buf integer
--- @param query string?
local function get_filename(buf, query)
  local full_path = vim.api.nvim_buf_get_name(buf)
  return vim.fn.fnamemodify(full_path, query or ":t")
end

function M.environment()
  local os_name = vim.loop.os_uname().sysname
  local os_version = vim.loop.os_uname().release
  local machine = vim.loop.os_uname().machine

  local cwd = vim.uv.cwd()

  local nvim_version = string.format(
    "%d.%d.%d",
    vim.version().major,
    vim.version().minor,
    vim.version().patch
  )

  local datetime = os.date("%Y-%m-%d %H:%M:%S %Z")

  local shell = vim.env.SHELL or "unknown"
  local term = vim.env.TERM or "unknown"
  local user = vim.env.USER or vim.env.USERNAME or "unknown"

  local git_info = ""
  if vim.fn.isdirectory(".git") == 1 then
    local branch = vim.fn.system("git branch --show-current 2>/dev/null"):gsub("\n", "")
    local commit =
      vim.fn.system("git rev-parse --short HEAD 2>/dev/null"):gsub("\n", "")
    if branch ~= "" and commit ~= "" then
      git_info = string.format(" Git: %s (%s)", branch, commit)
    end
  end

  return string.format(
    [[System Information:

- OS: %s %s (%s)
- User: %s
- Shell: %s
- Terminal: %s
- Neovim: v%s
- Working Directory: %s
- %s
- Timestamp: %s

This information shows the current system environment where the AI assistant is
operating through Neovim.]],
    os_name,
    os_version,
    machine,
    user,
    vim.fn.fnamemodify(shell, ":t"),
    term,
    nvim_version,
    cwd,
    git_info,
    datetime
  )
end

function M.file_tree()
  local command
  if vim.fn.executable("fd") == 1 then
    command = { "fd", "--type", "f" }
  else
    command = { "find", ".", "-type", "f", "-not", "-path", "'./.git/*'" }
  end
  local obj = vim.system(command, { timeout = 1000 }):wait()
  if obj.code ~= 0 then
    return nil
  end
  local files = vim.split(obj.stdout or "", "\n", { trimempty = true })
  if #files == 0 then
    return nil
  end
  return string.format(
    [[Below is the current directory structure. It does not include
hidden files or directories. The listing is immutable and represents the start
of the conversation. Use the glob tool to refresh your understanding.
%s]],
    table.concat(require("sia.utils").limit_files(files), "\n")
  )
end
function M.agents_md()
  local filename = vim.fs.joinpath(vim.uv.cwd(), "AGENTS.md")
  if vim.fn.filereadable(filename) ~= 1 then
    return nil
  end
  local memories = vim.fn.readfile(filename)
  return string.format(
    [[Always follow the instructions stored in %s.
Remember that you can edit this file to store user preferences. Before editing always
read the latest version.
```markdown
%s
```]],
    vim.fn.fnamemodify(filename, ":."),
    table.concat(memories, "\n")
  )
end

--- @param global {show_line_numbers: boolean?, include_cursor: boolean?}
--- @return sia.config.UserMessage
function M.buffer(global)
  global = global or {}
  return function(ctx)
    if not vim.api.nvim_buf_is_loaded(ctx.buf) then
      return nil
    end
    local filename = get_filename(ctx.buf, ":p")
    local line_count = vim.api.nvim_buf_line_count(ctx.buf)
    local instruction =
      string.format("Here is %s (lines 1 to %d)", filename, line_count)

    if global.show_line_numbers then
      instruction = instruction .. " as shown by cat -n"
    end

    if global.include_cursor and ctx.cursor then
      local cursor_line, cursor_col = ctx.cursor[1], ctx.cursor[2]
      instruction = instruction
        .. string.format(
          " - cursor is at line %d, column %d",
          cursor_line,
          cursor_col + 1
        )
    end

    local code = require("sia.utils").get_content(
      ctx.buf,
      0,
      line_count,
      { show_line_numbers = global.show_line_numbers, max_line_length = 2000 }
    )

    return string.format("%s\n%s", instruction, table.concat(code, "\n")),
      {
        buf = ctx.buf,
        idempotent = true,
        stale = {
          content = string.format(
            "Previously viewed content from %s - file was modified, read file if needed",
            vim.fn.bufname(ctx.buf)
          ),
        },
      } --[[@as sia.Region]]
  end
end

--- @param global {show_line_numbers: boolean?}?
--- @return sia.config.UserMessage
function M.selection(global)
  global = global or {}
  return function(ctx)
    if not vim.api.nvim_buf_is_loaded(ctx.buf) then
      return nil
    end
    local filename = get_filename(ctx.buf, ":p")
    if ctx.mode == "v" then
      local start_line, end_line = 0, -1
      if ctx.pos then
        start_line, end_line = ctx.pos[1], ctx.pos[2]
      end
      local instruction =
        string.format("Here is %s (lines %d to %d)", filename, start_line, end_line)
      if end_line == -1 then
        start_line = 1
        end_line = vim.api.nvim_buf_line_count(ctx.buf)
        instruction =
          string.format("Here is %s (lines %d to %d)", filename, start_line, end_line)
      end
      local code = require("sia.utils").get_content(
        ctx.buf,
        start_line - 1,
        end_line,
        { show_line_numbers = global.show_line_numbers, max_line_length = 2000 }
      )
      if global.show_line_numbers then
        instruction = instruction .. " as shown by cat -n"
      end

      return string.format("%s\n%s", instruction, table.concat(code, "\n")),
        {
          buf = ctx.buf,
          pos = { start_line, end_line },
          idempotent = true,
          stale = {
            content = string.format(
              "Previously viewed content from %s - file was modified, read file if needed",
              vim.fn.bufname(ctx.buf)
            ),
          },
        } --[[@as sia.Region]]
    else
      return nil
    end
  end
end

--- @return sia.config.UserMessage
function M.verbatim()
  return function(ctx)
    if not vim.api.nvim_buf_is_loaded(ctx.buf) then
      return nil
    end
    local start_line, end_line = 1, -1
    if ctx.pos then
      start_line, end_line = ctx.pos[1], ctx.pos[2]
    end
    return table.concat(
      vim.api.nvim_buf_get_lines(ctx.buf, start_line - 1, end_line, false),
      "\n"
    ),
      {
        buf = ctx.buf,
        pos = { start_line, end_line },
        idempotent = true,
        stale = {
          content = string.format(
            "Previously viewed content from %s - file was modified, read file if needed",
            vim.fn.bufname(ctx.buf)
          ),
        },
      } --[[@as sia.Region]]
  end
end

--- @param invocation sia.Invocation
--- @return sia.Content?
function M.visible_buffers(invocation)
  if invocation.mode ~= "n" then
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
      local relative_name = get_filename(buf, ":.")
      local cursor = vim.api.nvim_win_get_cursor(win)
      local line_count = vim.api.nvim_buf_line_count(buf)
      local is_current = win == current_win

      buffer_info[buf] = {
        relative_name = relative_name,
        hide = vim.bo[buf].buftype ~= "" or relative_name == "",
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
      local position_info = string.format(
        "line %d, col %d (of %d lines)",
        info.cursor_line,
        info.cursor_col,
        info.line_count
      )
      table.insert(
        buffers,
        string.format("- %s: %s%s", info.relative_name, position_info, status)
      )
    end
  end

  if #buffers == 1 then
    return nil
  end

  return table.concat(buffers, "\n")
end

return M
