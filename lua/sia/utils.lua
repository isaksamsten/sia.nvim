local M = {}

--- @type string
local SIA_OUTPUT_DIR =
  vim.fs.joinpath(vim.uv.os_tmpdir() or "/tmp", "sia", tostring(vim.uv.os_getpid()))

--- @type string
local BASH_OUTPUT_DIR = vim.fs.joinpath(SIA_OUTPUT_DIR, "bash")

--- @type string
local FETCH_OUTPUT_DIR = vim.fs.joinpath(SIA_OUTPUT_DIR, "web")

--- @param conversation_id integer
--- @return string
local function get_bash_output_dir(conversation_id)
  return vim.fs.joinpath(BASH_OUTPUT_DIR, tostring(conversation_id))
end

--- @param conversation_id integer
--- @return string
local function get_fetch_output_dir(conversation_id)
  return vim.fs.joinpath(FETCH_OUTPUT_DIR, tostring(conversation_id))
end

--- Check if a file path is under any sia tool output directory.
--- Paths under this directory are trusted and can be read without confirmation.
--- @param path string
--- @return boolean
local function is_tool_output_path(path)
  local resolved = vim.fn.resolve(path)
  local base = vim.fn.resolve(SIA_OUTPUT_DIR)
  return vim.startswith(resolved, base .. "/") or resolved == base
end

M.dirs = {
  bash = get_bash_output_dir,
  fetch = get_fetch_output_dir,
  is_safe = is_tool_output_path,
}

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
  local name = vim.api.nvim_buf_get_name(opts.buf)
  opts.outdated_message = string.format(
    "Previously viewed content from %s - file was modified, read file if needed",
    vim.fn.fnamemodify(name, ":.")
  )

  if args.count == -1 then
    opts.mode = "n"
  else
    opts.mode = "v"
  end
  if
    args.line1 == 1
    and args.line2 == vim.api.nvim_buf_line_count(opts.buf)
    and args.line1 ~= args.line2
  then
    opts.pos = nil
  end
  opts.tick = require("sia.tracker").ensure_tracked(opts.buf, { pos = opts.pos })
  opts.global = true
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

--- @param cmd_line string
--- @return boolean
function M.is_bang_command(cmd_line)
  return cmd_line:match("%S+!") ~= nil
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

--- @class sia.ModeEntry
--- @field name string
--- @field user_input string|nil

--- Parse a @mode prefix from the first word of user input.
--- Only matches if the first non-whitespace word starts with @.
--- @param text string
--- @return string? mode_name
--- @return string rest The text without the @mode prefix
function M.parse_mode_prefix(text)
  local mode = text:match("^@(%w[%w_-]*)%s*")
  if mode then
    local rest = text:sub(#mode + 2):gsub("^%s+", "")
    return mode, rest
  end
  return nil, text
end

--- Resolves a given prompt based on configuration options and context.
--- This function handles both named prompts and ad-hoc prompts, adjusting the behavior
--- based on the current file type and provided options.
---
--- @param argument string[]
--- @param opts sia.ActionContext
--- @return sia.config.Action?
--- @return boolean
--- @return sia.ModeEntry?
function M.resolve_action(argument, opts)
  local config = require("sia.config")
  --- @type sia.config.Action
  local action
  local new_action
  local mode_entry = nil

  if vim.startswith(argument[1], "/") and vim.bo.ft ~= "sia" then
    action = vim.deepcopy(config.options.actions[argument[1]:sub(2)]) --[[@as sia.config.Action]]
    if action == nil then
      vim.api.nvim_echo({
        { "sia: action '" .. argument[1] .. "' does not exist", "ErrorMsg" },
      }, false, {})
      return nil, true
    end

    if action.input and action.input == "require" and #argument < 2 then
      vim.api.nvim_echo({
        {
          "sia: action '" .. argument[1] .. "' requires additional input",
          "ErrorMsg",
        },
      }, false, {})
      return nil, true
    end

    new_action = true
    if
      action.mode == "chat"
      and #argument > 1
      and not (action.input and action.input == "ignore")
    then
      if
        #argument >= 2
        and vim.startswith(argument[2], "@")
        and action.mode == "chat"
      then
        local mode_name = argument[2]:sub(2)
        if mode_name == "default" or (action.modes and action.modes[mode_name]) then
          --- @type sia.ModeEntry
          mode_entry = {
            name = mode_name,
            user_input = #argument >= 3 and table.concat(argument, " ", 3) or nil,
          }
        end
      end

      if not mode_entry then
        table.insert(
          action.instructions,
          { role = "user", content = table.concat(argument, " ", 2) }
        )
      end
    end
  else
    new_action = false
    local action_mode = M.get_action_mode(opts)
    action = vim.deepcopy(config.options.settings.actions[action_mode]) --[[@as sia.config.Action]]

    if
      action.mode == "chat"
      and #argument >= 1
      and vim.startswith(argument[1], "@")
    then
      local mode_name = argument[1]:sub(2)
      if mode_name == "default" or (action.modes and action.modes[mode_name]) then
        mode_entry = {
          name = mode_name,
          user_input = #argument >= 2 and table.concat(argument, " ", 2) or nil,
        }
      end
    end

    if not mode_entry then
      table.insert(
        action.instructions,
        { role = "user", content = table.concat(argument, " ", 1) }
      )
    end
  end

  if action.modify_instructions then
    action.modify_instructions(action.instructions, opts)
  end

  return action, new_action, mode_entry
end

--- @param action sia.config.Action
function M.is_action_disabled(action)
  if
    action.enabled == false
    or (type(action.enabled) == "function" and not action.enabled())
  then
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
--- @param opts {read_only: boolean?, listed:boolean?}?
--- @return integer? buf
function M.ensure_file_is_loaded(file, opts)
  opts = opts or {}
  -- Resolve to an absolute path so that vim.fn.bufnr() performs an exact
  -- match rather than a suffix/fuzzy match.
  -- file = vim.fn.fnamemodify(file, ":p")
  local bufnr = vim.fn.bufnr(file)
  if
    bufnr ~= -1
    and vim.api.nvim_buf_is_valid(bufnr)
    and vim.api.nvim_buf_is_loaded(bufnr)
  then
    if opts.listed then
      vim.bo[bufnr].buflisted = opts.listed
    end
    return bufnr
  end

  local file_exists = vim.uv.fs_stat(file) ~= nil
  bufnr = (bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr)) and bufnr
    or vim.fn.bufadd(file)
  local swap_id = vim.api.nvim_create_autocmd("SwapExists", {
    once = true,
    callback = function()
      if opts.read_only then
        vim.v.swapchoice = "o"
      end
    end,
  })

  pcall(vim.api.nvim_buf_call, bufnr, vim.cmd.edit)
  pcall(vim.api.nvim_del_autocmd, swap_id)
  if file_exists and not vim.api.nvim_buf_is_loaded(bufnr) then
    vim.api.nvim_buf_delete(bufnr, { force = true })
    return nil
  end

  if opts.listed ~= nil then
    vim.bo[bufnr].buflisted = opts.listed
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
    on_nothing = function() end,
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
      table.insert(
        buffers,
        { buf = buf.buf, win = buf.win, name = vim.api.nvim_buf_get_name(buf.buf) }
      )
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
      result = vim
        .system({ "git", "diff", "--cached", "--quiet" }, { text = true })
        :wait()
      return result.code == 1
    else
      return true
    end
  end
  return false
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

local function normalize(p)
  return vim.fn.fnamemodify(p, ":p")
end

--- Detect a project root given a path or buffer
--- @param path_or_buf string|integer
--- @return string root_abs
function M.detect_project_root(path_or_buf)
  local markers = { ".sia" }

  local marker_root
  if type(path_or_buf) == "number" then
    marker_root = vim.fs.root(path_or_buf, markers)
  else
    local path_abs = normalize(path_or_buf or vim.fn.getcwd())
    marker_root = vim.fs.root(path_abs, markers)
  end

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

--- Format memory file name in a human-friendly way
--- @param filename string The full path to the memory file
--- @return string friendly_name Human-readable name
function M.format_memory_name(filename)
  local basename = vim.fs.basename(filename)
  local name = basename:match("^(.+)%.md$") or basename
  name = name:gsub("[_%-%.%+]+", " ")
  name = name:gsub("(%a)([%w_']*)", function(first, rest)
    return first:upper() .. rest:lower()
  end)
  return name
end

M.BANNED_COMMANDS = {
  "open",
  "xdg-open",
  "alias",
  "sudo",
  "su",
  "passwd",
  "dd",
  "mkfs",
  "fdisk",
  "mount",
  "umount",
  "systemctl",
  "service",
  "reboot",
  "shutdown",
  "halt",
  "poweroff",
  "crontab",
  "nohup",
}

function M.is_command_banned(command)
  local cmd_parts = vim.split(command:gsub("^%s+", ""), "%s+")
  local base_cmd = cmd_parts[1]:lower()

  for _, banned in ipairs(M.BANNED_COMMANDS) do
    if base_cmd == banned then
      return true,
        string.format("Command '%s' is not allowed for security reasons", base_cmd)
    end
  end

  return false, "command requires confirmation"
end

--- @param command string
--- @return boolean is_dangerous
function M.detect_dangerous_command_patterns(command)
  local dangerous_patterns = {
    "rm",
    "rmdir",
    "&&",
    "||",
    ";",
    "|",
    "%$%(",
    "`",
    "%$%{",
    "bash %-c",
    "sh %-c",
    "zsh %-c",
    "python %-c",
    "node %-e",
    "perl %-e",
    "eval",
    "exec",
    "source",
    "%<%(",
    "<<",
    "%$[A-Za-z_]",
    "alias ",
    "function ",
    "curl",
    "wget",
    "nc",
    "netcat",
    "\\r",
    "\\m",
    "\\s",
    '"r"',
    "'s'",
    '"s"',
    "'r'",
  }

  for _, pattern in ipairs(dangerous_patterns) do
    if command:find(pattern) then
      return true
    end
  end

  return false
end

--- Create a unified diff with adjusted line numbers for file context
--- @param old_text string The original text
--- @param new_text string The new text
--- @param opts { old_start: integer, new_start: integer, ctxlen: integer? }
--- @return string? unified_diff The adjusted unified diff or nil
function M.create_unified_diff(old_text, new_text, opts)
  local ctxlen = opts.ctxlen or 3

  if not old_text:match("\n$") then
    old_text = old_text .. "\n"
  end
  if not new_text:match("\n$") then
    new_text = new_text .. "\n"
  end

  local unified_diff = vim.diff(old_text, new_text, {
    result_type = "unified",
    ctxlen = ctxlen,
  })

  if not unified_diff or unified_diff == "" then
    return nil
  end

  unified_diff = unified_diff:gsub(
    "@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@",
    function(old_start, old_count, new_start, new_count)
      local old_file_start = opts.old_start + tonumber(old_start) - 1
      local new_file_start = opts.new_start + tonumber(new_start) - 1
      local old_count_str = old_count ~= "" and ("," .. old_count) or ""
      local new_count_str = new_count ~= "" and ("," .. new_count) or ""
      return string.format(
        "@@ -%d%s +%d%s @@",
        old_file_start,
        old_count_str,
        new_file_start,
        new_count_str
      )
    end
  )

  return unified_diff
end

--- Parse simple YAML frontmatter (flat key-value pairs and simple lists).
--- Supports:
---   key: value          → result[key] = "value"
---   key:                → result[key] stays unset until a list item follows
---   - item              → appended to the most recently seen list key
---   bool: true/false    → result[key] = true/false (Lua boolean)
--- @param lines string[]
--- @return table<string, string|string[]|boolean>
function M.parse_yaml_frontmatter(lines)
  local result = {}
  local current_key = nil

  for _, line in ipairs(lines) do
    local list_item = line:match("^%s+-%s+(.+)$")
    if list_item and current_key then
      if type(result[current_key]) ~= "table" then
        result[current_key] = {}
      end
      table.insert(result[current_key], list_item)
    else
      local key, value = line:match("^(%w[%w_]*):%s*(.-)%s*$")
      if key then
        current_key = key
        if value ~= "" then
          if value == "true" then
            result[key] = true
          elseif value == "false" then
            result[key] = false
          else
            result[key] = value
          end
        end
      end
    end
  end

  return result
end

return M
