local M = {}

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
  if args.count == -1 then
    opts.mode = "n"
  else
    opts.mode = "v"
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
--- @field on_select fun(strategy: sia.ChatStrategy):boolean
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
function M.resolve_action(argument, opts)
  local config = require("sia.config")
  local action
  if vim.startswith(argument[1], "/") and vim.bo.ft ~= "sia" then
    action = vim.deepcopy(config.options.actions[argument[1]:sub(2)])
    if action == nil then
      vim.notify("Sia: The action '" .. argument[1] .. "' does not exists.", vim.log.levels.ERROR)
      return nil
    end

    if action.input and action.input == "require" and #argument < 2 then
      vim.notify("Sia: The action '" .. argument[1] .. "' requires input.", vim.log.levels.ERROR)
      return nil
    end

    if #argument > 1 and not (action.input and action.input == "ignore") then
      local tools, prompt = split_tools_and_prompt(argument)
      action.tools = tools
      table.insert(action.instructions, { role = "user", content = table.concat(prompt, " ", 2) })
    end
  else
    local action_mode = M.get_action_mode(opts)
    action = vim.deepcopy(config.options.defaults.actions[action_mode])
    local tools, prompt = split_tools_and_prompt(argument)
    action.tools = tools
    table.insert(action.instructions, { role = "user", content = table.concat(prompt, " ") })
  end

  if action.modify_instructions then
    action.modify_instructions(action.instructions, opts)
  end

  return action
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
      vim.notify("No other buffer")
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
return M
