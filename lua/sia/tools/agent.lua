local tool_utils = require("sia.tools.utils")

local START_REPLY = [[
Async agent launched successfully.
agentId: %d (This is an internal ID for your use, do not mention it to the user. Use
this ID to retrieve results with agent(id=id, command="wait") when the agent finishes.
The agent is currently working in the background. If you have other tasks you you should
continue working on them now. Wait to call agent(command="wait") until either:
- If you want to check on the agent's progress - call agent(command="status") to get an
  immediate update on the agent's status
- If you run out of things to do and the agent is still running - call
  agent(command="wait") to idle and wait for the agent's result (do not use
  "wait" unless you completely run out of things to do as it will waste time).
]]

return tool_utils.new_tool({
  name = "task",
  message = "Launching autonomous agent...",
  read_only = true,
  description = [[Launch a new agent to handle complex, multi-step tasks autonomously.]],
  system_prompt = [[The task tool launches specialized agents (subprocesses) that
autonomously handle complex tasks. Each agent type has specific capabilities and tools
available to it.

Use the `list` command to see what agent types and tools they have access to.

When using the task tool, you must specify a subagent_type parameter to select which agent type to use.

When NOT to use the task tool:
- If you want to read a specific file path, use the read or grep tool instead of the task tool, to find the match more quickly
- If you are searching for a specific class definition like "class Foo", use the grep tool instead, to find the match more quickly
- If you are searching for code within a specific file or set of 2-3 files, use the read tool instead of the task tool, to find the match more quickly
- Other tasks that are not related to the agent descriptions above


Usage notes:
- Launch multiple agents concurrently whenever possible, to maximize performance; to do
  that, use a single message with multiple tool uses
- When the agent is done, it will return a single message back to you. The result
  returned by the agent is not visible to the user. To show the user the result, you
  should send a text message back to the user with a concise summary of the result.
- Each agent invocation is stateless. You will not be able to send additional messages
  to the agent, nor will the agent be able to communicate with you outside of its final
  report. Therefore, your prompt should contain a highly detailed task description for the
  agent to perform autonomously and you should specify exactly what information the agent
  should return back to you in its final and only message to you.
- Agents with "access to current context" can see the full conversation history before
  the tool call. When using these agents, you can write concise prompts that reference
  earlier context (e.g., "investigate the error discussed above") instead of repeating
  information. The agent will receive all prior messages and understand the context.
- The agent's outputs should generally be trusted
- Clearly tell the agent whether you expect it to write code or just to do research
  (search, file reads, web fetches, etc.), since it is not aware of the user's intent
- If the agent description mentions that it should be used proactively, then you should
  try your best to use it without the user having to ask for it first. Use your judgement.
- If the user specifies that they want you to run agents "in parallel", you MUST send a
  single message with multiple tark tool use content blocks. For example, if
  you need to launch both a code-reviewer agent and a test-runner agent in parallel, send
  a single message with both tool calls.
]],
  parameters = {
    command = {
      type = "string",
      enum = { "list", "start", "status", "wait" },
      description = "The command to execute: list (show available agents), start (launch new agent), status (check agent status), wait (wait for agent completion)",
    },
    agent = {
      type = "string",
      description = "The name of the agent type to launch (required for 'start' command)",
    },
    task = {
      type = "string",
      description = "The task for the agent to perform (required for 'start' command)",
    },
    id = {
      type = "integer",
      description = "The ID of an already running agent (required for 'status' and 'wait' commands)",
    },
  },
  required = { "command" },
}, function(args, conversation, callback, opts)
  local config = require("sia.config")
  local agent_registry = require("sia.agent_registry")
  local tasks = require("sia.tasks")

  if args.command == "list" then
    local agent_defintions = agent_registry.get_agent_definitions()

    if vim.tbl_count(agent_defintions) == 0 then
      callback({
        content = {
          "No agents available.",
        },
      })
      return
    end

    local content_lines = { "Available agents:", "" }
    for _, task in pairs(agent_defintions) do
      table.insert(
        content_lines,
        string.format("- %s: %s", task.name, task.description)
      )
      table.insert(
        content_lines,
        string.format(
          "  Tools: %s | Model: %s",
          table.concat(task.tools, ", "),
          task.model
        )
      )
    end

    callback({
      content = content_lines,
    })
  elseif args.command == "start" then
    if not args.agent then
      callback({
        content = { "Error: 'agent' parameter is required for 'start' command" },
        display_content = { "❌ Missing agent parameter" },
      })
      return
    end

    if not args.task then
      callback({
        content = { "Error: 'task' parameter is required for 'start' command" },
        display_content = { "❌ Missing task parameter" },
      })
      return
    end

    local agent_def = agent_registry.get_agent_definition(args.agent)

    if not agent_def then
      callback({
        content = {
          string.format(
            "Error: Agent '%s' not found. Use 'list' command to see available agents.",
            args.agent
          ),
        },
        display_content = { string.format("❌ Agent '%s' not found", args.agent) },
      })
      return
    end

    local confirm_message =
      string.format("Launch %s agent with task: %s", args.agent, args.task)
    opts.user_input(confirm_message, {
      on_accept = function()
        local task = conversation:new_task(args.agent, args.task)

        local HiddenStrategy = require("sia.strategy").HiddenStrategy
        local Conversation = require("sia.conversation").Conversation
        local new_conversation = Conversation:new({
          mode = "hidden",
          model = agent_def.model or config.get_default_model("fast_model"),
          system = {
            {
              role = "system",
              content = agent_def.system_prompt,
            },
          },
          instructions = {
            { role = "user", content = args.task },
          },
          ignore_tool_confirm = agent_def.require_confirmation == false,
          tools = agent_def.tools,
        }, nil)
        new_conversation.name = conversation.name .. "-" .. task.name
        local strategy = HiddenStrategy:new(new_conversation, {
          notify = function(msg)
            task.progress = msg
            tasks.update_progress(conversation)
          end,
          callback = function(_, reply, usage)
            if task then
              if reply then
                task.status = "completed"
                task.result = reply
              else
                task.status = "failed"
                task.error = "No response (or cancelled)"
              end
              task.usage = usage
              tasks.update_progress(conversation)
            else
              task.status = "failed"
              task.error = "not started"
            end
          end,
        }, opts.cancellable)
        require("sia.assistant").execute_strategy(strategy)

        callback({
          content = vim.split(string.format(START_REPLY, task.id), "\n"),
          display_content = {
            string.format("🚀 Started agent '%s'", args.agent),
          },
        })
      end,
    })
  elseif args.command == "status" then
    if not args.id then
      callback({
        content = { "Error: 'id' parameter is required for 'status' command" },
        display_content = { "❌ Missing id parameter" },
      })
      return
    end

    local task = conversation:get_task(args.id)

    if not task then
      callback({
        content = {
          string.format(
            "Error: Agent with ID %d not found in this conversation",
            args.id
          ),
        },
      })
      return
    end

    local content = {
      string.format("Agent ID: %d", task.id),
      string.format("Agent: %s", task.name),
      string.format("Status: %s", task.status),
      string.format("Task: %s", task.task),
    }

    if task.status == "completed" and task.result then
      table.insert(content, "")
      table.insert(content, "Result:")
      for _, line in ipairs(task.result) do
        table.insert(content, line)
      end
    elseif task.status == "failed" and task.error then
      table.insert(content, "")
      table.insert(content, string.format("Error: %s", task.error))
    end

    callback({ content = content })
  elseif args.command == "wait" then
    if not args.id then
      callback({ content = { "Error: 'id' parameter is required for 'wait' command" } })
      return
    end

    local task = conversation:get_task(args.id)
    if not task then
      callback({
        content = {
          string.format(
            "Error: Agent with ID %d not found in this conversation",
            args.id
          ),
        },
      })
      return
    end

    local function poll()
      local current_agent = conversation:get_task(args.id)
      if not current_agent then
        callback({
          content = { "Error: Agent instance was removed" },
        })
        return
      end

      if current_agent.status == "completed" then
        local content = {
          string.format("Agent %d (%s) completed:", args.id, current_agent.name),
          "",
        }
        if current_agent.result then
          for _, line in ipairs(current_agent.result) do
            table.insert(content, line)
          end
        end
        callback({
          content = content,
          display_content = {
            string.format("✅ Agent %s completed", task.name),
          },
        })
      elseif current_agent.status == "failed" then
        callback({
          content = {
            string.format("Agent %d (%s) failed:", args.id, current_agent.name),
            "",
            string.format("Error: %s", current_agent.error or "Unknown error"),
          },
          display_content = { string.format("❌ Agent %d failed", args.id) },
        })
      else
        vim.defer_fn(poll, 500)
      end
    end

    poll()
  else
    callback({
      content = { string.format("Error: Unknown command '%s'", args.command) },
    })
  end
end)
