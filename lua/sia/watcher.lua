local M = {}
local SIA_WATCH_NS = vim.api.nvim_create_namespace("SiaWatch")

local ChatStrategy = require("sia.strategy").ChatStrategy
local HiddenStrategy = require("sia.strategy").HiddenStrategy

local Conversation = require("sia.conversation").Conversation
local treesitter_query = require("sia.capture").treesitter({ "@function.outer", "@class.outer" })

--- @type sia.config.Action
local default_action = {
  model = "gpt-4o",
  instructions = {},
  reminder = "editblock_reminder",
  tools = { require("sia.tools").add_file },
}

local default_hl_groups = {
  SiaWatchQuestion = { link = "DiagnosticWarn" },
  SiaWatchCode = { link = "DiagnosticError" },
  SiaWatchContext = { link = "DiagnosticHint" },
}

local hl_groups = setmetatable({
  ["?"] = "SiaWatchQuestion",
  ["!"] = "SiaWatchCode",
}, {
  __index = function()
    return "SiaWatchContext"
  end,
})

--- @alias sia.watcher.Context { autocmd: integer? }
--- @alias sia.watcher.Query {action: "?"|"!"|nil, execute: boolean?, line: string, lnum: integer, lnum_end: integer}
--- Cache variables related to a specific root_dir.
--- @type table<string, { target_buf: integer, augroup: integer, contexts: table<integer, sia.watcher.Context?>, busy: boolean }?>
local root_dir_cache = {}

--- Cache buffer local variables (buffers that we watch)
--- @type table<integer, sia.watcher.Query[]?>
local buf_contexts = {}

local bufs_to_update = {}

--- @type table<integer, {buf: integer, query: sia.watcher.Query}?>
local root_dirs_to_update = {}

local root_dir_process_timer = vim.uv.new_timer()

--- @type uv_timer_t
local buf_update_timer = vim.uv.new_timer()

--- @param buf integer
local redraw_buffer = function(buf)
  vim.api.nvim__buf_redraw_range(buf, 0, -1)
  vim.cmd("redrawstatus")
end

if vim.api.nvim__redraw ~= nil then
  redraw_buffer = function(buf)
    vim.api.nvim__redraw({ buf = buf, valid = true, statusline = true })
  end
end

--- @param buf integer
--- @return string
local function get_buf_real_path(buf)
  return vim.uv.fs_realpath(vim.api.nvim_buf_get_name(buf)) or ""
end

--- @param root_dir string
--- @param opts { buf:integer?, fpath: string? }
local function is_root_dir(root_dir, opts)
  local fpath = opts.fpath
  if opts.buf then
    fpath = get_buf_real_path(opts.buf)
  end

  if not root_dir or not fpath then
    return false
  end
  return vim.startswith(fpath, root_dir)
end

local function set_decoration_provider()
  vim.api.nvim_set_decoration_provider(SIA_WATCH_NS, {
    on_win = function(_, winid, buf, toprow, botrow)
      local contexts = buf_contexts[buf]
      if contexts == nil then
        vim.api.nvim_buf_clear_namespace(buf, SIA_WATCH_NS, toprow, botrow)
        return
      end
      vim.api.nvim_buf_clear_namespace(buf, SIA_WATCH_NS, toprow, botrow)
      for _, context in ipairs(contexts) do
        vim.api.nvim_buf_set_extmark(buf, SIA_WATCH_NS, context.lnum - 1, 0, {
          end_line = context.lnum_end,
          end_col = 0,
          hl_group = hl_groups[context.action],
        })
      end
      -- for i = toprow, botrow do
      --   local context = contexts[i]
      --   if context then
      --     vim.api.nvim_buf_set_extmark(buf, SIA_WATCH_NS, i - 1, 0, {
      --       end_line = i,
      --       end_col = 0,
      --       hl_group = hl_groups[context.action],
      --     })
      --   end
      -- end
    end,
  })
end

--- Get the position range for a given buffer and line number
--- @param buf integer Buffer number
--- @param lnum integer Line number (1-indexed)
--- @return number[] Position array [end_line, start_line] (1-indexed)
local function get_context_position(buf, lnum)
  local pos = treesitter_query({ buf = buf, cursor = { lnum, 1 } })
  if not pos then
    --- Ensure 1-indexed
    pos = {
      math.max(0, lnum - 5) + 1,
      math.min(vim.api.nvim_buf_line_count(buf), lnum + 5) + 1,
    }
  end
  return pos
end

--- @param root_dir string
--- @param opts {buf: integer, query: sia.watcher.Query}
local process_request = vim.schedule_wrap(function(root_dir, opts)
  local cache = root_dir_cache[root_dir]
  if cache == nil or cache.busy then
    return
  end
  cache.busy = true

  local instructions = { "editblock_system" }
  for buf, _ in pairs(cache.contexts) do
    for _, context in ipairs(buf_contexts[buf] or {}) do
      if context.action == nil then
        --- Returns pos 1-indexed
        local pos = get_context_position(buf, context.lnum)
        table.insert(
          instructions,
          require("sia.instructions").context(buf, pos, { mark_lnum = context.lnum, mark = context.line })
        )
        vim.api.nvim_buf_set_lines(buf, context.lnum - 1, context.lnum_end, false, {})
      end
    end
  end

  local pos = get_context_position(opts.buf, opts.query.lnum)
  table.insert(
    instructions,
    require("sia.instructions").context(opts.buf, pos, { mark_lnum = opts.query.lnum, mark = opts.query.line })
  )
  vim.api.nvim_buf_set_lines(opts.buf, opts.query.lnum - 1, opts.query.lnum_end, false, {})

  local conv_action = vim.tbl_deep_extend("force", default_action, { instructions = instructions })
  local conversation = Conversation:new(conv_action, { buf = opts.buf, pos = pos })

  if opts.query.action == "?" then
    conversation:add_instruction("watch_user_question", nil)
  else
    conversation:add_instruction("watch_user_assist", nil)
  end

  --- @type sia.Strategy?
  local strategy
  if opts.query.action == "?" then
    if cache.target_buf ~= nil and vim.api.nvim_buf_is_loaded(cache.target_buf) then
      strategy = ChatStrategy.by_buf(cache.target_buf)
      strategy.conversation = conversation

      local win = vim.fn.bufwinid(cache.target_buf)
      if win == -1 then
        vim.cmd(strategy.options.cmd)
        win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(win, cache.target_buf)
        strategy.canvas:clear()
      end
    else
      strategy = ChatStrategy:new(
        conversation,
        { automatic_block_action = true, block_action = "search_replace_edit", cmd = "chat" }
      )
      cache.target_buf = strategy.buf
    end
  else
    strategy = HiddenStrategy:new(conversation, { callback = require("sia.blocks").replace_blocks_callback })
  end

  if strategy then
    require("sia.assistant").execute_strategy(strategy, {
      on_complete = function()
        cache.busy = false
      end,
    })
  end
end)

local process_requests = vim.schedule_wrap(function()
  for root_dir, opts in pairs(root_dirs_to_update) do
    process_request(root_dir, opts)
  end

  root_dirs_to_update = {}
end)

--- @param root_dir string
--- @param opts {buf: integer, query: sia.watcher.Query}
local schedule_process_request = vim.schedule_wrap(function(root_dir, opts)
  root_dirs_to_update[root_dir] = opts
  root_dir_process_timer:stop()
  root_dir_process_timer:start(1000, 0, process_requests)
end)

--- @param root_dir string
--- @param action "?"|"!"
local deschedule_process_request = vim.schedule_wrap(function(root_dir)
  root_dirs_to_update[root_dir] = nil
end)

local schedule_process_request_on_mode_change = function(root_dir)
  return function(ev)
    local cache = buf_contexts[ev.buf]
    if cache == nil then
      return
    end

    local old_mode = vim.v.event.old_mode
    local new_mode = vim.v.event.new_mode
    if old_mode == "i" and new_mode == "n" then
      local question = nil
      local assist = nil
      for _, context in ipairs(cache) do
        if context.action == "?" and context.execute then
          question = context
        elseif context.action == "!" and context.execute then
          assist = context
        end
      end
      if question then
        schedule_process_request(root_dir, { buf = ev.buf, query = question })
        return
      end
      if assist then
        schedule_process_request(root_dir, { buf = ev.buf, query = assist })
        return
      end
    elseif old_mode == "n" then
      deschedule_process_request(root_dir)
      -- deschedule_process_request(root_dir, "!")
    end
  end
end

local update_watch_buf = vim.schedule_wrap(function(buf, root_dir)
  local cache = root_dir_cache[root_dir]
  if cache == nil then
    return
  end

  local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local old_contexts = buf_contexts[buf] or {}

  --- @type sia.watcher.Query[]
  local contexts = {}

  ---Determines if a line should be processed as a new context
  ---@param line string The line content to check
  ---@param current_line_num number The current line number being examined
  ---@return boolean true if the line should be processed, false otherwise
  ---
  ---Logic:
  --- * If line exists in old contexts:
  ---   * Process if moved up (current_line_num < old_line_num)
  ---   * Ignore if at same position or moved down
  --- * If line is new (not in old contexts), process it
  local function should_trigger_execute(line, current_line_num)
    for _, old_context in ipairs(old_contexts) do
      if old_context.line == line then
        return current_line_num < old_context.lnum
      end
    end
    return true
  end

  for i, line in ipairs(content) do
    local match = line:match("Sia([!?]?)%s*$")
    if match ~= nil then
      -- Only add context if the line is new or has moved up
      local action = match ~= "" and match or nil
      table.insert(contexts, {
        action = action,
        line = line,
        execute = should_trigger_execute(line, i),
        lnum = i,
        lnum_end = i,
      })
    end
  end

  local cache_context = cache.contexts[buf]
  if #contexts > 0 then
    if cache_context == nil then
      --- Setup an autocommand that triggers Sia's analysis when switching modes
      --- When leaving Insert mode ('i') and entering Normal mode ('n'):
      ---   - Schedules a code analysis request for the current root directory
      --- When leaving Normal mode ('n'):
      ---   - Cancels any pending analysis requests for the current root directory
      local autocmd_id = vim.api.nvim_create_autocmd("ModeChanged", {
        buffer = buf,
        callback = schedule_process_request_on_mode_change(root_dir),
      })
      cache.contexts[buf] = { autocmd = autocmd_id }
    end
    buf_contexts[buf] = contexts
  else
    if cache_context then
      pcall(vim.api.nvim_del_autocmd, cache_context.autocmd)
    end
    cache.contexts[buf] = nil
    buf_contexts[buf] = nil
  end
  redraw_buffer(buf)
end)

local process_watch_updates = vim.schedule_wrap(function()
  for buf, root_dir in pairs(bufs_to_update) do
    update_watch_buf(buf, root_dir)
  end
  bufs_to_update = {}
end)

local schedule_watch_update = vim.schedule_wrap(function(buf, root_dir)
  bufs_to_update[buf] = root_dir
  buf_update_timer:stop()
  buf_update_timer:start(200, 0, process_watch_updates)
end)

--- @param root_dir string?
function M.start(root_dir)
  if root_dir == nil then
    root_dir = vim.fs.root(0, { ".git" })
  end

  if root_dir == nil then
    vim.notify("root_dir is required")
    return
  end

  if root_dir_cache[root_dir] then
    vim.notify("Watcher already active for root_dir", vim.log.levels.INFO)
    return
  end

  local track_buffer = vim.schedule_wrap(function(args)
    if not is_root_dir(root_dir, { buf = args.buf }) then
      return
    end

    if not vim.api.nvim_buf_is_valid(args.buf) then
      return
    end

    vim.api.nvim_buf_attach(args.buf, true, {
      on_lines = function()
        if root_dir_cache[root_dir] == nil then
          buf_contexts[args.buf] = nil
          return true
        end
        schedule_watch_update(args.buf, root_dir)
      end,
      on_reload = function(_, bufnr)
        if root_dir_cache[root_dir] == nil then
          buf_contexts[args.buf] = nil
          return
        end
        schedule_watch_update(args.buf, root_dir)
      end,
    })
    schedule_watch_update(args.buf)
  end)

  local augroup = vim.api.nvim_create_augroup("SiaWatcher" .. root_dir, { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = augroup,
    callback = track_buffer,
  })

  vim.api.nvim_create_autocmd("BufDelete", {
    group = augroup,
    callback = function(args)
      local cache = root_dir_cache[root_dir]
      if cache == nil then
        return
      end

      cache.contexts[args.buf] = nil
      buf_contexts[args.buf] = nil
    end,
  })
  root_dir_cache[root_dir] = { buf = 0, augroup = augroup, contexts = {}, busy = false }

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    track_buffer({ buf = buf })
  end
end

--- @param root_dir string
function M.stop(root_dir)
  local cache = root_dir_cache[root_dir]
  if cache == nil then
    return
  end

  pcall(vim.api.nvim_del_augroup_by_id, cache.augroup)
  root_dir_cache[root_dir] = nil
  for buf, _ in pairs(cache.contexts) do
    redraw_buffer(buf)
  end
end

function M.setup()
  -- setup autocommands
  -- setup hl_groups
end

local function set_highlight_groups()
  for group, attr in pairs(default_hl_groups) do
    local existing = vim.api.nvim_get_hl(0, { name = group })
    if vim.tbl_isempty(existing) then
      vim.api.nvim_set_hl(0, group, attr)
    end
  end
end

set_highlight_groups()
set_decoration_provider()
return M
