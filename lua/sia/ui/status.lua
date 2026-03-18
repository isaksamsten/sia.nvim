local M = {}

local icons = require("sia.ui").icons
local format_tokens = require("sia.provider.common").format_token_count
local split = require("sia.ui.split")

local STATUS_NS = vim.api.nvim_create_namespace("sia_status_ui")

local SPINNER_FRAMES = { "", "", "", "", "", "" }
local EXPANDED_MARKER = "▾"
local COLLAPSED_MARKER = "▸"
local PREVIEW_TAIL_LINES = 20
local BUSY_INTERVAL = 300
local IDLE_INTERVAL = 1000

local AGENT_STATUS = {
  running = { hl_group = "SiaStatusActive", icon = icons.started },
  completed = { hl_group = "SiaStatusDone", icon = icons.success },
  failed = { hl_group = "SiaStatusFailed", icon = icons.error },
}

local BASH_STATUS = {
  running = { hl_group = "SiaStatusActive", icon = icons.started },
  completed = { hl_group = "SiaStatusDone", icon = icons.success },
  failed = { hl_group = "SiaStatusFailed", icon = icons.error },
  timed_out = { hl_group = "SiaStatusFailed", icon = icons.overloaded },
  stopped = { hl_group = "SiaStatusFailed", icon = icons.bash_kill },
}

local ITEM_TAGS = {
  agent = "[agent]",
  bash = "[bash]",
}

local panel = split.new("status")

--- @class sia.status.State
--- @field conversation sia.Conversation
--- @field buf integer
--- @field expanded table<string, boolean>
--- @field line_meta table<integer, table>
--- @field spinner_frame integer
--- @field has_running boolean

--- @type table<integer, integer>
M._buffers = {}

--- @type table<integer, sia.status.State>
M._states = {}

--- @type uv_timer_t?
local timer = nil
--- @type integer
local timer_interval = 0
local render_scheduled = false

--- @class sia.ui.status.LineInfo
--- @field hl_group string?
--- @field col integer?
--- @field end_col integer?
--- @field line_hl_group string?

--- Format a duration in seconds to a human-readable string
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

--- @param path string?
--- @return string
local function read_output_file(path)
  if not path or vim.fn.filereadable(path) ~= 1 then
    return ""
  end
  return table.concat(vim.fn.readfile(path), "\n")
end

--- @param lines string[]
--- @param line_info sia.ui.status.LineInfo[]
--- @param line_meta table<integer, table>
--- @param text string
--- @param hl sia.ui.status.LineInfo[]?
--- @param meta table?
local function add_line(lines, line_info, line_meta, text, hl, meta)
  table.insert(lines, text)
  table.insert(line_info, hl or {})
  line_meta[#lines] = meta
end

--- @param text string
--- @param pattern string
--- @param hl_group string
--- @return sia.ui.status.LineInfo[]?
local function highlight_match(text, pattern, hl_group)
  local start_col = text:find(pattern, 1, true)
  if not start_col then
    return nil
  end
  return {
    col = start_col - 1,
    end_col = start_col - 1 + #pattern,
    hl_group = hl_group,
  }
end

--- @param lines string[]
--- @param line_info sia.ui.status.LineInfo[]
--- @param line_meta table<integer, table>
--- @param header string
--- @param values string[]
--- @param meta table
local function add_block(lines, line_info, line_meta, header, values, meta)
  if #values == 0 then
    return
  end

  local header_text = "    " .. header
  add_line(lines, line_info, line_meta, header_text, {
    { line_hl_group = "SiaStatusMuted" },
    {
      col = 4,
      end_col = 4 + #header,
      hl_group = "SiaStatusLabel",
    },
  }, meta)
  for _, value in ipairs(values) do
    add_line(lines, line_info, line_meta, "      " .. value, {
      {
        col = 6,
        end_col = 6 + #value,
        hl_group = "SiaStatusCode",
      },
    }, meta)
  end
end

--- @param lines string[]
--- @param line_info sia.ui.status.LineInfo[]
--- @param line_meta table<integer, table>
--- @param label string
--- @param value string?
--- @param meta table
--- @param hl_group string?
local function add_detail_value(
  lines,
  line_info,
  line_meta,
  label,
  value,
  meta,
  hl_group
)
  if not value or value == "" then
    return
  end
  local line = string.format("    %s: %s", label, value)
  local label_end = 4 + #label + 1
  local value_start = label_end + 1
  add_line(lines, line_info, line_meta, line, {
    { line_hl_group = "SiaStatusMuted" },
    {
      col = 4,
      end_col = label_end,
      hl_group = "SiaStatusLabel",
    },
    {
      col = value_start,
      end_col = value_start + #value,
      hl_group = hl_group or "SiaStatusValue",
    },
  }, meta)
end

--- @param kind "agent"|"bash"
--- @return string
local function item_tag(kind)
  return ITEM_TAGS[kind] or ("[" .. kind .. "]")
end

--- @param proc sia.conversation.BashProcess
--- @return string
--- @return { hl_group: string, icon: string }
local function resolve_bash_status(proc)
  if BASH_STATUS[proc.status] then
    return proc.status, BASH_STATUS[proc.status]
  end
  return "failed", BASH_STATUS.failed
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

--- @param proc sia.conversation.BashProcess
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

  return read_output_file(proc.stdout_file), read_output_file(proc.stderr_file), nil
end

--- @param lines string[]
--- @param line_info sia.ui.status.LineInfo[]
--- @param line_meta table<integer, table>
--- @param stdout string
--- @param stderr string
--- @param meta table
--- @param empty_message string
local function add_output_sections(
  lines,
  line_info,
  line_meta,
  stdout,
  stderr,
  meta,
  empty_message
)
  local stdout_tail = tail_lines(stdout, PREVIEW_TAIL_LINES)
  local stderr_tail = tail_lines(stderr, PREVIEW_TAIL_LINES)

  if #stdout_tail > 0 then
    add_block(
      lines,
      line_info,
      line_meta,
      string.format(
        "stdout (last %d lines):",
        math.min(#stdout_tail, PREVIEW_TAIL_LINES)
      ),
      stdout_tail,
      meta
    )
  end

  if #stderr_tail > 0 then
    add_block(
      lines,
      line_info,
      line_meta,
      string.format(
        "stderr (last %d lines):",
        math.min(#stderr_tail, PREVIEW_TAIL_LINES)
      ),
      stderr_tail,
      meta
    )
  end

  if #stdout_tail == 0 and #stderr_tail == 0 then
    add_line(
      lines,
      line_info,
      line_meta,
      "    " .. empty_message,
      { { line_hl_group = "NonText" } },
      meta
    )
  end
end

--- @param agent sia.conversation.Agent
--- @param state { expanded: table<string, boolean>, spinner_frame: integer, has_running: boolean }
--- @param lines string[]
--- @param line_info sia.ui.status.LineInfo[]
--- @param line_meta table<integer, table>
local function render_agent(agent, state, lines, line_info, line_meta)
  local status = agent.status == "completed" and "completed" or agent.status
  local cfg = AGENT_STATUS[status] or AGENT_STATUS.failed
  local item_key = string.format("agent:%d", agent.id)
  local expanded = state.expanded[item_key] == true
  local icon = agent.status == "running" and SPINNER_FRAMES[state.spinner_frame]
    or cfg.icon
  local marker = expanded and EXPANDED_MARKER or COLLAPSED_MARKER
  local suffix = ""

  if agent.status == "running" then
    if agent.progress and #agent.progress > 0 then
      suffix = " · " .. agent.progress
    end
  elseif agent.usage and agent.usage.total and agent.usage.total > 0 then
    suffix = string.format(" (%s tokens)", format_tokens(agent.usage.total))
  end

  local meta = {
    kind = "agent",
    id = agent.id,
    item_key = item_key,
    action = agent.status == "running" and "cancel" or nil,
  }
  local summary_meta = vim.tbl_extend("force", {}, meta, { summary = true })

  add_line(
    lines,
    line_info,
    line_meta,
    (
      string.format(
        "  %s %s %s #%d %s%s",
        marker,
        icon,
        item_tag("agent"),
        agent.id,
        agent.name,
        suffix
      )
    ),
    (function()
      local line = string.format(
        "  %s %s %s #%d %s%s",
        marker,
        icon,
        item_tag("agent"),
        agent.id,
        agent.name,
        suffix
      )
      local highlights = {
        { line_hl_group = cfg.hl_group },
        { col = 2, end_col = 2 + #marker, hl_group = "SiaStatusMuted" },
      }
      local tag_hl = highlight_match(line, item_tag("agent"), "SiaStatusTag")
      if tag_hl then
        table.insert(highlights, tag_hl)
      end
      local id_hl = highlight_match(line, "#" .. agent.id, "SiaStatusLabel")
      if id_hl then
        table.insert(highlights, id_hl)
      end
      return highlights
    end)(),
    summary_meta
  )

  if agent.status == "running" then
    state.has_running = true
  end

  if not expanded then
    return
  end

  add_block(lines, line_info, line_meta, "Task:", command_lines(agent.task), meta)

  if agent.status == "running" then
    if agent.cancellable and agent.cancellable.is_cancelled then
      add_line(lines, line_info, line_meta, "    Cancellation requested.", {
        { line_hl_group = "DiagnosticInfo" },
        {
          col = 4,
          end_col = 4 + #"Cancellation requested.",
          hl_group = "DiagnosticInfo",
        },
      }, meta)
    elseif not agent.progress or agent.progress == "" then
      add_line(lines, line_info, line_meta, "    Waiting for progress update.", {
        { line_hl_group = "SiaStatusMuted" },
        {
          col = 4,
          end_col = 4 + #"Waiting for progress update.",
          hl_group = "SiaStatusMuted",
        },
      }, meta)
    end
    return
  end

  if agent.status == "completed" then
    if agent.result and #agent.result > 0 then
      add_block(lines, line_info, line_meta, "Output:", agent.result, meta)
    else
      add_line(lines, line_info, line_meta, "    No output returned.", {
        { line_hl_group = "SiaStatusMuted" },
        {
          col = 4,
          end_col = 4 + #"No output returned.",
          hl_group = "SiaStatusMuted",
        },
      }, meta)
    end
    return
  end

  add_detail_value(
    lines,
    line_info,
    line_meta,
    "Error",
    agent.error or "Unknown error",
    meta,
    "DiagnosticError"
  )
  if agent.result and #agent.result > 0 then
    add_block(lines, line_info, line_meta, "Output:", agent.result, meta)
  end
end

--- @param proc sia.conversation.BashProcess
--- @param state { expanded: table<string, boolean>, spinner_frame: integer, has_running: boolean }
--- @param lines string[]
--- @param line_info sia.ui.status.LineInfo[]
--- @param line_meta table<integer, table>
local function render_process(proc, state, lines, line_info, line_meta)
  local status_name, cfg = resolve_bash_status(proc)
  local item_key = string.format("bash:%d", proc.id)
  local expanded = state.expanded[item_key] == true
  local marker = expanded and EXPANDED_MARKER or COLLAPSED_MARKER
  local icon = proc.status == "running" and SPINNER_FRAMES[state.spinner_frame]
    or cfg.icon
  local label = proc.description or proc.command
  local suffix = ""

  if proc.status == "running" then
    suffix =
      string.format(" (%s)", format_duration(vim.uv.hrtime() / 1e9 - proc.started_at))
    state.has_running = true
  elseif proc.completed_at and proc.started_at then
    suffix = " " .. format_duration(proc.completed_at - proc.started_at)
  end

  if proc.code and proc.code ~= 0 then
    suffix = suffix .. string.format(" [exit %d]", proc.code)
  end

  local meta = {
    kind = "bash",
    id = proc.id,
    item_key = item_key,
    action = proc.status == "running" and "stop" or nil,
  }
  local summary_meta = vim.tbl_extend("force", {}, meta, { summary = true })

  add_line(
    lines,
    line_info,
    line_meta,
    (
      string.format(
        "  %s %s %s #%d %s%s",
        marker,
        icon,
        item_tag("bash"),
        proc.id,
        label,
        suffix
      )
    ),
    (function()
      local line = string.format(
        "  %s %s %s #%d %s%s",
        marker,
        icon,
        item_tag("bash"),
        proc.id,
        label,
        suffix
      )
      local highlights = {
        { line_hl_group = cfg.hl_group },
        { col = 2, end_col = 2 + #marker, hl_group = "SiaStatusMuted" },
      }
      local tag_hl = highlight_match(line, item_tag("bash"), "SiaStatusTag")
      if tag_hl then
        table.insert(highlights, tag_hl)
      end
      local id_hl = highlight_match(line, "#" .. proc.id, "SiaStatusLabel")
      if id_hl then
        table.insert(highlights, id_hl)
      end
      return highlights
    end)(),
    summary_meta
  )

  if not expanded then
    return
  end

  add_block(lines, line_info, line_meta, "Command:", command_lines(proc.command), meta)

  if proc.status == "running" then
    add_detail_value(
      lines,
      line_info,
      line_meta,
      "Running for",
      format_duration(vim.uv.hrtime() / 1e9 - proc.started_at),
      meta,
      "SiaStatusValue"
    )
  else
    add_detail_value(
      lines,
      line_info,
      line_meta,
      "Status",
      status_name,
      meta,
      cfg.hl_group
    )
    add_detail_value(
      lines,
      line_info,
      line_meta,
      "Exit code",
      tostring(proc.code or -1),
      meta,
      proc.code == 0 and "SiaStatusValue" or "SiaStatusFailed"
    )
    if proc.stdout_file then
      add_detail_value(
        lines,
        line_info,
        line_meta,
        "stdout file",
        proc.stdout_file,
        meta,
        "SiaStatusPath"
      )
    end
    if proc.stderr_file then
      add_detail_value(
        lines,
        line_info,
        line_meta,
        "stderr file",
        proc.stderr_file,
        meta,
        "SiaStatusPath"
      )
    end
  end

  local stdout, stderr, note = get_bash_preview_output(proc)
  if note then
    add_line(lines, line_info, line_meta, "    " .. note, {
      { line_hl_group = "SiaStatusMuted" },
      {
        col = 4,
        end_col = 4 + #note,
        hl_group = "SiaStatusMuted",
      },
    }, meta)
    return
  end

  add_output_sections(
    lines,
    line_info,
    line_meta,
    stdout,
    stderr,
    meta,
    "No output captured."
  )
end

--- Render agents and bash processes into lines + highlight info
--- @param conversation sia.Conversation
--- @param state { expanded: table<string, boolean>, spinner_frame: integer}
--- @return string[] lines, sia.ui.status.LineInfo[] line_info, table<integer, table> line_meta, boolean has_running
local function render_snapshot(conversation, state)
  local lines = {}
  local line_info = {}
  local line_meta = {}
  --- @type { expanded: table<string, boolean>, spinner_frame: integer, has_running: boolean }
  local render_state = {
    expanded = state.expanded or {},
    spinner_frame = state.spinner_frame or 1,
    has_running = false,
  }

  local items = {}
  for _, agent in ipairs(conversation.agents or {}) do
    table.insert(items, {
      kind = "agent",
      id = agent.id,
      started_at = agent.started_at or 0,
      item = agent,
    })
  end
  for _, proc in ipairs(conversation.bash_processes or {}) do
    table.insert(items, {
      kind = "bash",
      id = proc.id,
      started_at = proc.started_at or 0,
      item = proc,
    })
  end

  table.sort(items, function(a, b)
    if a.started_at ~= b.started_at then
      return a.started_at > b.started_at
    end
    if a.kind ~= b.kind then
      return a.kind < b.kind
    end
    return a.id > b.id
  end)

  for _, entry in ipairs(items) do
    if entry.kind == "agent" then
      render_agent(entry.item, render_state, lines, line_info, line_meta)
    else
      render_process(entry.item, render_state, lines, line_info, line_meta)
    end
  end

  if #lines == 0 then
    return { "No agents or processes" },
      {
        {
          { line_hl_group = "SiaStatusMuted" },
          {
            col = 0,
            end_col = #"No agents or processes",
            hl_group = "SiaStatusMuted",
          },
        },
      },
      {},
      false
  end

  return lines, line_info, line_meta, render_state.has_running
end

--- Apply line highlights to the buffer
--- @param buf integer
--- @param line_info table<integer, sia.ui.status.LineInfo[]?>
local function apply_highlights(buf, line_info)
  vim.api.nvim_buf_clear_namespace(buf, STATUS_NS, 0, -1)
  for i, infos in ipairs(line_info) do
    for _, info in ipairs(infos or {}) do
      if info.hl_group then
        vim.api.nvim_buf_set_extmark(buf, STATUS_NS, i - 1, info.col or 0, {
          hl_group = info.hl_group,
          end_col = info.end_col or 0,
        })
      elseif info.line_hl_group then
        vim.api.nvim_buf_set_extmark(buf, STATUS_NS, i - 1, 0, {
          line_hl_group = info.line_hl_group,
        })
      end
    end
  end
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

--- @param buf integer
--- @return table?
local function current_item_meta(buf)
  local state = state_from_buf(buf)
  if not state then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  return state.line_meta[line]
end

--- @param state sia.status.State
--- @param current_line integer
--- @param direction 1|-1
--- @return integer?
local function find_item_line(state, current_line, direction)
  local line_count = vim.api.nvim_buf_line_count(state.buf)
  local current_meta = state.line_meta[current_line]
  local current_key = current_meta and current_meta.item_key or nil

  local line = current_line + direction
  while line >= 1 and line <= line_count do
    local meta = state.line_meta[line]
    if meta and meta.summary and meta.item_key ~= current_key then
      return line
    end
    line = line + direction
  end

  return nil
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
  local target_line = find_item_line(state, current_line, direction)
  if target_line then
    vim.api.nvim_win_set_cursor(win, { target_line, 0 })
  end
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

  local lines, line_info, line_meta, has_running = render_snapshot(state.conversation, {
    expanded = state.expanded,
    spinner_frame = state.spinner_frame,
  })

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  apply_highlights(state.buf, line_info)

  state.line_meta = line_meta
  state.has_running = has_running

  local line_count = math.max(vim.api.nvim_buf_line_count(state.buf), 1)
  for win, cursor in pairs(cursors) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_cursor(win, { math.min(cursor[1], line_count), cursor[2] })
    end
  end
end

M._apply_to_state = render_state_buffer
M._find_item_line = find_item_line

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
          if state.has_running then
            state.spinner_frame = (state.spinner_frame % #SPINNER_FRAMES) + 1
          else
            state.spinner_frame = 1
          end
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
        any_running = any_running or state.has_running
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

  state = {
    conversation = conversation,
    buf = -1,
    expanded = {},
    line_meta = {},
    spinner_frame = 1,
    has_running = false,
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

  local meta = current_item_meta(buf)
  if not meta or not meta.item_key then
    return
  end

  state.expanded[meta.item_key] = not state.expanded[meta.item_key]
  M.schedule_render()
end

--- @param conversation sia.Conversation
--- @param meta table
function M._run_action(conversation, meta)
  if meta.kind == "agent" then
    local agent = conversation:get_agent(meta.id)
    if not agent then
      return
    end
    agent:cancel()
  elseif meta.kind == "bash" then
    local proc = conversation:get_bash_process(meta.id)
    if not proc then
      return
    end
    proc:stop()
  end
end

--- @param buf integer
local function cancel_current(buf)
  local state = state_from_buf(buf)
  if not state then
    return
  end

  local meta = current_item_meta(buf)
  if not meta or not meta.action then
    vim.notify(
      "Only running agents and processes can be cancelled here.",
      vim.log.levels.INFO
    )
    return
  end

  M._run_action(state.conversation, meta)
  M.schedule_render()
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

M._render_snapshot = render_snapshot

return M
