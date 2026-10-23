local M = {}

--- A bounded snapshot of current work, independent of transcript summaries.
--- @class sia.Activity
--- @field phase string
--- @field message string
--- @field completed integer
--- @field total integer
--- @field running integer
--- @field last_completed string?
--- @field response string
--- @field done table<any, boolean>

function M.new()
  return {
    phase = "waiting",
    message = "Waiting for model…",
    completed = 0,
    total = 0,
    running = 0,
    response = "",
    done = {},
  }
end

--- Begin a model round, retaining the previous batch's statistics as context.
--- @param activity sia.Activity
function M.round(activity)
  activity.phase = "waiting"
  activity.message = "Waiting for model…"
  activity.response = ""
  activity.done = {}
end

local function header(summary)
  if type(summary) == "table" then
    return summary.header
  end
  return type(summary) == "string" and summary or nil
end

--- @param activity sia.Activity
--- @param statuses sia.engine.Status[]
function M.tools(activity, statuses)
  local completed, running, first = 0, 0, nil
  for index, status in ipairs(statuses) do
    if status.status == "done" then
      completed = completed + 1
      local key = status.key or index
      if not activity.done[key] then
        activity.last_completed = header(status.summary) or status.name
        activity.done[key] = true
      end
    elseif status.status == "running" then
      running = running + 1
      first = first or status
    end
  end
  activity.completed = completed
  activity.total = #statuses
  activity.running = running
  if first then
    activity.phase = "tools"
    activity.message = header(first.activity)
      or ("Using " .. (first.name or "tool") .. "…")
    if running > 1 then
      activity.message = activity.message
        .. string.format(" (+%d running)", running - 1)
    end
  elseif completed == #statuses then
    activity.phase = "waiting"
    activity.message = "Waiting for model…"
  else
    activity.phase = "tools"
    activity.message = "Preparing tools…"
  end
end

--- @param activity sia.Activity
--- @param input sia.StreamDelta
function M.stream(activity, input)
  if input.reasoning and input.reasoning.content and input.reasoning.content ~= "" then
    activity.phase = "reasoning"
    activity.message = "Reasoning…"
  end
  if input.content and input.content ~= "" then
    activity.phase = "responding"
    activity.message = "Writing response…"
    local response = activity.response .. input.content
    activity.response =
      vim.fn.strcharpart(response, math.max(0, vim.fn.strchars(response) - 1000))
  end
end

--- @param messages sia.conversation.PendingUserMessage[]
--- @param next_mode sia.chat.Submit?
--- @return string[]
function M.pending(messages, next_mode)
  local previews, count = {}, 0
  local function add(message)
    if message.hide or type(message.content) ~= "string" then
      return
    end
    local text = vim.trim(message.content:gsub("%s+", " "))
    if text == "" then
      return
    end
    count = count + 1
    if #previews < 3 then
      if vim.fn.strchars(text) > 120 then
        text = vim.fn.strcharpart(text, 0, 119) .. "…"
      end
      table.insert(previews, "↳ " .. text)
    end
  end
  for _, message in ipairs(messages) do
    add(message)
  end
  if next_mode then
    add({ content = next_mode.content })
  end
  if count > #previews then
    table.insert(previews, string.format("+%d more pending", count - #previews))
  end
  return previews
end

return M
