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

--- Format token count for display (e.g., "45.2K", "1.3M")
--- @param total integer
--- @return string
function M.format_token_count(total)
  if total >= 1000000 then
    return string.format("%.1fM", total / 1000000)
  elseif total >= 1000 then
    return string.format("%.1fK", total / 1000)
  else
    return tostring(total)
  end
end

--- Calculate cost from pricing info and token counts
--- @param pricing { input: number, output: number }
--- @param input_tokens integer
--- @param output_tokens integer
--- @param multiplier number?
--- @return number cost in USD
local function calculate_cost_from_pricing(
  pricing,
  input_tokens,
  output_tokens,
  multiplier
)
  multiplier = multiplier or 1.0
  local input_cost = (input_tokens / 1000000) * pricing.input * multiplier
  local output_cost = (output_tokens / 1000000) * pricing.output
  return input_cost + output_cost
end

--- Create a cost-based stats function for providers
--- @param builtin_pricing table<string, { input: number, output: number }>
--- @param cache_multiplier {read: number, write: number}?
--- @return fun(callback: fun(stats: table?), conversation: sia.Conversation)
function M.create_cost_stats(builtin_pricing, cache_multiplier)
  return function(callback, conversation)
    local usage = conversation:get_cumulative_usage()

    if not usage or usage.total == 0 then
      callback()
      return
    end

    local token_str = M.format_token_count(usage.total)

    local cost = nil
    if conversation and conversation.model then
      local config = require("sia.config")
      local model_spec = config.options.models[conversation.model]

      if model_spec then
        if model_spec.pricing then
          cost =
            calculate_cost_from_pricing(model_spec.pricing, usage.input, usage.output)
          if model_spec.cache_multiplier then
            if usage.cache_read then
              cost = cost
                + calculate_cost_from_pricing(
                  model_spec.pricing,
                  usage.cache_write,
                  0,
                  model_spec.cache_multiplier.read
                )
            end
            if usage.cache_write then
              cost = cost
                + calculate_cost_from_pricing(
                  model_spec.pricing,
                  usage.cache_write,
                  0,
                  model_spec.cache_multiplier.write
                )
            end
          end
        elseif builtin_pricing then
          local actual_model_name = model_spec[2]
          local pricing = builtin_pricing[actual_model_name]
          if pricing then
            cost = calculate_cost_from_pricing(pricing, usage.input, usage.output)
            if cache_multiplier then
              if usage.cache_read then
                cost = cost
                  + calculate_cost_from_pricing(
                    pricing,
                    usage.cache_read,
                    0,
                    cache_multiplier.read
                  )
              end
              if usage.cache_write then
                cost = cost
                  + calculate_cost_from_pricing(
                    pricing,
                    usage.cache_write,
                    0,
                    cache_multiplier.write
                  )
              end
            end
          end
        end
      end
    end

    if not cost then
      callback({ right = token_str })
      return
    end

    local cost_str
    if cost >= 1.0 then
      cost_str = string.format("$%.2f", cost)
    else
      cost_str = string.format("$%.3f", cost)
    end

    local max_cost = 1.0
    local cost_percent = math.min(cost / max_cost, 1)

    callback({
      bar = { percent = cost_percent, icon = "", text = cost_str },
      right = token_str,
    })
  end
end

return M
