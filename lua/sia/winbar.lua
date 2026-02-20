local M = {}
local common = require("sia.provider.common")

local ICONS = {
  bash = " ",
  agents = " ",
  tool = " ",
}

local SPINNER_FRAMES = { "", "", "", "", "", "" }

--- @class sia.WinbarToolStatus
--- @field name string?
--- @field message string?
--- @field status "pending"|"running"|"done"

--- @class sia.WinbarData
--- @field conversation sia.Conversation?
--- @field is_busy boolean
--- @field stats sia.conversation.Stats?
--- @field tool_status sia.WinbarToolStatus[]?
--- @field spinner string?
--- @field win integer
--- @field buf integer

--- Default left section: shows running tools, agents, and bash processes
--- @param data sia.WinbarData
--- @return string
function M.default_left(data)
  if not data.conversation then
    return ""
  end

  local parts = {}

  if data.spinner and data.is_busy then
    table.insert(parts, "%#SiaTaskRunning#" .. data.spinner .. "  ")
  end
  if data.tool_status then
    local running_names = {}
    local pending_count = 0
    for _, ts in ipairs(data.tool_status) do
      if ts.status == "running" then
        table.insert(running_names, ts.name or "tool")
      elseif ts.status == "pending" then
        pending_count = pending_count + 1
      end
    end
    if #running_names > 0 then
      local label = table.concat(running_names, ", ")
      if pending_count > 0 then
        label = label .. " (+" .. pending_count .. ")"
      end
      table.insert(parts, "%#SiaTaskRunning#" .. ICONS.tool .. " " .. label)
    end
  end

  if data.conversation:has_tool("agents") then
    local running_agents = 0
    for _, task in ipairs(data.conversation.tasks) do
      if task.status == "running" then
        running_agents = running_agents + 1
      end
    end
    table.insert(
      parts,
      "%#"
        .. (running_agents > 0 and "SiaTaskRunning" or "NonText")
        .. "#"
        .. ICONS.agents
        .. running_agents
    )
  end

  if data.conversation:has_tool("bash") then
    local running_bash = 0
    for _, proc in ipairs(data.conversation.bash_processes) do
      if proc.status == "running" then
        running_bash = running_bash + 1
      end
    end
    table.insert(
      parts,
      "%#"
        .. (running_bash > 0 and "SiaTaskRunning" or "NonText")
        .. "#"
        .. ICONS.bash
        .. running_bash
    )
  end

  if #parts == 0 then
    return ""
  end

  return table.concat(parts, "%#NonText# ") .. "%#NonText#"
end

--- Default center section: shows cost tracking bar from provider stats
--- @param data sia.WinbarData
--- @return string
function M.default_center(data)
  local bar = data.stats and data.stats.bar
  if not bar then
    return ""
  end

  local used_percent = bar.percent or 0
  local win_width = vim.api.nvim_win_get_width(data.win)
  local bar_width = math.min(20, win_width - 11)
  if bar_width < 3 then
    return ""
  end

  local filled_bars = math.ceil(used_percent * bar_width)
  if filled_bars > bar_width then
    filled_bars = bar_width
  end
  local empty_bars = bar_width - filled_bars

  local bar_hl = used_percent >= 1 and "%#DiagnosticError#"
    or used_percent >= 0.75 and "%#DiagnosticWarn#"
    or "%#DiagnosticOk#"

  return bar_hl
    .. (bar.icon and (" " .. bar.icon) or "")
    .. string.rep("■", filled_bars)
    .. string.rep("━", empty_bars)
    .. (bar.text and (" " .. bar.text) or "")
    .. bar_hl
end

--- Default right section: shows token count
--- @param data sia.WinbarData
--- @return string
function M.default_right(data)
  if data.stats and data.stats.right then
    return data.stats.right
  end
  if not data.conversation then
    return ""
  end
  local usage = data.conversation:get_cumulative_usage()
  if not usage or usage.total == 0 then
    return ""
  end
  return common.format_token_count(usage.total)
end

--- @class sia.WinbarEntry
--- @field conversation sia.Conversation
--- @field strategy sia.Strategy
--- @field stats sia.conversation.Stats?
--- @field stats_pending boolean
--- @field last_usage_total integer
--- @field tool_status sia.WinbarToolStatus[]?
--- @field spinner_frame integer

--- @type table<integer, sia.WinbarEntry>
local entries = {}

--- @type uv_timer_t?
local timer = nil

--- Render the winbar for a single buffer entry
--- @param buf integer
--- @param entry sia.WinbarEntry
local function render_one(buf, entry)
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    return
  end

  local config = require("sia.config")
  local winbar_config = config.options.defaults.chat.winbar
  if not winbar_config then
    return
  end

  --- @type sia.WinbarData
  local data = {
    conversation = entry.conversation,
    is_busy = entry.strategy.is_busy or false,
    stats = entry.stats,
    tool_status = entry.tool_status,
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
    end
  end, entry.conversation)
end

--- Single tick that renders all attached winbars
local function tick()
  local dead = {}
  for buf, entry in pairs(entries) do
    if not vim.api.nvim_buf_is_loaded(buf) then
      table.insert(dead, buf)
    else
      if entry.strategy.is_busy then
        entry.spinner_frame = (entry.spinner_frame % #SPINNER_FRAMES) + 1
      else
        entry.spinner_frame = 1
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
  end
end

function M._stop_timer()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

local function ensure_timer()
  if timer then
    return
  end
  timer = vim.uv.new_timer()
  if timer then
    timer:start(100, 300, vim.schedule_wrap(tick))
  end
end

--- Register a chat buffer for winbar updates
--- @param buf integer
--- @param conversation sia.Conversation
--- @param strategy sia.Strategy
function M.attach(buf, conversation, strategy)
  M.detach(buf)
  entries[buf] = {
    conversation = conversation,
    strategy = strategy,
    activity = nil,
    stats = nil,
    stats_pending = false,
    last_usage_total = 0,
    tool_status = nil,
    spinner_frame = 1,
  }
  ensure_timer()
end

--- Update tool execution status for a chat buffer
--- @param buf integer
--- @param statuses sia.WinbarToolStatus[]?
function M.update_tool_status(buf, statuses)
  local entry = entries[buf]
  if entry then
    entry.tool_status = statuses
  end
end

--- Update activity status for a chat buffer
--- @param buf integer
--- @param activity string?
function M.update_activity(buf, activity)
  local entry = entries[buf]
  if entry then
    entry.activity = activity
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
