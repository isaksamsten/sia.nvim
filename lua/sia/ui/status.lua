local M = {}

local icons = require("sia.ui").icons
local format_tokens = require("sia.provider.common").format_token_count
local split = require("sia.ui.split")
local ListModel = require("sia.ui.list").ListModel
local ListView = require("sia.ui.list").ListView

local STATUS_NS = vim.api.nvim_create_namespace("sia_status_ui")
local PREVIEW_TAIL_LINES = 20
local BUSY_INTERVAL = 300
local IDLE_INTERVAL = 1000

--- @param text string?
--- @param n integer
--- @return string[]
local function tail_lines(text, n)
  if not text or text == "" then
    return {}
  end

  local lines = vim.split(text, "\n", { plain = true })
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end

  if #lines <= n then
    return lines
  end

  local result = {}
  for i = #lines - n + 1, #lines do
    table.insert(result, lines[i])
  end
  return result
end

local AGENT_STATUS = {
  running = { hl_group = "SiaStatusActive", icon = icons.started },
  idle = { hl_group = "SiaStatusMuted", icon = "󰁝" },
  pending = { hl_group = "SiaStatusDone", icon = icons.success },
  failed = { hl_group = "SiaStatusFailed", icon = icons.error },
  cancelled = { hl_group = "SiaStatusMuted", icon = icons.error },
}

local BASH_STATUS = {
  running = { hl_group = "SiaStatusActive", icon = icons.started },
  completed = { hl_group = "SiaStatusDone", icon = icons.success },
  failed = { hl_group = "SiaStatusFailed", icon = icons.error },
  timed_out = { hl_group = "SiaStatusFailed", icon = icons.overloaded },
  stopped = { hl_group = "SiaStatusFailed", icon = icons.bash_kill },
}

local panel = split.new()

--- @class sia.status.State
--- @field conversation sia.Conversation
--- @field buf integer
--- @field model sia.ui.ListModel
--- @field list_view sia.ui.ListView

--- @type table<integer, integer>
M._buffers = {}

--- @type table<integer, sia.status.State>
M._states = {}

--- @type uv_timer_t?
local timer = nil

--- @type integer
local timer_interval = 0
local render_scheduled = false

--- @param seconds number
--- @return string
local function format_duration(seconds)
  if seconds < 1 then
    return "<1s"
  elseif seconds < 60 then
    return string.format("%ds", math.floor(seconds))
  elseif seconds < 3600 then
    return string.format("%dm%ds", math.floor(seconds / 60), math.floor(seconds % 60))
  else
    return string.format(
      "%dh%dm",
      math.floor(seconds / 3600),
      math.floor((seconds % 3600) / 60)
    )
  end
end

--- @param command string
--- @return string[]
local function command_lines(command)
  local lines = vim.split(command or "", "\n", { plain = true })
  if #lines == 0 then
    return { "" }
  end
  return lines
end

--- @param proc sia.process.Process
--- @return string stdout
--- @return string stderr
--- @return string? note
local function get_bash_preview_output(proc)
  if proc.status == "running" then
    if not proc.detached_handle then
      return "", "", "Live output is unavailable for synchronous processes."
    end
    local output = proc.detached_handle.get_output()
    return output.stdout or "", output.stderr or "", nil
  end

  return proc:read_stdout(), proc:read_stderr(), nil
end

--- Add stdout/stderr tail blocks to a detail builder.
--- @param d sia.ui.DetailBuilder
--- @param stdout string
--- @param stderr string
--- @param empty_message string
local function add_output_sections(d, stdout, stderr, empty_message)
  local stdout_tail = tail_lines(stdout, PREVIEW_TAIL_LINES)
  local stderr_tail = tail_lines(stderr, PREVIEW_TAIL_LINES)

  if #stdout_tail > 0 then
    d:block(
      string.format(
        "stdout (last %d lines):",
        math.min(#stdout_tail, PREVIEW_TAIL_LINES)
      ),
      stdout_tail
    )
  end

  if #stderr_tail > 0 then
    d:block(
      string.format(
        "stderr (last %d lines):",
        math.min(#stderr_tail, PREVIEW_TAIL_LINES)
      ),
      stderr_tail
    )
  end

  if #stdout_tail == 0 and #stderr_tail == 0 then
    d:line(empty_message, "NonText")
  end
end

--- @param agent sia.agents.Agent
--- @param runtime sia.agents.Runtime
--- @return sia.ui.RenderSpec
local function render_agent(agent, runtime)
  local cfg = AGENT_STATUS[agent.status] or AGENT_STATUS.failed

  local suffix = ""
  if agent.status == "running" and agent.progress and #agent.progress > 0 then
    suffix = "· " .. agent.progress
  end

  suffix = suffix
    .. string.format(
      "(%s tokens)",
      format_tokens(agent.conversation:get_cumulative_usage().total)
    )

  local actions = {}
  if agent.status == "running" then
    actions.cancel = function()
      return runtime:stop(agent.id)
    end
  elseif runtime:can_open(agent.id) then
    actions.open = function()
      return runtime:open(agent.id)
    end
  end

  return {
    icon = cfg.icon,
    label = string.format("[agent] #%d %s", agent.id, agent.name),
    suffix = suffix,
    hl = cfg.hl_group,
    running = agent.status == "running",
    actions = actions,
    details = function(d)
      d:block("Task:", command_lines(agent.task))
      if agent.status == "running" then
        if agent.view == "pending" then
          d:line("Will open as chat on completion.", "DiagnosticInfo")
        end
        if agent.cancellable and agent.cancellable.is_cancelled then
          d:line("Cancellation requested.", "DiagnosticInfo")
        elseif not agent.progress or agent.progress == "" then
          d:line("Waiting for progress update.")
        end
      elseif agent.status == "idle" and agent.view == "open" then
        d:line("Opened as interactive chat.", "DiagnosticInfo")
      elseif agent.status == "pending" then
        d:line("Result is ready to attach.", "DiagnosticInfo")
        local assistant_content = agent.conversation:get_last_assistant_content()
        if assistant_content then
          local preview = vim.trim(assistant_content)
          if #preview > 200 then
            preview = preview:sub(1, 200) .. "…"
          end
          d:detail("Result", preview)
        end
      elseif agent.status == "idle" then
        d:line("Idle.", "NonText")
      elseif agent.status == "cancelled" then
        d:line("Cancelled.", "DiagnosticWarn")
      else
        d:detail("Error", agent.error, "DiagnosticError")
      end
    end,
  }
end

--- @param proc sia.process.Process
--- @param runtime sia.process.Runtime
--- @return sia.ui.RenderSpec
local function render_process(proc, runtime)
  local status_name = BASH_STATUS[proc.status] and proc.status or "failed"
  local cfg = BASH_STATUS[status_name]
  local label = proc.description or proc.command

  local suffix
  if proc.status == "running" then
    suffix =
      string.format("(%s)", format_duration(vim.uv.hrtime() / 1e9 - proc.started_at))
  elseif proc.completed_at and proc.started_at then
    suffix = format_duration(proc.completed_at - proc.started_at)
  end

  if proc.code and proc.code ~= 0 then
    suffix = (suffix or "") .. string.format(" [exit %d]", proc.code)
  end

  local actions = {}
  if proc.status == "running" then
    actions.stop = function()
      return runtime:stop(proc.id)
    end
  end

  return {
    icon = cfg.icon,
    label = string.format("[bash] #%d %s", proc.id, label),
    suffix = suffix,
    hl = cfg.hl_group,
    running = proc.status == "running",
    actions = actions,
    details = function(d)
      d:block("Command:", command_lines(proc.command))

      if proc.status == "running" then
        d:detail(
          "Running for",
          format_duration(vim.uv.hrtime() / 1e9 - proc.started_at)
        )
      else
        d:detail("Status", status_name, cfg.hl_group)
        d:detail(
          "Exit code",
          tostring(proc.code or -1),
          proc.code == 0 and "SiaStatusValue" or "SiaStatusFailed"
        )
        if proc.stdout_file then
          d:detail("stdout file", proc.stdout_file, "SiaStatusPath")
        end
        if proc.stderr_file then
          d:detail("stderr file", proc.stderr_file, "SiaStatusPath")
        end
      end

      local stdout, stderr, note = get_bash_preview_output(proc)
      if note then
        d:line(note)
        return
      end

      add_output_sections(d, stdout, stderr, "No output captured.")
    end,
  }
end

--- @param conversation sia.Conversation
--- @return fun(tag: string, id: any, obj: any): sia.ui.RenderSpec?
local function make_render_entry(conversation)
  return function(tag, _id, obj)
    if tag == "agent" then
      return render_agent(obj, conversation.agent_runtime)
    elseif tag == "bash" then
      return render_process(obj, conversation.process_runtime)
    end
    return nil
  end
end

local sort_newest_first = function(a, b)
  local a_start = a.obj.started_at or 0
  local b_start = b.obj.started_at or 0
  if a_start ~= b_start then
    return a_start > b_start
  end
  if a.tag ~= b.tag then
    return a.tag < b.tag
  end
  return a.id > b.id
end

--- @param buf integer
--- @return integer?
local function conversation_id_from_buf(buf)
  local ok, conv_id = pcall(vim.api.nvim_buf_get_var, buf, "sia_status_conversation_id")
  if ok then
    return conv_id
  end
  return nil
end

--- @param buf integer
--- @return sia.status.State?
local function state_from_buf(buf)
  local conv_id = conversation_id_from_buf(buf)
  if not conv_id then
    return nil
  end
  return M._states[conv_id]
end

--- @param state sia.status.State
local function render_state_buffer(state)
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    return
  end

  local wins = vim.fn.win_findbuf(state.buf)
  local cursors = {}
  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win) then
      cursors[win] = vim.api.nvim_win_get_cursor(win)
    end
  end

  state.list_view:apply(state.buf, STATUS_NS)

  local line_count = math.max(vim.api.nvim_buf_line_count(state.buf), 1)
  for win, cursor in pairs(cursors) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_cursor(win, { math.min(cursor[1], line_count), cursor[2] })
    end
  end
end

M._apply_to_state = render_state_buffer

local function stop_timer()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
    timer_interval = 0
  end
end

local function adjust_interval(interval)
  if not timer or timer_interval == interval then
    return
  end
  timer_interval = interval
  timer:set_repeat(interval)
  timer:again()
end

local function ensure_timer()
  if timer then
    return
  end
  timer = vim.uv.new_timer()
  if timer then
    timer_interval = IDLE_INTERVAL
    timer:start(
      100,
      IDLE_INTERVAL,
      vim.schedule_wrap(function()
        for _, state in pairs(M._states) do
          state.list_view:tick()
        end
        M.schedule_render()
      end)
    )
  end
end

--- Schedule an immediate render pass
function M.schedule_render()
  if render_scheduled then
    return
  end
  render_scheduled = true
  vim.schedule(function()
    render_scheduled = false

    local active_count = 0
    local any_running = false
    local stale = {}

    for conv_id, state in pairs(M._states) do
      if not vim.api.nvim_buf_is_valid(state.buf) then
        table.insert(stale, conv_id)
      elseif vim.fn.bufwinid(state.buf) ~= -1 then
        active_count = active_count + 1
        render_state_buffer(state)
        any_running = any_running or state.list_view.has_running
      end
    end

    for _, conv_id in ipairs(stale) do
      M._states[conv_id] = nil
      M._buffers[conv_id] = nil
    end

    if active_count == 0 then
      stop_timer()
      return
    end

    ensure_timer()
    adjust_interval(any_running and BUSY_INTERVAL or IDLE_INTERVAL)
  end)
end

--- @param conversation sia.Conversation
--- @return sia.status.State
local function ensure_state(conversation)
  local state = M._states[conversation.id]
  if state then
    state.conversation = conversation
    return state
  end

  local model = ListModel.new({
    sources = {
      {
        tag = "agent",
        items = function()
          return conversation.agent_runtime:list()
        end,
        id = function(o)
          return o.id
        end,
      },
      {
        tag = "bash",
        items = function()
          return conversation.process_runtime:list()
        end,
        id = function(o)
          return o.id
        end,
      },
    },
    sort = sort_newest_first,
  })
  state = {
    conversation = conversation,
    buf = -1,
    model = model,
    list_view = ListView.new(model, {
      render = make_render_entry(conversation),
      empty_message = "No agents or processes",
    }),
  }
  M._states[conversation.id] = state
  return state
end

local function close_current_window()
  if vim.api.nvim_win_is_valid(0) then
    vim.api.nvim_win_close(0, true)
  end
  M.schedule_render()
end

--- @param buf integer
local function toggle_current_expand(buf)
  local state = state_from_buf(buf)
  if not state then
    return
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  state.list_view:toggle(line)
  M.schedule_render()
end

--- @param buf integer
local function cancel_current(buf)
  local state = state_from_buf(buf)
  if not state then
    return
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  local tag = state.list_view:item_at(line)
  if not tag then
    return
  end

  if state.list_view:has_action(line, "cancel") then
    state.list_view:trigger(line, "cancel")
  elseif state.list_view:has_action(line, "stop") then
    state.list_view:trigger(line, "stop")
  else
    return
  end

  M.schedule_render()
end

--- @param buf integer
local function open_current(buf)
  local state = state_from_buf(buf)
  if not state then
    return
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  if state.list_view:has_action(line, "open") then
    state.list_view:trigger(line, "open")
    M.schedule_render()
  end
end

--- @param buf integer
--- @param direction 1|-1
local function jump_item(buf, direction)
  local state = state_from_buf(buf)
  if not state then
    return
  end

  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    return
  end

  local current_line = vim.api.nvim_win_get_cursor(win)[1]
  local target_line = state.list_view:find_item(current_line, direction)
  if target_line then
    vim.api.nvim_win_set_cursor(win, { target_line, 0 })
  end
end

--- Get or create the status buffer for a conversation, filled with a snapshot.
--- @param conversation sia.Conversation
--- @return integer buf
local function get_or_create_buf(conversation)
  local state = ensure_state(conversation)
  local buf = M._buffers[conversation.id]
  if buf and vim.api.nvim_buf_is_valid(buf) then
    state.buf = buf
    render_state_buffer(state)
    return buf
  end

  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "sia-status"
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, string.format("*%s status*", conversation.name))
  vim.api.nvim_buf_set_var(buf, "sia_status_conversation_id", conversation.id)

  vim.keymap.set("n", "q", close_current_window, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", close_current_window, { buffer = buf, silent = true })
  vim.keymap.set("n", "<CR>", function()
    toggle_current_expand(buf)
  end, { buffer = buf, silent = true })
  vim.keymap.set("n", "=", function()
    toggle_current_expand(buf)
  end, { buffer = buf, silent = true })
  vim.keymap.set("n", "s", function()
    cancel_current(buf)
  end, { buffer = buf, silent = true })
  vim.keymap.set("n", "n", function()
    jump_item(buf, 1)
  end, { buffer = buf, silent = true })
  vim.keymap.set("n", "p", function()
    jump_item(buf, -1)
  end, { buffer = buf, silent = true })
  vim.keymap.set("n", "r", function()
    M.schedule_render()
  end, { buffer = buf, silent = true })
  vim.keymap.set("n", "e", function()
    open_current(buf)
  end, { buffer = buf, silent = true })

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      M._buffers[conversation.id] = nil
      M._states[conversation.id] = nil
      M.schedule_render()
    end,
  })

  state.buf = buf
  M._buffers[conversation.id] = buf
  render_state_buffer(state)
  return buf
end

--- Open/close/toggle the status panel for the current chat.
--- @param action? "open"|"close"|"toggle"
function M.toggle(action)
  action = action or "toggle"

  local chat = require("sia.strategy").get_chat()
  if not chat then
    return
  end

  if action == "close" then
    panel:close(chat.buf)
    M.schedule_render()
    return
  end

  if action == "toggle" and panel:is_open(chat.buf) then
    panel:close(chat.buf)
    M.schedule_render()
    return
  end

  local buf = get_or_create_buf(chat.conversation)
  panel:open(chat.buf, buf, { size = 15 })
  ensure_timer()
  M.schedule_render()
end

--- Build a model and view from a conversation (exposed for testing).
--- @param conversation sia.Conversation
--- @param opts table?
--- @return sia.ui.ListModel model
--- @return sia.ui.ListView view
function M._build(conversation, opts)
  local model = ListModel.new({
    sources = {
      {
        tag = "agent",
        items = function()
          return conversation.agent_runtime:list()
        end,
        id = function(o)
          return o.id
        end,
      },
      {
        tag = "bash",
        items = function()
          return conversation.process_runtime:list()
        end,
        id = function(o)
          return o.id
        end,
      },
    },
    sort = sort_newest_first,
  })
  local view = ListView.new(
    model,
    vim.tbl_extend("force", {
      render = make_render_entry(conversation),
      empty_message = "No agents or processes",
    }, opts or {})
  )
  return model, view
end

return M
