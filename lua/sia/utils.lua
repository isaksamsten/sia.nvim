local M = {}

--- @param files string[]
--- @param opts {max_count: integer?, max_sort: integer?}?
function M.limit_files(files, opts)
  opts = opts or {}
  local max_count = opts.max_count or 100
  local max_sort = opts.max_sort or 1000
  if #files > max_sort then
    local limited_files = {}
    for i = 1, max_count do
      table.insert(limited_files, files[i])
    end
    return limited_files, #files
  end

  local file_info = {}

  for _, file in ipairs(files) do
    local stat = vim.loop.fs_stat(file)
    if stat then
      table.insert(file_info, {
        path = file,
        mtime = stat.mtime.sec,
      })
    end
  end

  table.sort(file_info, function(a, b)
    return a.mtime > b.mtime
  end)

  local limited_files = {}
  for i = 1, math.min(max_count, #file_info) do
    table.insert(limited_files, file_info[i].path)
  end

  return limited_files, #file_info
end

---Get buffer content for a specific range with optional formatting
---@param buf integer Buffer handle
---@param start_line integer Starting line number (0-based)
---@param end_line integer Ending line number (0-based, -1 for end of buffer)
---@param opts { show_line_numbers: boolean?, max_line_length: integer? }?
---@return string[] formatted_lines Array of lines, optionally with line numbers
function M.get_content(buf, start_line, end_line, opts)
  opts = opts or {}
  local show_line_numbers = opts.show_line_numbers ~= false -- default to true
  local max_line_length = opts.max_line_length

  local content = vim.api.nvim_buf_get_lines(buf, start_line, end_line, false)

  local result = {}
  for i, line in ipairs(content) do
    local processed_line = line
    if max_line_length and #line > max_line_length then
      processed_line = line:sub(1, max_line_length) .. "[TRUNCATED]"
    end

    if show_line_numbers then
      local line_num = start_line + i
      local num_str = tostring(line_num)
      if #num_str >= 6 then
        processed_line = string.format("%s\t%s", num_str, processed_line)
      else
        processed_line = string.format("%6d\t%s", line_num, processed_line)
      end
    end

    table.insert(result, processed_line)
  end

  return result
end

--- @param args vim.api.keyset.create_user_command.command_args
--- @return sia.ActionContext
function M.create_context(args)
  --- @type sia.ActionContext
  local opts = {
    win = vim.api.nvim_get_current_win(),
    buf = vim.api.nvim_get_current_buf(),
    cursor = vim.api.nvim_win_get_cursor(0),
    start_line = args.line1,
    end_line = args.line2,
    pos = { args.line1, args.line2 },
    bang = args.bang,
  }
  opts.tick = require("sia.tracker").ensure_tracked(opts.buf)
  local name = vim.api.nvim_buf_get_name(opts.buf)
  opts.outdated_message = string.format("%s was modified externally", name)

  if args.count == -1 then
    opts.mode = "n"
  else
    opts.mode = "v"
  end
  if args.line1 == 1 and args.line2 == vim.api.nvim_buf_line_count(opts.buf) then
    opts.pos = nil
  end
  return opts
end

function M.is_range_commend(cmd_line)
  local range_patterns = {
    "^%s*%d+", -- Single line number (start), with optional leading spaces
    "^%s*%d+,%d+", -- Line range (start,end), with optional leading spaces
    "^%s*%d+[,+-]%d+", -- Line range with arithmetic (start+1, start-1)
    "^%s*%d+,", -- Line range with open end (start,), with optional leading spaces
    "^%s*%%", -- Whole file range (%), with optional leading spaces
    "^%s*[$.]+", -- $, ., etc., with optional leading spaces
    "^%s*[$.%d]+[%+%-]?%d*", -- Combined offsets (e.g., .+1, $-1)
    "^%s*'[a-zA-Z]", -- Marks ('a, 'b), etc.
    "^%s*[%d$%.']+,[%d$%.']+", -- Mixed patterns (e.g., ., 'a)
    "^%s*['<>][<>]", -- Visual selection marks ('<, '>)
    "^%s*'<[,]'?>", -- Combinations like '<,'>
  }

  for _, pattern in ipairs(range_patterns) do
    if cmd_line:match(pattern) then
      return true
    end
  end
  return false
end
--- @class sia.utils.WithChatStrategy
--- @field on_select fun(strategy: sia.ChatStrategy):nil
--- @field on_none (fun():boolean)?
--- @field only_visible boolean?

--- @param opts sia.utils.WithChatStrategy
function M.with_chat_strategy(opts)
  local ChatStrategy = require("sia.strategy").ChatStrategy
  local chat = ChatStrategy.by_buf()
  if chat then
    opts.on_select(chat)
    return
  end
  --- @type {buf: integer, win: integer? }[]
  local buffers = ChatStrategy.visible()

  if #buffers == 0 and not opts.only_visible then
    buffers = ChatStrategy.all()
  end

  M.select_buffer({
    on_select = function(buffer)
      local strategy = ChatStrategy.by_buf(buffer.buf)
      if strategy then
        opts.on_select(strategy)
      end
    end,
    format_name = function(buf)
      local strategy = ChatStrategy.by_buf(buf.buf)
      if strategy then
        return strategy.name
      end
    end,
    on_nothing = function()
      if opts.on_none then
        opts.on_none()
      end
    end,
    source = buffers,
  })
end
--- Create a new split with markdown content
--- @param content string[] The content to insert in the split
--- @param opts? {cmd: string?, ft: string?} Optional configuration
function M.create_markdown_split(content, opts)
  opts = opts or {}
  local cmd = opts.cmd or "new"
  vim.cmd(cmd)
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
  vim.bo[buf].modifiable = false
  vim.bo[buf].ft = opts.ft or "markdown"
  vim.bo[buf].buflisted = false
  vim.bo[buf].buftype = "nofile"

  return buf
end
--- @type string[]
local global_file_list = {}

--- @param files string[]
function M.add_global_files(files)
  for _, file in ipairs(files) do
    if not vim.tbl_contains(global_file_list, file) then
      table.insert(global_file_list, file)
    end
  end
end

--- Clear the global file list
function M.clear_global_files()
  global_file_list = {}
end

--- @param patterns string[]
function M.remove_global_files(patterns)
  --- @type string[]
  local regexes = {}
  for i, pattern in ipairs(patterns) do
    regexes[i] = vim.fn.glob2regpat(pattern)
  end

  --- @type integer[]
  local to_remove = {}
  for i, file in ipairs(global_file_list) do
    for _, regex in ipairs(regexes) do
      if vim.fn.match(file, regex) ~= -1 then
        table.insert(to_remove, i)
        break
      end
    end
  end

  for i = #to_remove, 1, -1 do
    table.remove(global_file_list, to_remove[i])
  end
end

--- @return string[] files
function M.get_global_files()
  return global_file_list
end

--- @return string[] paths
function M.glob_pattern_to_files(patterns)
  if type(patterns) == "string" then
    patterns = { patterns }
  end

  local files = {}
  for _, pattern in ipairs(patterns) do
    local expanded = vim.fn.glob(pattern, true, true)
    if #expanded > 0 then
      vim.list_extend(files, expanded)
    else
      table.insert(files, pattern)
    end
  end
  return files
end

--- @param words string[]
local function split_tools_and_prompt(words)
  local config = require("sia.config")
  local tools = {}
  local prompt = {}
  for _, word in ipairs(words) do
    if word:sub(1, 1) == "#" then
      local tool = config.options.defaults.tools.choices[word:sub(2)]
      if tool then
        table.insert(tools, word:sub(2))
        table.insert(prompt, word:sub(2))
      else
        table.insert(prompt, word)
      end
    else
      table.insert(prompt, word)
    end
  end
  return tools, prompt
end

--- Resolves a given prompt based on configuration options and context.
--- This function handles both named prompts and ad-hoc prompts, adjusting the behavior
--- based on the current file type and provided options.
---
--- @param argument string[]
--- @param opts sia.ActionContext
--- @return sia.config.Action?
--- @return boolean named prompt
function M.resolve_action(argument, opts)
  local config = require("sia.config")
  local action
  local named
  if vim.startswith(argument[1], "/") and vim.bo.ft ~= "sia" then
    action = vim.deepcopy(config.options.actions[argument[1]:sub(2)])
    if action == nil then
      vim.api.nvim_echo({ { "Sia: The action '" .. argument[1] .. "' does not exist.", "ErrorMsg" } }, false, {})
      return nil, true
    end

    if action.input and action.input == "require" and #argument < 2 then
      vim.api.nvim_echo(
        { { "Sia: The action '" .. argument[1] .. "' requires additional input.", "ErrorMsg" } },
        false,
        {}
      )
      return nil, true
    end

    named = true
    if #argument > 1 and not (action.input and action.input == "ignore") then
      local tools, prompt = split_tools_and_prompt(argument)
      action.tools = tools
      table.insert(action.instructions, { role = "user", content = table.concat(prompt, " ", 2) })
    end
  else
    named = false
    local action_mode = M.get_action_mode(opts)
    action = vim.deepcopy(config.options.defaults.actions[action_mode])
    local tools, prompt = split_tools_and_prompt(argument)
    action.tools = vim.tbl_extend("keep", action.tools or {}, tools)
    table.insert(action.instructions, { role = "user", content = table.concat(prompt, " ") })
  end

  if action.modify_instructions then
    action.modify_instructions(action.instructions, opts)
  end

  return action, named
end

--- @param action sia.config.Action
function M.is_action_disabled(action)
  if action.enabled == false or (type(action.enabled) == "function" and not action.enabled()) then
    return true
  end
  return false
end

--- @param opts sia.ActionContext
--- @return sia.config.ActionMode
function M.get_action_mode(opts)
  if vim.bo[opts.buf].ft == "sia" then
    return "chat"
  end

  if opts.bang and opts.mode == "n" then
    return "insert"
  elseif opts.bang and opts.mode == "v" then
    return "diff"
  else
    return "chat"
  end
end

--- @param file string
--- @return integer? buf
function M.ensure_file_is_loaded(file)
  local bufnr = vim.fn.bufnr(file)
  if bufnr == -1 or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    local status, _ = pcall(function()
      bufnr = vim.fn.bufadd(file)
      vim.fn.bufload(bufnr)
      vim.api.nvim_set_option_value("buflisted", true, { buf = bufnr })
    end)
    if not status then
      return nil
    end
  end

  return bufnr
end

--- @param buf integer
--- @return integer? win
function M.get_window_for_buffer(buf)
  local windows = vim.api.nvim_tabpage_list_wins(0)
  for _, win in ipairs(windows) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
  return nil
end

--- @param buf integer
--- @param query string?
function M.get_filename(buf, query)
  local full_path = vim.api.nvim_buf_get_name(buf)
  return vim.fn.fnamemodify(full_path, query or ":t")
end

--- @param start_line integer
--- @param end_line integer
--- @param opts { buf: integer?, return_table: boolean?, show_line_numbers: boolean? }?
function M.get_code(start_line, end_line, opts)
  opts = opts or {}
  local lines = {}
  if end_line == -1 then
    end_line = vim.api.nvim_buf_line_count(opts.buf or 0)
  end
  local buf = opts.buf or 0
  for line_num = start_line, end_line do
    local line
    if opts.show_line_numbers then
      line = string.format("%d: %s", line_num, vim.fn.getbufoneline(buf, line_num))
    else
      line = string.format("%s", vim.fn.getbufoneline(buf, line_num))
    end
    table.insert(lines, line)
  end

  if opts.return_table == true then
    return lines
  else
    return table.concat(lines, "\n")
  end
end

--- @param start_line integer
--- @param end_line integer?
--- @param opts { buf: integer?, min_severity: vim.diagnostic.Severity }?
function M.get_diagnostics(start_line, end_line, opts)
  if end_line == nil then
    end_line = start_line
  end

  opts = opts or {}
  local buf = opts.buf or vim.api.nvim_get_current_buf()
  local min_severity = opts.min_severity or vim.diagnostic.severity.WARN

  local diagnostics = {}

  for line_num = start_line, end_line do
    local line_diagnostics = vim.diagnostic.get(buf, {
      lnum = line_num - 1,
      severity = { min = min_severity },
    })

    if next(line_diagnostics) ~= nil then
      for _, diagnostic in ipairs(line_diagnostics) do
        table.insert(diagnostics, {
          line_number = line_num,
          message = diagnostic.message,
          severity = vim.diagnostic.severity[diagnostic.severity],
        })
      end
    end
  end

  return diagnostics
end

local ignore_ft = {
  "help",
  "man",
  "git",
  "fugitive",
  "netrw",
  "log",
  "packer",
  "dashboard",
  "TelescopePrompt",
  "NvimTree",
  "vista",
  "terminal",
  "diff",
  "qf",
  "lspinfo",
  "harpoon",
  "outline",
  "sia",
  "neotest-summary",
  "neotest-output-panel",
}

--- @alias sia.utils.BufArgs { buf: integer, win: integer?, name: string }
--- @alias sia.utils.BufOnSelect fun(item: sia.utils.BufArgs, single: boolean?):nil
--- @alias sia.utils.BufFormat fun(item: sia.utils.BufArgs):string?

--- @param current_buf integer
--- @param callback sia.utils.BufOnSelect
function M.select_other_buffer(current_buf, callback)
  M.select_buffer({
    filter = function(buf)
      return buf ~= current_buf
        and vim.api.nvim_buf_is_loaded(buf)
        and not vim.list_contains(ignore_ft, vim.bo[buf].filetype)
    end,
    source = "tab",
    on_select = callback,
    on_nothing = function()
      vim.notify("Sia: No other buffer")
    end,
  })
end

--- @param tab integer
--- @return { buf: integer, win: integer? }
local function get_bufs_tabpage(tab)
  local buffers = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    table.insert(buffers, { buf = vim.api.nvim_win_get_buf(win), win = win })
  end
  return buffers
end

--- @return { buf: integer }
local function get_bufs_all()
  local buffers = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    table.insert(buffers, { buf = buf })
  end
  return buffers
end

--- @param args { filter: (fun(buf:integer):boolean), on_select: sia.utils.BufOnSelect, format_name: sia.utils.BufFormat?, on_nothing: (fun():nil), source:("tab"|"all"|{buf: integer}[])? }
function M.select_buffer(args)
  local buffers = {}
  --- @type {buf: integer, win: integer?}
  local buffer_source = {}
  if args.source == nil or type(args.source) == "string" then
    if args.source == "tab" then
      buffer_source = get_bufs_tabpage(0)
    else
      buffer_source = get_bufs_all()
    end
  else
    local source = args.source
    --- @cast source {buf: integer?}
    buffer_source = source
  end

  for _, buf in ipairs(buffer_source) do
    --- @cast buf { buf: integer, win: integer? }
    if
      args.filter == nil
      or args.filter(buf.buf)
        and not vim.tbl_contains(buffers, function(v)
          return v.buf == buf
        end, { predicate = true })
    then
      table.insert(buffers, { buf = buf.buf, win = buf.win, name = vim.api.nvim_buf_get_name(buf.buf) })
    end
  end
  if #buffers == 0 then
    args.on_nothing()
  elseif #buffers == 1 then
    args.on_select(buffers[1], true)
  else
    vim.ui.select(buffers, {
      format_item = function(item)
        return args.format_name and args.format_name(item) or item.name
      end,
    }, function(choice)
      if choice then
        args.on_select(choice)
      end
    end)
  end
end

function M.is_git_repo(has_staged)
  local handle = io.popen("git rev-parse --is-inside-work-tree 2>/dev/null")
  if handle == nil then
    return false
  end
  local result = handle:read("*a")
  handle:close()
  if result:match("true") then
    if has_staged then
      result = vim.system({ "git", "diff", "--cached", "--quiet" }, { text = true }):wait()
      return result.code == 1
    else
      return true
    end
  end
  return false
end

local BEFORE = 1
local AFTER = 2
local NONE = 3

--- @param content string[]
--- @param opts {before: string, delimiter: string, after: string, find_all: boolean?}?
--- @return { before_tag: string?, after_tag: string?, before: string[]?, after:string[]?, all: {lnum: integer, lnum_end: integer, before:string[], after:string[], before_tag: string?, after_tag: string?}[]? }
function M.partition_marker(content, opts)
  opts = opts or {}

  local before = opts.before or "^<<<<<<?<?<?<?"
  local after = opts.after or "^>>>>>>?>?>?>?>"
  local delimiter = opts.delimiter or "^======?=?=?=?"
  local find_all = opts.find_all or false

  local search = {}
  local replace = {}
  local search_tag = nil
  local all = {}
  local state = NONE
  local lnum = -1
  local match

  for l, line in pairs(content) do
    if state == NONE then
      match = string.match(line, before)
      if match then
        state = BEFORE
        search_tag = match
        lnum = l
      else
        goto continue
      end
    else
      if state == BEFORE then
        if string.match(line, delimiter) then
          state = AFTER
        else
          search[#search + 1] = line
        end
      elseif state == AFTER then
        match = string.match(line, after)
        if match then
          if not find_all then
            return { before_tag = search_tag, after_tag = match, before = search, after = replace }
          else
            all[#all + 1] = {
              before_tag = search_tag,
              after_tag = match,
              lnum = lnum,
              lnum_end = l,
              before = search,
              after = replace,
            }
            search = {}
            replace = {}
            search_tag = nil
            state = NONE
          end
        else
          replace[#replace + 1] = line
        end
      end
    end
    ::continue::
  end

  if #all > 0 then
    return { all = all }
  else
    return { before_tag = search_tag, after_tag = match, before = search, after = replace }
  end
end

function M.urlencode(str)
  if str then
    str = string.gsub(str, "\n", "\r\n")
    str = string.gsub(str, "([^%w _%%%-%.~])", function(c)
      return string.format("%%%02X", string.byte(c))
    end)
    str = string.gsub(str, " ", "+")
  end
  return str
end

-- Root detection helpers
local default_markers = {
  ".git",
  ".hg",
  ".svn",
  "go.mod",
  "Cargo.toml",
  "package.json",
  "pyproject.toml",
  "Pipfile",
  "poetry.lock",
  "requirements.txt",
  "setup.py",
  "Makefile",
  "pom.xml",
  "build.gradle",
  "mix.exs",
}

local function normalize(p)
  return vim.fn.fnamemodify(p, ":p")
end

--- Detect a project root given a path or buffer
--- @param path_or_buf string|integer
--- @param opts { markers: string[]? }?
--- @return string root_abs
function M.detect_project_root(path_or_buf, opts)
  opts = opts or {}
  local markers = opts.markers or default_markers

  local path_abs
  if type(path_or_buf) == "number" then
    local name = vim.api.nvim_buf_get_name(path_or_buf)
    path_abs = normalize(name ~= "" and name or vim.fn.getcwd())
  else
    path_abs = normalize(path_or_buf or vim.fn.getcwd())
  end

  local marker_root = vim.fs.root(path_abs, markers)
  if marker_root then
    return normalize(marker_root)
  end

  return normalize(vim.fn.getcwd(0, 0))
end

--- Check if path is inside root
--- @param path string
--- @param root string
function M.path_in_root(path, root)
  if not path or not root then
    return false
  end
  path = normalize(path)
  root = normalize(root)
  return vim.startswith(path, root)
end

-- Banned commands for security
M.BANNED_COMMANDS = {
  "open",
  "xdg-open",
  "alias",
  "sudo",
  "su",
  "passwd",
  "ssh",
  "scp",
  "rsync",
  "curl",
  "curlie",
  "wget",
  "nc",
  "netcat",
  "dd",
  "mkfs",
  "fdisk",
  "mount",
  "umount",
  "chmod",
  "chown",
  "chgrp",
  "systemctl",
  "service",
  "reboot",
  "shutdown",
  "halt",
  "poweroff",
  "kill",
  "killall",
  "crontab",
  "at",
  "nohup",
  "screen",
  "tmux",
  "bg",
  "fg",
  "jobs",
}

function M.is_command_banned(command)
  local cmd_parts = vim.split(command:gsub("^%s+", ""), "%s+")
  local base_cmd = cmd_parts[1]:lower()

  for _, banned in ipairs(M.BANNED_COMMANDS) do
    if base_cmd == banned then
      return true, string.format("Command '%s' is not allowed for security reasons", base_cmd)
    end
  end

  -- if command:match("%.%.") or command:match("~/") or command:match("^/") then
  --   return true, "Path traversal or absolute paths outside project are not allowed"
  -- end

  return false, "command requires confirmation"
end

--- Command security functions for bash tool
--- @param command string
--- @return boolean is_dangerous
function M.detect_dangerous_command_patterns(command)
  local dangerous_patterns = {
    -- Command chaining/compound commands
    "rm",
    "rmdir",
    "&&",
    "||",
    ";",
    "|",
    -- Command substitution
    "%$%(",
    "`",
    "%$%{",
    -- Indirect execution
    "bash %-c",
    "sh %-c",
    "zsh %-c",
    "python %-c",
    "node %-e",
    "perl %-e",
    -- Built-in bypasses
    "eval",
    "exec",
    "source",
    -- Process substitution
    "%<%(",
    -- Here documents
    "<<",
    -- Variable assignment with execution
    "%$[A-Za-z_]",
    -- Alias/function definition
    "alias ",
    "function ",
    -- Network commands
    "curl",
    "wget",
    "nc",
    "netcat",
    -- Common escape patterns
    "\\r",
    "\\m",
    "\\s",
    -- Quoted command bypasses
    "\"r\"",
    "'s'",
    "\"s\"",
    "'r'",
  }

  for _, pattern in ipairs(dangerous_patterns) do
    if command:find(pattern) then
      return true
    end
  end

  return false
end

return M
