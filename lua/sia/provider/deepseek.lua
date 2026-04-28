local M = {}
local openai = require("sia.provider.openai")

local function is_empty_content(content)
  return content == nil or content == ""
end

local function rename_reasoning_field(message)
  if message.reasoning_text then
    message.reasoning_content = message.reasoning_text
    message.reasoning_text = nil
  end
end

local function normalize_messages(messages)
  local normalized = {}
  local i = 1

  while i <= #messages do
    local message = vim.deepcopy(messages[i])
    rename_reasoning_field(message)

    if message.role ~= "assistant" then
      table.insert(normalized, message)
      i = i + 1
    else
      local next_message = messages[i + 1]
      local can_absorb_following_tool_calls = not message.tool_calls
        and next_message
        and next_message.role == "assistant"
        and next_message.tool_calls

      if not message.tool_calls and not can_absorb_following_tool_calls then
        table.insert(normalized, message)
        i = i + 1
      else
        local grouped = message
        grouped.tool_calls = grouped.tool_calls or {}
        local tool_results = {}
        local cursor = i + 1
        local valid = true
        local consumed_any = false
        local buffered_users = {}

        local function consume_tool_results(tool_calls)
          for _, tool_call in ipairs(tool_calls) do
            local tool_message = messages[cursor]
            if
              not (
                tool_message
                and tool_message.role == "tool"
                and tool_message.tool_call_id == tool_call.id
              )
            then
              return false
            end
            table.insert(tool_results, vim.deepcopy(tool_message))
            cursor = cursor + 1
            consumed_any = true
          end
          return true
        end

        if #grouped.tool_calls > 0 and not consume_tool_results(grouped.tool_calls) then
          valid = false
        end

        while valid and messages[cursor] and messages[cursor].role == "user" do
          table.insert(buffered_users, vim.deepcopy(messages[cursor]))
          cursor = cursor + 1
        end

        while valid do
          local assistant_call = messages[cursor]
          if
            not (assistant_call and assistant_call.role == "assistant")
            or not (assistant_call.tool_calls or can_absorb_following_tool_calls)
          then
            break
          end

          local assistant_call_copy = vim.deepcopy(assistant_call)
          rename_reasoning_field(assistant_call_copy)
          if
            assistant_call_copy.reasoning_content
            or assistant_call_copy.reasoning_text
            or not is_empty_content(assistant_call_copy.content)
          then
            break
          end

          cursor = cursor + 1
          if not assistant_call_copy.tool_calls then
            local tool_call_message = messages[cursor]
            if
              not (
                tool_call_message
                and tool_call_message.role == "assistant"
                and tool_call_message.tool_calls
              )
            then
              valid = false
              break
            end
            assistant_call_copy = vim.deepcopy(tool_call_message)
            rename_reasoning_field(assistant_call_copy)
            cursor = cursor + 1
          end

          for _, tool_call in ipairs(assistant_call_copy.tool_calls) do
            table.insert(grouped.tool_calls, tool_call)
          end
          if not consume_tool_results(assistant_call_copy.tool_calls) then
            valid = false
            break
          end

          while valid and messages[cursor] and messages[cursor].role == "user" do
            table.insert(buffered_users, vim.deepcopy(messages[cursor]))
            cursor = cursor + 1
          end
        end

        if valid then
          table.insert(normalized, grouped)
          vim.list_extend(normalized, tool_results)
          vim.list_extend(normalized, buffered_users)
          i = cursor
        else
          table.insert(normalized, message)
          i = i + 1
        end
      end
    end
  end

  return normalized
end

local function tool_call_to_payload(tool_call)
  return {
    id = tool_call.id,
    type = tool_call.type,
    ["function"] = {
      name = tool_call.name,
      arguments = tool_call.arguments,
    },
  }
end

--- @type sia.provider.ProviderSpec
M.spec = {
  implementations = {
    default = openai.completion_compatible(
      "https://api.deepseek.com/",
      "chat/completions",
      {
        api_key = function()
          return os.getenv("DEEPSEEK_API_KEY")
        end,
        prepare_parameters = function(data, model)
          if model.support and model.support.reasoning then
            data.thinking = { type = "enabled" }
          end
        end,
        prepare_messages = function(data, _, _)
          data.messages = normalize_messages(data.messages)
          for _, message in ipairs(data.messages) do
            if message.tool_call then
              message.tool_calls = { tool_call_to_payload(message.tool_call) }
              message.tool_call = nil
            elseif message.tool_calls then
              local payload = {}
              for _, tool_call in ipairs(message.tool_calls) do
                if tool_call["function"] then
                  table.insert(payload, tool_call)
                else
                  table.insert(payload, tool_call_to_payload(tool_call))
                end
              end
              message.tool_calls = payload
            end
          end
        end,
      }
    ),
  },
  seed = {
    ["v4-flash"] = {
      api_name = "deepseek-v4-flash",
      context_window = 384000,
      support = { reasoning = true },
      pricing = {
        input = 0.00000014,
        output = 0.00000028,
      },
      cache_multiplier = { read = 0.2 },
    },
    ["v4-pro"] = {
      api_name = "deepseek-v4-pro",
      context_window = 384000,
      support = { reasoning = true },
      pricing = {
        input = 0.00000014,
        output = 0.00000028,
      },
      cache_multiplier = { read = 0.2 },
    },
  },
}

return M
