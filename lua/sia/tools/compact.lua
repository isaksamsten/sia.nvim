local tool_utils = require("sia.tools.utils")

return tool_utils.new_tool({
  name = "compact_conversation",
  message = "Compacting conversation...",
  description = "Compact the conversation by summarizing previous messages when the topic changes significantly",
  system_prompt = [[Use this tool when you detect a significant topic change in
the conversation that makes previous context less relevant. This helps keep
the conversation focused and manageable.

When to use this tool:
1. The user switches from one coding task to a completely different one
2. The conversation has become very long and earlier messages are no longer relevant
3. The user explicitly asks to start fresh or change topics
4. You're working on a different part of the codebase that's unrelated to previous discussion

Do NOT use this tool:
- For minor topic shifts within the same general task
- When previous context is still relevant to the current discussion
- Early in conversations that aren't yet lengthy

The tool will preserve important context while removing outdated information.]],
  parameters = {
    reason = {
      type = "string",
      description = "Brief explanation of why the conversation needs to be compacted (e.g., 'Topic changed from debugging to new feature implementation')",
    },
  },
  required = { "reason" },
}, function(args, conversation, callback)
  if not args.reason then
    callback({ content = { "Error: No reason provided for compacting conversation" } })
    return
  end

  require("sia").compact_conversation(conversation, args.reason, function(content)
    if content then
      callback({
        content = {
          string.format("Successfully compacted conversation. Reason: %s", args.reason),
          "Previous context has been summarized and the conversation is now ready for the new topic.",
        },
        display_content = { "🗂️ Compacted conversation" },
      })
    else
      callback({ content = { "Failed to compact conversation" } })
    end
  end)
end)
