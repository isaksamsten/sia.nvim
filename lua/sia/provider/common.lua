local M = {}

function M.apply_caching(message)
  if type(message.content) == "string" then
    message.content = {
      {
        type = "text",
        text = message.content,
        cache_control = { type = "ephemeral" },
      },
    }
  else
    message.content[#message.content].cache_control = { type = "ephemeral" }
  end
end

function M.apply_prompt_caching(messages)
  local last_system_idx = nil
  local last_user_idx = nil
  for i = #messages, 1, -1 do
    if messages[i].role == "system" then
      last_system_idx = i
      break
    end
  end
  for i = #messages, 1, -1 do
    if messages[i].role == "user" then
      last_user_idx = i
      break
    end
  end
  if last_system_idx then
    M.apply_caching(messages[last_system_idx])
  end
  if last_user_idx then
    M.apply_caching(messages[last_user_idx])
  end
end

function M.prepare_parameters(data, model)
  local config = require("sia.config").options
  if model.n then
    data.n = model.n
  end

  if model.max_tokens then
    data.max_tokens = model.max_tokens
  end

  if not model.reasoning_effort then
    data.temperature = model.temperature or config.defaults.temperature
  end

  if model.temperature then
    data.temperature = model.temperature
  end
end

--- @class sia.ProviderStream
--- @field strategy sia.Strategy
M.ProviderStream = {}
M.ProviderStream.__index = M.ProviderStream

--- Create a new stream instance
--- @param strategy sia.Strategy
--- @return sia.ProviderStream
function M.ProviderStream.new(strategy)
  local self = setmetatable({
    strategy = strategy,
  }, M.ProviderStream)
  return self
end

--- @param obj table
--- @return boolean? abort true to abort
function M.ProviderStream:process_stream_chunk(obj)
  return false
end

--- @return string[]? content
function M.ProviderStream:finalize() end

--- @protected
--- @param input { content: string?, reasoning: table?, tool_calls: sia.ToolCall[]?, extra: table? }
--- @return boolean success
function M.ProviderStream:on_content(input)
  return self.strategy:on_content(input)
end

return M
