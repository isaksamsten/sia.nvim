local tool_utils = require("sia.tools.utils")

return tool_utils.new_tool({
  name = "dispatch_agent",
  message = "Launching autonomous agent...",
  read_only = true,
  description = [[Launch a new agent that has access to the following tools: list_files, grep, read tools.
  system_prompt = [[When you are searching for a keyword or file and are not confident that you
will find the right match on the first try, use the dispatch_agent tool to perform the
search for you. For example:

1. If you want to read file, the dispatch_agent tool is NOT appropriate. If no
   appropriate tool is available ask the user to do it.
2. If you are searching for a keyword like "config" or "logger", the dispatch_agent tool is appropriate
3. If you want to read a specific file path, use the read tool
   instead of the dispatch_agent tool, to find the match more quickly
4. If you are searching for a specific class definition like "class Foo", use
   the grep tool instead, to find the match more quickly

Usage notes:

1. When a task involves multiple related queries or actions that can be
   efficiently handled together, prefer dispatching a single agent with a
   comprehensive prompt rather than multiple agents with overlapping or similar
   tasks.
2. Launch multiple agents concurrently whenever possible, to maximize
   performance; to do that, use a single message with multiple tool uses
3. When the agent is done, it will return a single message back to you. The
   result returned by the agent is not visible to the user. To show the user
   the result, you should send a text message back to the user with a concise
   summary of the result.
4. Each agent invocation is stateless. You will not be able to send additional
   messages to the agent, nor will the agent be able to communicate with you
   outside of its final report. Therefore, your prompt should contain a highly
   detailed task description for the agent to perform autonomously and you
   should specify exactly what information the agent should return back to you
   in its final and only message to you.
5. The agent's outputs should generally be trusted
6. IMPORTANT: The agent can not modify files. If you want to use these tools,
   use them directly instead of going through the agent.]],
  parameters = {
    prompt = {
      type = "string",
      description = "The task for the agent to perform",
    },
  },
  required = { "prompt" },
}, function(args, _, callback, opts)
  local confirm_message = string.format("Launch agent with task: %s", args.prompt)
  local config = require("sia.config")

  opts.user_input(confirm_message, {
    on_accept = function()
      local HiddenStrategy = require("sia.strategy").HiddenStrategy
      local Conversation = require("sia.conversation").Conversation
      local conversation = Conversation:new({
        mode = "hidden",
        model = config.get_default_model("fast_model"),
        system = {
          {
            role = "system",
            content = [[You are a autonomous agent. You perform the user request
and use tools to provide an answer. You cannot interact; you perform
the requested action using the tools at your disposal and provide a
response]],
          },
        },
        instructions = {
          { role = "user", content = args.prompt },
        },
        ignore_tool_confirm = true,
        tools = {
          "glob",
          "grep",
          "read",
        },
      }, nil)
      local strategy = HiddenStrategy:new(conversation, {
        callback = function(_, reply)
          callback({ content = reply, display_content = { "🤖 Agent completed task" } })
        end,
      }, opts.cancellable)
      require("sia.assistant").execute_strategy(strategy)
    end,
  })
end)
