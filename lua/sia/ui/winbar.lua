local M = {}
local common = require("sia.provider.common")

local ICONS = {
  bash = " ",
  agents = " ",
  tool = " ",
  queue = " ",
  total_tokens = "󰝪 ",
  price = " ",
  context = " ",
}

local SPINNER_FRAMES = { "", "", "", "", "", "" }

local STATUS_PREFIX = {
  error = " ",
  warning = " ",
  info = " ",
}

local STATUS_HL = {
  error = "DiagnosticError",
  warning = "DiagnosticWarn",
  info = "DiagnosticInfo",
}

local SECTION_SEPARATOR = "%#NonText# · "

--- @param items string[]
--- @param max_visible integer
--- @param extra_count integer
--- @return string
local function compact_list(items, max_visible, extra_count)
  if #items == 0 and extra_count <= 0 then
    return ""
  end

  local visible = vim.list_slice(items, 1, max_visible)
  local hidden = math.max(#items - #visible, 0) + extra_count
  local text = table.concat(visible, ", ")
  if hidden > 0 then
    text = text == "" and ("+" .. hidden) or (text .. " +" .. hidden)
  end
  return text
end

--- @param hl string
--- @param text string
--- @return string
local function section(hl, text)
  return "%#" .. hl .. "#" .. text
end

--- @param text string
--- @param max_len integer
--- @return string
local function truncate_middle(text, max_len)
  if #text <= max_len then
    return text
  end
  if max_len <= 1 then
    return "…"
  end
  return text:sub(1, max_len - 1) .. "…"
end

--- @param status sia.WinbarStatus
--- @return string
local function status_section(status)
  local hl = status.status and STATUS_HL[status.status] or "NonText"
  local prefix = status.status and STATUS_PREFIX[status.status] or ""
  local message = truncate_middle(vim.trim(status.message or ""), 64)
  return section(hl, prefix .. message)
end

--- @param data sia.WinbarData
--- @return string
local function tool_section(data)
  if not data.tool_status then
    return ""
  end

  local running_names = {}
  local pending_count = 0
  for _, ts in ipairs(data.tool_status) do
    if ts.status == "running" then
      table.insert(running_names, ts.name or "tool")
    elseif ts.status == "pending" then
      pending_count = pending_count + 1
    end
  end

  local label = compact_list(running_names, 1, pending_count)
  if label == "" then
    return ""
  end

  return section("SiaTaskRunning", string.format("%s%s", ICONS.tool, label))
end

--- @param conversation sia.Conversation
--- @return string
local function agents_section(conversation)
  if not conversation:has_tool("agent") then
    return ""
  end

  local running = {}
  for _, agent in ipairs(conversation.agents) do
    if agent.status == "running" then
      table.insert(running, agent)
    end
  end

  if #running == 0 then
    return ""
  end

  local label
  if #running == 1 then
    local a = running[1]
    label = a.name
    if a.progress and #a.progress > 0 then
      label = label .. " " .. truncate_middle(a.progress, 20)
    end
  else
    label = tostring(#running)
  end

  return section("SiaTaskRunning", string.format("%s%s", ICONS.agents, label))
end

--- @param conversation sia.Conversation
--- @return string
local function bash_section(conversation)
  if not conversation:has_tool("bash") then
    return ""
  end

  local running = {}
  for _, proc in ipairs(conversation.bash_processes) do
    if proc.status == "running" then
      table.insert(running, proc)
    end
  end

  if #running == 0 then
    return ""
  end

  local label
  if #running == 1 then
    local desc = running[1].description or running[1].command
    label = truncate_middle(desc, 20)
  else
    label = tostring(#running)
  end

  return section("SiaTaskRunning", string.format("%s%s", ICONS.bash, label))
end

--- @param data sia.WinbarData
--- @return string
local function queue_section(data)
  local size = #data.strategy.queue
  if size <= 0 then
    return ""
  end
  return section("NonText", string.format("%s%d", ICONS.queue, size))
end

--- @param data sia.WinbarData
--- @return string
local function spinner_section(data)
  if not data.strategy.is_busy then
    return ""
  end
  return section("SiaTaskRunning", data.spinner)
end

--- Render a visual bar from a percentage (0..1).
--- @param percent number 0..1
--- @param width integer number of bar segments (default 5)
--- @return string
local function render_bar(percent, width)
  width = width or 5
  local filled = math.min(width, math.floor(percent * width + 0.5))
  local empty = width - filled
  return string.rep("▰", filled) .. string.rep("▱", empty)
end

--- @param data sia.WinbarData
--- @return string
local function context_budget_section(data)
  local budget = data.context_budget
  if not budget then
    return ""
  end

  local visual = render_bar(math.min(budget.percent, 1.0), 6)
  local hl = "NonText"
  if budget.percent >= 0.95 then
    hl = "DiagnosticError"
  elseif budget.percent >= 0.85 then
    hl = "DiagnosticWarn"
  end
  local limit_str = common.format_token_count(budget.limit)
  local estimate_str = common.format_token_count(budget.estimated)
  return section(
    hl,
    string.format("%s%s %s %s", ICONS.context, estimate_str, visual, limit_str)
  )
end

--- @param data sia.WinbarData
--- @return string
local function format_right_metric(data)
  local stats = data.stats
  local parts = {}

  parts[1] = section(
    "NonText",
    ICONS.total_tokens .. common.format_token_count(data.total_usage)
  )

  if stats and stats.cost then
    local cost_str
    if stats.cost >= 1.0 then
      cost_str = string.format("$%.2f", stats.cost)
    else
      cost_str = string.format("$%.3f", stats.cost)
    end
    table.insert(parts, section("NonText", ICONS.price .. cost_str))
  elseif stats and stats.quota then
    local pct = math.floor(stats.quota.percent * 100 + 0.5)
    local label = pct .. "%%"
    if stats.quota.label then
      label = label .. " " .. stats.quota.label
    end
    table.insert(parts, section("NonText", ICONS.price .. label))
  end

  local budget_part = context_budget_section(data)
  if budget_part ~= "" then
    table.insert(parts, budget_part)
  end

  if #parts > 0 then
    return table.concat(parts, section("NonText", " · "))
  end

  return ""
end

local function format_left(parts)
  if #parts == 0 then
    return ""
  end
  return table.concat(parts, SECTION_SEPARATOR) .. "%#NonText#"
end

local function push_part(parts, value)
  if value ~= "" then
    table.insert(parts, value)
  end
end

--- @param conversation sia.Conversation
--- @return string
local function mode_section(conversation)
  if not conversation.active_mode then
    return ""
  end
  return section("SiaMode", " " .. conversation.active_mode.name)
end

--- @param conversation sia.Conversation
--- @return string
local function id_section(conversation)
  local parent = conversation.parent
  if parent then
    return section(
      "DiagnosticInfo",
      "#" .. conversation.id .. "↑" .. parent.conversation.id
    )
  end
  return section("NonText", "#" .. conversation.id)
end

local function default_left_sections(data)
  local parts = {}
  push_part(parts, spinner_section(data))
  push_part(parts, id_section(data.conversation))
  push_part(parts, mode_section(data.conversation))
  push_part(parts, queue_section(data))
  push_part(parts, tool_section(data))
  push_part(parts, agents_section(data.conversation))
  push_part(parts, bash_section(data.conversation))
  return format_left(parts)
end

local function default_center_status(data)
  if not data.status then
    return ""
  end
  return status_section(data.status)
end

local function default_right_metric(data)
  return format_right_metric(data)
end

--- @class sia.WinbarToolStatus
--- @field name string?
--- @field message string?
--- @field status "pending"|"running"|"done"

--- @class sia.WinbarStatus
--- @field message string
--- @field status "warning"|"error"|"info"|nil

--- @class sia.WinbarData
--- @field conversation sia.Conversation
--- @field strategy sia.ChatStrategy
--- @field stats sia.conversation.Stats?
--- @field tool_status sia.WinbarToolStatus[]?
--- @field status sia.WinbarStatus?
--- @field context_budget { estimated: integer, limit: integer, percent: number }?
--- @field total_usage integer
--- @field spinner string?
--- @field win integer
--- @field buf integer

--- Default left section: shows activity in structured segments
--- @param data sia.WinbarData
--- @return string
function M.default_left(data)
  if not data.conversation then
    return ""
  end
  return default_left_sections(data)
end

--- Default center section: status (with severity) or cost tracking bar
--- @param data sia.WinbarData
--- @return string
function M.default_center(data)
  local status = default_center_status(data)
  return status
end

--- Default right section: labels usage metric
--- @param data sia.WinbarData
--- @return string
function M.default_right(data)
  return default_right_metric(data)
end

--- @class sia.WinbarEntry
--- @field conversation sia.Conversation
--- @field strategy sia.ChatStrategy
--- @field stats sia.conversation.Stats?
--- @field stats_pending boolean
--- @field last_usage_total integer
--- @field tool_status sia.WinbarToolStatus[]?
--- @field status sia.WinbarStatus?
--- @field context_budget { estimated: integer, limit: integer, percent: number }?
--- @field spinner_frame integer

--- @type table<integer, sia.WinbarEntry>
local entries = {}

local BUSY_INTERVAL = 300
local IDLE_INTERVAL = 5000

--- @type uv_timer_t?
local timer = nil
--- Current timer repeat interval (to detect when it needs changing)
--- @type integer
local timer_interval = 0
--- Whether a render is already scheduled for this event loop iteration
local render_scheduled = false

--- Render the winbar for a single buffer entry
--- @param buf integer
--- @param entry sia.WinbarEntry
local function render_one(buf, entry)
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    return
  end

  local config = require("sia.config")
  local winbar_config = config.options.settings.chat.winbar
  if not winbar_config then
    return
  end

  --- @type sia.WinbarData
  local data = {
    conversation = entry.conversation,
    strategy = entry.strategy,
    stats = entry.stats,
    status = entry.status,
    tool_status = entry.tool_status,
    context_budget = entry.context_budget,
    total_usage = entry.last_usage_total,
    spinner = SPINNER_FRAMES[entry.spinner_frame],
    win = win,
    buf = buf,
  }

  local left = winbar_config.left and winbar_config.left(data) or ""
  local center = winbar_config.center and winbar_config.center(data) or ""
  local right = winbar_config.right and winbar_config.right(data) or ""

  local new_winbar =
    string.format("%%#Normal#%s%%=%s%%#Normal#%%=%s%%#Normal#", left, center, right)
  if new_winbar ~= vim.wo[win].winbar then
    vim.wo[win].winbar = new_winbar
  end
end

--- Refresh stats from provider if usage changed
--- @param buf integer
--- @param entry sia.WinbarEntry
local function maybe_refresh_stats(buf, entry)
  local usage = entry.conversation:get_cumulative_usage()
  local usage_total = usage and usage.total or 0
  if usage_total == entry.last_usage_total or entry.stats_pending then
    return
  end

  entry.last_usage_total = usage_total
  local model = entry.conversation.model
  if not model then
    return
  end

  local provider = model:get_provider()
  if not provider or not provider.get_stats then
    return
  end

  entry.stats_pending = true
  provider.get_stats(function(stats)
    local e = entries[buf]
    if e then
      e.stats = stats
      e.stats_pending = false
      M.schedule_render()
    end
  end, entry.conversation)
end

--- Render all attached winbars and clean up dead buffers
local function render_all()
  local dead = {}
  local any_busy = false
  for buf, entry in pairs(entries) do
    if not vim.api.nvim_buf_is_loaded(buf) then
      table.insert(dead, buf)
    else
      if entry.strategy.is_busy then
        any_busy = true
      end
      maybe_refresh_stats(buf, entry)
      render_one(buf, entry)
    end
  end
  for _, buf in ipairs(dead) do
    entries[buf] = nil
  end
  if vim.tbl_isempty(entries) then
    M._stop_timer()
  else
    M._adjust_interval(any_busy and BUSY_INTERVAL or IDLE_INTERVAL)
  end
end

local function tick()
  for _, entry in pairs(entries) do
    if entry.strategy.is_busy then
      entry.spinner_frame = (entry.spinner_frame % #SPINNER_FRAMES) + 1
    else
      entry.spinner_frame = 1
    end
  end
  render_all()
end

function M._stop_timer()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
    timer_interval = 0
  end
end

--- Adjust the timer repeat interval if it changed
--- @param interval integer
function M._adjust_interval(interval)
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
    timer:start(100, IDLE_INTERVAL, vim.schedule_wrap(tick))
  end
end

--- Schedule an immediate render pass (coalesced within the current event loop)
function M.schedule_render()
  if render_scheduled then
    return
  end
  render_scheduled = true
  vim.schedule(function()
    render_scheduled = false
    render_all()
  end)
end

--- Register a chat buffer for winbar updates
--- @param buf integer
--- @param conversation sia.Conversation
--- @param strategy sia.ChatStrategy
function M.attach(buf, conversation, strategy)
  M.detach(buf)
  entries[buf] = {
    conversation = conversation,
    strategy = strategy,
    stats = nil,
    stats_pending = false,
    last_usage_total = 0,
    tool_status = nil,
    spinner_frame = 1,
  }
  ensure_timer()
  M.schedule_render()
end

--- Update tool execution status for a chat buffer
--- @param buf integer
--- @param statuses sia.WinbarToolStatus[]?
function M.update_tool_status(buf, statuses)
  local entry = entries[buf]
  if entry then
    entry.tool_status = statuses
    M.schedule_render()
  end
end

--- Update status message for a chat buffer
--- @param buf integer
--- @param status sia.WinbarStatus?
function M.update_status(buf, status)
  local entry = entries[buf]
  if entry then
    entry.status = status
    M.schedule_render()
  end
end

--- @param buf integer
--- @param timeout integer?
function M.clear_status(buf, timeout)
  vim.defer_fn(function()
    M.update_status(buf, nil)
  end, timeout or 500)
end

--- Update context budget for a chat buffer
--- @param buf integer
--- @param budget { estimated: integer, limit: integer, percent: number }?
function M.update_context_budget(buf, budget)
  local entry = entries[buf]
  if entry then
    entry.context_budget = budget
    M.schedule_render()
  end
end

--- Unregister a chat buffer
--- @param buf integer
function M.detach(buf)
  entries[buf] = nil
  if vim.tbl_isempty(entries) then
    M._stop_timer()
  end
end

return M
