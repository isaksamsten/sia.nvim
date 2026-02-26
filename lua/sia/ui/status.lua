local M = {}

local icons = require("sia.icons").get()
local format_tokens = require("sia.provider.common").format_token_count
local split = require("sia.ui.split")

local STATUS_NS = vim.api.nvim_create_namespace("sia_status_ui")

local AGENT_STATUS = {
  running = { hl_group = "SiaAgentRunning", icon = icons.started },
  completed = { hl_group = "SiaAgentCompleted", icon = icons.success },
  failed = { hl_group = "SiaAgentFailed", icon = icons.error },
}

local BASH_STATUS = {
  running = { hl_group = "SiaAgentRunning", icon = icons.started },
  completed = { hl_group = "SiaAgentCompleted", icon = icons.success },
  failed = { hl_group = "SiaAgentFailed", icon = icons.error },
  timed_out = { hl_group = "SiaAgentFailed", icon = icons.overloaded },
}

local panel = split.new("status")

--- @type table<integer, integer>  conv_id -> status buffer
M._buffers = {}

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

--- @alias sia.ui.status.LineInfo { hl_group: string? }

--- Render agents and bash processes into lines + highlight info
--- @param conversation sia.Conversation
--- @return string[] lines, sia.ui.status.LineInfo[] line_info
local function render_snapshot(conversation)
  local lines = {}
  local line_info = {}

  -- Agents section
  local agents = conversation.agents or {}
  if #agents > 0 then
    table.insert(lines, "Agents")
    table.insert(line_info, { hl_group = "Title" })

    local running = {}
    local finished = {}
    for _, agent in ipairs(agents) do
      if agent.status == "running" then
        table.insert(running, agent)
      else
        table.insert(finished, agent)
      end
    end

    table.sort(running, function(a, b)
      return a.id > b.id
    end)
    table.sort(finished, function(a, b)
      return a.id > b.id
    end)

    for _, agent in ipairs(running) do
      local cfg = AGENT_STATUS.running
      local progress = (agent.progress and #agent.progress > 0)
          and (" · " .. agent.progress)
        or ""
      table.insert(
        lines,
        string.format("  %s #%d %s%s", cfg.icon, agent.id, agent.name, progress)
      )
      table.insert(line_info, { hl_group = cfg.hl_group })
    end

    for _, agent in ipairs(finished) do
      local status = agent.status == "completed" and "completed" or "failed"
      local cfg = AGENT_STATUS[status]
      local tokens = ""
      if agent.usage and agent.usage.total and agent.usage.total > 0 then
        tokens = string.format(" (%s tokens)", format_tokens(agent.usage.total))
      end
      table.insert(
        lines,
        string.format("  %s #%d %s%s", cfg.icon, agent.id, agent.name, tokens)
      )
      table.insert(line_info, { hl_group = cfg.hl_group })
    end
  end

  -- Bash processes section
  local procs = conversation.bash_processes or {}
  if #procs > 0 then
    if #lines > 0 then
      table.insert(lines, "")
      table.insert(line_info, {})
    end

    table.insert(lines, "Processes")
    table.insert(line_info, { hl_group = "Title" })

    local running_procs = {}
    local finished_procs = {}
    for _, proc in ipairs(procs) do
      if proc.status == "running" then
        table.insert(running_procs, proc)
      else
        table.insert(finished_procs, proc)
      end
    end

    table.sort(running_procs, function(a, b)
      return a.id > b.id
    end)
    table.sort(finished_procs, function(a, b)
      return a.id > b.id
    end)

    for _, proc in ipairs(running_procs) do
      local cfg = BASH_STATUS.running
      local label = proc.description or proc.command
      local elapsed = format_duration(vim.uv.hrtime() / 1e9 - proc.started_at)
      table.insert(
        lines,
        string.format("  %s #%d %s (%s)", cfg.icon, proc.id, label, elapsed)
      )
      table.insert(line_info, { hl_group = cfg.hl_group })
    end

    for _, proc in ipairs(finished_procs) do
      local status = proc.status or "failed"
      local cfg = BASH_STATUS[status] or BASH_STATUS.failed
      local label = proc.description or proc.command
      local duration = ""
      if proc.completed_at and proc.started_at then
        duration = " " .. format_duration(proc.completed_at - proc.started_at)
      end
      local exit_code = ""
      if proc.code and proc.code ~= 0 then
        exit_code = string.format(" [exit %d]", proc.code)
      end
      table.insert(
        lines,
        string.format("  %s #%d %s%s%s", cfg.icon, proc.id, label, duration, exit_code)
      )
      table.insert(line_info, { hl_group = cfg.hl_group })
    end
  end

  if #lines == 0 then
    return { "No agents or processes" }, { {} }
  end

  return lines, line_info
end

--- Apply line highlights to the buffer
--- @param buf integer
--- @param line_info sia.ui.status.LineInfo[]
local function apply_highlights(buf, line_info)
  vim.api.nvim_buf_clear_namespace(buf, STATUS_NS, 0, -1)
  for i, info in ipairs(line_info) do
    if info.hl_group then
      vim.api.nvim_buf_set_extmark(buf, STATUS_NS, i - 1, 0, {
        hl_group = info.hl_group,
        hl_mode = "combine",
        hl_eol = true,
      })
    end
  end
end

--- Get or create the status buffer for a conversation, filled with a snapshot.
--- @param conversation sia.Conversation
--- @return integer buf
local function get_or_create_buf(conversation)
  local buf = M._buffers[conversation.id]
  if buf and vim.api.nvim_buf_is_valid(buf) then
    -- Re-render into the existing buffer
    local lines, line_info = render_snapshot(conversation)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    apply_highlights(buf, line_info)
    return buf
  end

  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "sia-status"
  pcall(
    vim.api.nvim_buf_set_name,
    buf,
    string.format("*%s status*", conversation.name)
  )

  local lines, line_info = render_snapshot(conversation)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  apply_highlights(buf, line_info)

  M._buffers[conversation.id] = buf
  return buf
end

--- Open/close/toggle the status panel for the current chat.
--- @param action? "open"|"close"|"toggle"
function M.toggle(action)
  action = action or "toggle"

  local chat = require("sia.strategy").ChatStrategy.by_buf()
  if not chat then
    return
  end

  if action == "close" then
    panel:close(chat.buf)
    return
  end

  if action == "toggle" and panel:is_open(chat.buf) then
    panel:close(chat.buf)
    return
  end

  local buf = get_or_create_buf(chat.conversation)
  panel:open(chat.buf, buf)
end

return M

