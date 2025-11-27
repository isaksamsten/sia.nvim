local M = {}
--- @type {buf: integer, win: integer?, timer: uv_timer_t}[]
M._tasks = {}

local TASK_NS = vim.api.nvim_create_namespace("sia_tasks")
local TASK_STATUS = {
  running = { hl_group = "SiaTaskRunning" },
  completed = { hl_group = "SiaTaskCompleted" },
  failed = { hl_group = "SiaTaskFailed" },
}

--- Render task content for a conversation's tasks
--- @param conversation sia.Conversation
--- @return string[] lines, table[] task_info
local function render_tasks(conversation)
  local format_tokens = require("sia.provider.common").format_token_count
  local lines = {}
  local task_info = {} -- Store status for each line

  local running = {}
  local completed = {}

  for _, task in ipairs(conversation.tasks) do
    if task.status == "running" then
      table.insert(running, task)
    else
      table.insert(completed, task)
    end
  end

  table.sort(running, function(a, b)
    return a.id > b.id
  end)
  table.sort(completed, function(a, b)
    return a.id > b.id
  end)

  if #running == 0 and #completed == 0 then
    table.insert(lines, "No tasks")
    table.insert(task_info, { status = nil })
    return lines, task_info
  end

  for _, task in ipairs(running) do
    local progress = task.progress or ""
    if progress ~= "" then
      progress = " " .. progress
    end
    table.insert(lines, string.format("󰦖 %s%s", task.name, progress))
    table.insert(task_info, { status = "running" })
  end

  for _, task in ipairs(completed) do
    local icon = task.status == "completed" and "󰦕" or "󱄊"
    local usage_str = ""
    if task.usage and task.usage.total and task.usage.total > 0 then
      usage_str = string.format(" (%s tokens)", format_tokens(task.usage.total))
    end
    table.insert(lines, string.format("%s %s%s", icon, task.name, usage_str))
    table.insert(task_info, { status = task.status })
  end

  return lines, task_info
end

--- Update task window for a conversation
--- @param conversation sia.Conversation
local function update_task_buffer(conversation)
  local obj = M._tasks[conversation.id]
  if not obj then
    return
  end

  if not obj.win or not vim.api.nvim_win_is_valid(obj.win) then
    return
  end

  if not obj.buf or not vim.api.nvim_buf_is_valid(obj.buf) then
    return
  end

  local lines, task_info = render_tasks(conversation)
  vim.api.nvim_buf_set_lines(obj.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(obj.buf, TASK_NS, 0, -1)

  for i, info in ipairs(task_info) do
    if info.status then
      local hl_group = TASK_STATUS[info.status].hl_group
      vim.api.nvim_buf_set_extmark(obj.buf, TASK_NS, i - 1, 0, {
        hl_group = hl_group,
        hl_mode = "combine",
      })
    end
  end

  local height = math.min(#lines, 15)
  vim.api.nvim_win_set_height(obj.win, height)
end

--- Schedule a debounced update of the task window
--- @param conversation sia.Conversation
local function schedule_update(conversation)
  local cache = M._tasks[conversation.id]
  if not cache then
    return
  end
  if cache.timer then
    cache.timer:stop()
  end

  cache.timer = vim.defer_fn(function()
    update_task_buffer(conversation)
    cache.timer = nil
  end, 100)
end

--- Open/close/toggle task window for current chat
--- @param action? "open"|"close"|"toggle"
function M.task_window(action)
  action = action or "toggle"
  local chat = require("sia.strategy").ChatStrategy.by_buf()
  if not chat then
    return
  end

  local conv_id = chat.conversation.id
  local ex = M._tasks[conv_id]
  local is_open = ex and ex.win and vim.api.nvim_win_is_valid(ex.win)

  if action == "close" then
    if is_open then
      vim.api.nvim_win_close(ex.win, true)
      M._tasks[conv_id] = nil
    end
    return
  end

  if action == "toggle" then
    if is_open then
      vim.api.nvim_win_close(ex.win, true)
      M._tasks[conv_id] = nil
      return
    end
  end

  local task_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[task_buf].filetype = "sia-tasks"
  vim.bo[task_buf].bufhidden = "wipe"

  local lines, task_info = render_tasks(chat.conversation)
  vim.api.nvim_buf_set_lines(task_buf, 0, -1, false, lines)

  -- Apply initial extmarks
  for i, info in ipairs(task_info) do
    if info.status then
      local status = TASK_STATUS[info.status]
      local hl_group = status and status.hl_group or "Normal"
      local line = lines[i]
      if line then
        vim.api.nvim_buf_set_extmark(task_buf, TASK_NS, i - 1, 0, {
          end_col = #line,
          hl_group = hl_group,
          hl_mode = "combine",
        })
      end
    end
  end

  local height = math.min(#lines, 15)
  local win = vim.api.nvim_open_win(task_buf, false, {
    relative = "win",
    width = vim.api.nvim_win_get_width(0) - 1,
    height = height,
    row = 0,
    col = 0,
    style = "minimal",
    border = "none",
    focusable = true,
    zindex = 50,
  })

  vim.wo[win].wrap = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = true

  M._tasks[conv_id] = { win = win, buf = task_buf }

  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout", "BufWinLeave" }, {
    buffer = chat.buf,
    callback = function()
      local tmp = M._tasks[chat.conversation.id]
      if not tmp then
        return
      end

      if tmp.win and vim.api.nvim_win_is_valid(tmp.win) then
        vim.api.nvim_win_close(tmp.win, true)
      end
      if tmp.buf and vim.api.nvim_buf_is_valid(tmp.buf) then
        vim.api.nvim_buf_delete(tmp.buf, { force = true })
      end
      M._tasks[chat.conversation.id] = nil
    end,
  })
end

--- Update task progress and refresh window
--- @param conversation sia.Conversation
function M.update_progress(conversation)
  schedule_update(conversation)
end

return M
