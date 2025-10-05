local tool_utils = require("sia.tools.utils")

return tool_utils.new_tool({
  name = "plan",
  message = "Launching planning agent...",
  read_only = true,
  description = [[Launch a planning agent that analyzes the current situation and creates a concrete actionable plan.

The planning agent has access to exploration tools (glob, grep, read) to understand the
codebase structure and requirements. It will return a detailed plan with specific,
actionable steps that the main agent can implement.

Usage notes:

1. Use this tool when you have a good understanding of what the user wants but need to create a concrete implementation plan
2. The planning agent will explore the codebase to understand the current structure and identify what needs to be changed
3. The agent will return a structured plan with specific steps, file locations, and implementation details
4. Each step in the plan should be actionable and specific enough for the main agent to implement
5. The planning agent cannot modify files - it only analyzes and plans
6. Use this when the task is complex enough to benefit from dedicated planning phase]],
  parameters = {
    prompt = {
      type = "string",
      description = "The planning task - describe what needs to be accomplished and any specific requirements or constraints",
    },
  },
  required = { "prompt" },
}, function(args, _, callback, opts)
  local confirm_message = string.format("Launch planning agent for: %s", args.prompt)
  local config = require("sia.config")
  opts.user_input(confirm_message, {
    on_accept = function()
      local HiddenStrategy = require("sia.strategy").HiddenStrategy
      local Conversation = require("sia.conversation").Conversation
      local conversation = Conversation:new({
        mode = "hidden",
        model = config.get_default_model("plan_model"),
        system = {
          {
            role = "system",
            content = [[You are a specialized planning agent. Your role is to analyze
the current codebase and create detailed, actionable implementation plans.

Your responsibilities:
1. Use the available tools (glob, grep, read) to explore and understand the current codebase structure
2. Identify what files need to be created, modified, or removed
3. Understand existing patterns and conventions in the codebase
4. Create a step-by-step implementation plan with specific details

Your response should be a structured plan that includes:
- Overview of the task and approach
- List of files that need to be examined/modified/created
- Step-by-step implementation plan with specific details
- Any dependencies or prerequisites
- Potential challenges or considerations

Make your plan concrete and actionable - each step should be specific enough that another agent can implement it without additional planning.]],
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
          if reply then
            callback({
              content = reply,
              display_content = { "📋 Planning agent completed analysis" },
            })
          else
            callback({
              content = { "Planning failed" },
              display_content = { "📋 Planning agent completed analysis" },
            })
          end
        end,
      }, opts.cancellable)
      require("sia.assistant").execute_strategy(strategy)
    end,
  })
end)
