local tool_utils = require("sia.tools.utils")

local M = {}

--- Create the get_history tool for a specific parent conversation
--- @param messages sia.Message[]
--- @return sia.config.Tool
function M.create_conversation_tool(messages)
  return tool_utils.new_tool({
    name = "get_history",
    read_only = true,
    message = "Reading conversation history...",
    system_prompt = [[Get messages from the parent conversation history. Returns the full content of messages,
starting from the most recent and going backwards.

PARAMETERS:
- last_n: Number of recent messages to return (default: 10)
- query: Optional text to search for (case-insensitive). Only matching messages are returned.
- role: Optional filter by message role ("user", "assistant", or "tool")

The tool returns messages in chronological order (oldest first) with their role and full content.
This gives you direct access to conversation context without needing multiple calls.

EXAMPLES:
- get_history(last_n=10) → Get last 10 messages
- get_history(last_n=20, query="error") → Find up to 20 recent messages containing "error"
- get_history(last_n=15, role="user") → Get last 15 user messages
- get_history(query="Paris") → Search all messages for "Paris" (up to default limit)

TIP: Start with a small last_n value to get oriented, then increase if you need more context.]],
    description = "Get messages from the parent conversation history (returns full content)",
    parameters = {
      last_n = {
        type = "integer",
        description = "Number of recent messages to return (default: 10)",
      },
      query = {
        type = "string",
        description = "Optional: text to search for in message content (case-insensitive)",
      },
      role = {
        type = "string",
        enum = { "user", "assistant", "tool" },
        description = "Optional: filter by message role",
      },
    },
    required = {},
    auto_apply = function(_, _)
      return 1
    end,
  }, function(args, _, callback, _)
    local limit = args.last_n or 10
    local query_lower = args.query and string.lower(args.query)
    local total_messages = #messages

    local matching_messages = {}
    for i = total_messages, 1, -1 do
      local message = messages[i]

      if message.role == "system" or (args.role and message.role ~= args.role) then
        goto continue
      end

      local content = message:get_content()
      if content and type(content) == "string" then
        local matches = true
        if query_lower then
          local content_lower = string.lower(content)
          matches = string.find(content_lower, query_lower, 1, true) ~= nil
        end

        if matches then
          table.insert(matching_messages, 1, {
            role = message.role,
            content = content,
          })

          if #matching_messages >= limit then
            break
          end
        end
      end

      ::continue::
    end

    if #matching_messages == 0 then
      local msg = args.query
          and string.format("No messages found matching '%s'", args.query)
        or "No messages in conversation"
      callback({
        content = { msg },
      })
      return
    end

    local response = {}
    local header = args.query
        and string.format(
          "Found %d message(s) matching '%s' (of %d total messages):",
          #matching_messages,
          args.query,
          total_messages
        )
      or string.format(
        "Showing last %d message(s) (of %d total messages):",
        #matching_messages,
        total_messages
      )

    table.insert(response, header)
    table.insert(response, "")

    for i, msg in ipairs(matching_messages) do
      table.insert(response, string.format("--- Message %d: %s ---", i, msg.role))
      table.insert(response, msg.content)
      table.insert(response, "")
    end

    callback({
      content = response,
    })
  end)
end

--- Start a subagent with access to the parent conversation
--- @param chat sia.ChatStrategy The parent chat strategy
--- @param prompt string The prompt for the subagent
--- @param opts {model:string?, system_prompt:string?}
function M.start(chat, prompt, opts)
  opts = opts or {}
  local system_prompt = opts.system_prompt
    or [[You are an autonomous agent. You perform the user's request using
the available tools and provide a complete answer.

You cannot ask questions or request user input. Complete the task using only the tools
at your disposal and respond with your findings.

]]

  local config = require("sia.config")
  local model = opts.model or config.get_default_model("fast_model")

  local HiddenStrategy = require("sia.strategy").HiddenStrategy
  local Conversation = require("sia.conversation").Conversation

  chat.is_busy = true
  chat.canvas:update_progress({
    { "Waiting for subagent to complete...", "NonText" },
  })

  local parent_messages = chat.conversation:prepare_messages()
  local conversation_tool = M.create_conversation_tool(parent_messages)

  local conversation = Conversation:new({
    mode = "hidden",
    model = model,
    system = {
      {
        role = "system",
        content = string.format(
          [[%s
You have special access to the parent conversation through the get_history tool.
Use this to understand context and previous discussions.
<tools>
{{tool_instructions}}
</tools>]],
          system_prompt
        ),
      },
    },
    instructions = {
      { role = "user", content = prompt },
    },
    tools = {
      conversation_tool,
      "glob",
      "grep",
      "read",
      "websearch",
      "fetch",
    },
  }, nil)

  conversation.name = chat.conversation.name .. "-subagent"

  local strategy = HiddenStrategy:new(conversation, {
    notify = function(message)
      chat.canvas:update_progress({
        { message, "NonText" },
      })
    end,
    callback = function(_, reply)
      chat.canvas:clear_progress()
      if reply then
        chat.conversation:add_instruction({
          role = "assistant",
          content = reply,
        })
        local message = chat.conversation.messages[#chat.conversation.messages]
        chat.canvas:render_messages({ message }, model)
      end
      chat.is_busy = false
    end,
  })

  require("sia.assistant").execute_strategy(strategy)
end

return M
