--- Context window management: token estimation, budget tracking, and auto-pruning.
---
--- This module lives at the strategy level and modifies the conversation directly.
--- It does NOT replace the existing outdating mechanism in conversation.lua — that
--- handles tick-based staleness. This module handles hard context window limits.
local M = {}

--- Normalize a message for the summarizer by converting tool calls and tool
--- results into plain text. This avoids passing provider-specific tool call
--- IDs (e.g., Anthropic's `toolu_...` vs OpenAI's `call_...`) to a potentially
--- different provider used for summarization.
--- @param msg sia.Message
--- @return { role: string, content: string }
local function normalize_for_summary(msg)
  local parts = {}

  if msg.content and msg.content ~= "" then
    table.insert(parts, msg.content)
  end

  if msg.tool_calls then
    for _, tc in ipairs(msg.tool_calls) do
      local name = tc["function"] and tc["function"].name
        or tc["custom"] and tc["custom"].name
        or "unknown"
      local args = tc["function"] and tc["function"].arguments
        or tc["custom"] and tc["custom"].input
        or ""
      table.insert(parts, string.format("[Tool call: %s(%s)]", name, args))
    end
  end

  local tc = msg._tool_call
  if tc then
    local name = tc["function"] and tc["function"].name
      or tc["custom"] and tc["custom"].name
      or "unknown"
    table.insert(parts, 1, string.format("[Tool result: %s]", name))
  end

  local role = msg.role
  if role == "tool" then
    role = "user"
  end

  return {
    role = role,
    content = table.concat(parts, "\n"),
  }
end

--- Compact a conversation by summarizing previous messages
--- @param conversation sia.Conversation The conversation object to compact
--- @param opts { reason: string?, ratio: number?, on_complete: fun(content: string?)? }
local compact_conversation = function(conversation, opts)
  opts = opts or {}
  local new_conversation = require("sia.conversation").Conversation:new({
    model = require("sia.config").options.settings.fast_model,
    system = {
      {
        role = "system",
        content = [[You are tasked with compacting a conversation by creating a
comprehensive summary that preserves all essential information for
continuing the conversation.

CRITICAL REQUIREMENTS:
1. Preserve ALL technical details: file paths, function names, class names,
   variable names, configuration settings
2. Maintain the chronological order of decisions and changes made
3. Include specific code snippets or patterns that were discussed or implemented
4. Preserve any architectural decisions, design patterns, or coding standards established
5. Keep track of any bugs identified, solutions attempted, and their outcomes
6. Maintain context about the codebase structure and relationships between components

SUMMARY STRUCTURE:
- **Project Context**: Brief description of the project and its purpose
- **Files Modified**: List all files that were created, modified, or discussed
  with specific changes
- **Key Decisions**: Important architectural, design, or implementation
  decisions made
- **Code Changes**: Specific functions, classes, or code blocks that were added/modified
- **Outstanding Issues**: Any unresolved problems, TODOs, or areas needing attention
- **Technical Details**: Configuration changes, dependencies, or environment setup

OUTPUT FORMAT:
Write a clear, structured summary using markdown formatting. Be concise but
comprehensive - the summary should allow someone to understand the full context
and continue working on the project without losing important details.

The summary will replace the conversation history, so ensure no critical
information is lost.]],
      },
    },
    instructions = {},
  }, nil)

  local prepared = conversation:prepare_messages()

  -- Collect dropped non-system messages from the raw conversation.
  -- These are filtered out by prepare_messages() but their content is still
  -- intact. We always include them in the summarizer input since they are
  -- essentially free to compact (already excluded from the context window).
  local dropped_messages = {}
  for _, m in ipairs(conversation.messages) do
    if m.status == "dropped" and m.role ~= "system" and m:has_content() then
      table.insert(dropped_messages, m)
    end
  end

  -- Determine which non-dropped, non-system messages to compact
  local non_system = {}
  for i, message in ipairs(prepared) do
    if message.role ~= "system" then
      table.insert(non_system, { index = i, message = message })
    end
  end

  local compact_count = #non_system
  if opts.ratio and opts.ratio > 0 and opts.ratio < 1 then
    compact_count = math.max(1, math.floor(#non_system * opts.ratio))
  end

  for _, m in ipairs(dropped_messages) do
    new_conversation:add_instruction(normalize_for_summary(m), nil)
  end

  for i = 1, compact_count do
    local msg = non_system[i].message
    new_conversation:add_instruction(normalize_for_summary(msg), nil)
  end

  require("sia.assistant").fetch_response(new_conversation, function(content)
    if content then
      if compact_count >= #non_system then
        conversation:clear_user_instructions()
      else
        local dropped = 0
        for _, m in ipairs(conversation.messages) do
          if m.role ~= "system" and m.status ~= "dropped" then
            conversation:set_message_status(m, "dropped")
            dropped = dropped + 1
            if dropped >= compact_count then
              break
            end
          end
        end
      end

      local dropped_set = {}
      for _, m in ipairs(dropped_messages) do
        dropped_set[m] = true
      end
      conversation.messages = vim
        .iter(conversation.messages)
        :filter(function(m)
          if dropped_set[m] then
            return false
          end
          if m.status == "superseded" then
            return false
          end
          return true
        end)
        :totable()
      conversation:_invalidate_cache()

      local summary_content
      if opts.reason then
        summary_content = string.format(
          "This is a summary of a previous conversation (%s):\n\n%s",
          opts.reason,
          content
        )
      else
        summary_content = string.format(
          "This is a summary of the conversation which has been removed:\n %s",
          content
        )
      end

      conversation:add_instruction({
        role = "user",
        content = summary_content,
      })

      if opts.on_complete then
        opts.on_complete(content)
      end
    elseif opts.on_complete then
      opts.on_complete(nil)
    end
  end)
end

--- Estimate the number of bytes in a prepared message.
--- We serialize content + tool_calls to get a reasonable byte count.
--- @param message sia.PreparedMessage
--- @return integer bytes
local function message_bytes(message)
  local bytes = 0

  -- Content
  if message.content then
    if type(message.content) == "string" then
      bytes = bytes + #message.content
    elseif type(message.content) == "table" then
      for _, part in ipairs(message.content) do
        if part.text then
          bytes = bytes + #part.text
        elseif part.file and part.file.file_data then
          bytes = bytes + #part.file.file_data
        end
      end
    end
  end

  -- Tool calls (assistant messages requesting tool use)
  if message.tool_calls then
    for _, tc in ipairs(message.tool_calls) do
      if tc["function"] then
        bytes = bytes + #(tc["function"].name or "")
        bytes = bytes + #(tc["function"].arguments or "")
      elseif tc["custom"] then
        bytes = bytes + #(tc["custom"].name or "")
        bytes = bytes + #(tc["custom"].input or "")
      end
    end
  end

  -- Tool call metadata (tool result messages)
  if message._tool_call then
    local tc = message._tool_call or {}
    local fn = tc["function"]
    local custom = tc["custom"]
    if fn then
      bytes = bytes + #(fn.name or "")
      bytes = bytes + #(fn.arguments or "")
    elseif custom then
      bytes = bytes + #(custom.name or "")
      bytes = bytes + #(custom.input or "")
    end
  end

  -- Role overhead (roughly ~10 tokens per message for framing)
  bytes = bytes + 40

  return bytes
end

--- Estimate the number of bytes in tool definitions.
--- Cached on the conversation since tools don't change during its lifetime.
--- @param conversation sia.Conversation
--- @return integer bytes
local function tool_definition_bytes(conversation)
  if conversation._tool_def_bytes then
    return conversation._tool_def_bytes
  end
  local bytes = 0
  if conversation.tools then
    for _, tool in ipairs(conversation.tools) do
      bytes = bytes + #(tool.name or "")
      bytes = bytes + #(tool.description or "")
      if tool.parameters then
        local ok, json = pcall(vim.json.encode, tool.parameters)
        if ok then
          bytes = bytes + #json
        end
      end
    end
  end
  conversation._tool_def_bytes = bytes
  return bytes
end

--- Estimate the token count for a conversation's prepared messages.
--- Uses the heuristic: tokens ≈ bytes / 4
--- @param conversation sia.Conversation
--- @return integer estimated_tokens
function M.estimate_tokens(conversation)
  local messages = conversation:prepare_messages()
  local total_bytes = 0
  for _, message in ipairs(messages) do
    total_bytes = total_bytes + message_bytes(message)
  end
  total_bytes = total_bytes + tool_definition_bytes(conversation)
  return math.floor(total_bytes / 4)
end

--- Get the context window budget information for a conversation.
--- @param conversation sia.Conversation
--- @return { estimated: integer, limit: integer, percent: number }?
function M.get_budget(conversation)
  local model = conversation.model
  if not model then
    return nil
  end
  local context_window = model:get_param("context_window")
  if not context_window then
    return nil
  end
  local estimated = M.estimate_tokens(conversation)
  return {
    estimated = estimated,
    limit = context_window,
    percent = estimated / context_window,
  }
end

--- Find tool call pairs (assistant message with tool_calls + tool result message)
--- that are eligible for hard-dropping. Returns them oldest-first.
--- @param conversation sia.Conversation
--- @return { assistant_idx: integer, tool_idx: integer, tool_call_id: string }[]
local function find_droppable_tool_pairs(conversation)
  local context_config = require("sia.config").options.settings.context
  local exclude = context_config.exclude or {}

  --- @type { assistant_idx: integer, tool_idx: integer, tool_call_id: string }[]
  local pairs_list = {}

  -- Build a map from tool_call_id -> tool result message index
  --- @type table<string, integer>
  local tool_result_map = {}
  for i, message in ipairs(conversation.messages) do
    if message.role == "tool" and message._tool_call and message._tool_call.id then
      tool_result_map[message._tool_call.id] = i
    end
  end

  -- Find assistant messages with tool_calls and their matching tool results
  for i, message in ipairs(conversation.messages) do
    if message.role == "assistant" and message.tool_calls then
      for _, tc in ipairs(message.tool_calls) do
        if tc.id then
          local tool_idx = tool_result_map[tc.id]
          local tool_name = tc["function"] and tc["function"].name
            or tc["custom"] and tc["custom"].name
          -- Don't drop excluded tools or already-dropped ones
          if
            tool_idx
            and not vim.tbl_contains(exclude, tool_name)
            and message.status ~= "superseded"
            and message.status ~= "dropped"
          then
            table.insert(pairs_list, {
              assistant_idx = i,
              tool_idx = tool_idx,
              tool_call_id = tc.id,
            })
          end
        end
      end
    end
  end

  return pairs_list
end

--- Hard-drop the oldest tool call pairs by marking them as "dropped".
--- Unlike "outdated" (which replaces content with a pruning note),
--- "dropped" causes messages to be fully filtered from prepared output.
--- Uses incremental byte estimation to avoid calling estimate_tokens() in a loop.
--- @param conversation sia.Conversation
--- @param target_tokens integer Target token count to get below
--- @return boolean dropped Whether any messages were dropped
function M.drop_oldest_tool_calls(conversation, target_tokens)
  local droppable = find_droppable_tool_pairs(conversation)
  if #droppable == 0 then
    return false
  end

  -- Compute current tokens once, then subtract bytes as we drop messages
  local current_tokens = M.estimate_tokens(conversation)
  if current_tokens <= target_tokens then
    return false
  end

  -- Pre-compute byte costs for the raw messages that will be dropped.
  -- We use the raw Message objects (not PreparedMessage) to estimate bytes
  -- without calling prepare_messages again.
  local dropped_any = false
  for _, pair in ipairs(droppable) do
    if current_tokens <= target_tokens then
      break
    end

    local assistant_msg = conversation.messages[pair.assistant_idx]
    local tool_msg = conversation.messages[pair.tool_idx]
    local bytes_freed = 0

    if assistant_msg and assistant_msg.status ~= "dropped" then
      -- Estimate bytes for the assistant message
      if assistant_msg.tool_calls then
        for _, tc in ipairs(assistant_msg.tool_calls) do
          if tc["function"] then
            bytes_freed = bytes_freed + #(tc["function"].name or "")
            bytes_freed = bytes_freed + #(tc["function"].arguments or "")
          elseif tc["custom"] then
            bytes_freed = bytes_freed + #(tc["custom"].name or "")
            bytes_freed = bytes_freed + #(tc["custom"].input or "")
          end
        end
      end
      if assistant_msg.content then
        if type(assistant_msg.content) == "string" then
          bytes_freed = bytes_freed + #assistant_msg.content
        end
      end
      bytes_freed = bytes_freed + 40 -- overhead
      conversation:set_message_status(assistant_msg, "dropped")
      dropped_any = true
    end

    if tool_msg and tool_msg.status ~= "dropped" then
      -- Estimate bytes for the tool result message
      if tool_msg.content then
        if type(tool_msg.content) == "string" then
          bytes_freed = bytes_freed + #tool_msg.content
        elseif type(tool_msg.content) == "table" then
          for _, part in ipairs(tool_msg.content) do
            if type(part) == "string" then
              bytes_freed = bytes_freed + #part
            end
          end
        end
      end
      if tool_msg._tool_call then
        local tc = tool_msg._tool_call
        if tc["function"] then
          bytes_freed = bytes_freed + #(tc["function"].name or "")
          bytes_freed = bytes_freed + #(tc["function"].arguments or "")
        elseif tc["custom"] then
          bytes_freed = bytes_freed + #(tc["custom"].name or "")
          bytes_freed = bytes_freed + #(tc["custom"].input or "")
        end
      end
      bytes_freed = bytes_freed + 40 -- overhead
      conversation:set_message_status(tool_msg, "dropped")
      dropped_any = true
    end

    -- Convert bytes freed to estimated tokens
    current_tokens = current_tokens - math.floor(bytes_freed / 4)
  end

  if dropped_any then
    conversation:_invalidate_cache()
  end

  return dropped_any
end

--- Prune conversation if context budget is exceeded.
--- Strategy:
--- 1. If estimated tokens >= prune_threshold * context_window:
---    Hard-drop oldest tool calls until we reach target_after_prune
--- 2. If still over target after dropping all eligible tool calls:
---    Compact the oldest user+assistant messages
---
--- @param conversation sia.Conversation
--- @param opts { on_complete: fun(pruned: boolean, compacted: boolean), on_status: fun(message:string)? }
function M.prune_if_needed(conversation, opts)
  local config = require("sia.config").options.settings.context_management
  if not config then
    if opts.on_complete then
      opts.on_complete(false, false)
    end
    return
  end

  local budget = M.get_budget(conversation)
  if not budget then
    if opts.on_complete then
      opts.on_complete(false, false)
    end
    return
  end

  local prune_threshold = config.prune_threshold or 0.85
  local target_after_prune = config.target_after_prune or 0.70

  -- Not over threshold yet
  if budget.percent < prune_threshold then
    if opts.on_complete then
      opts.on_complete(false, false)
    end
    return
  end

  local target_tokens = math.floor(budget.limit * target_after_prune)

  -- Step 1: Drop oldest tool calls
  local dropped = M.drop_oldest_tool_calls(conversation, target_tokens)

  -- Check if we're now below target
  local current = M.estimate_tokens(conversation)
  if current <= target_tokens then
    if opts.on_complete then
      opts.on_complete(dropped, false)
    end
    return
  end

  local reason = string.format(
    "context window pressure: %dK/%dK tokens (%.0f%%)",
    math.floor(current / 1000),
    math.floor(budget.limit / 1000),
    budget.percent * 100
  )

  if opts.on_status then
    opts.on_status("Compacting conversation history")
  end

  compact_conversation(conversation, {
    reason = reason,
    ratio = config.compact_ratio,
    on_complete = function(content)
      if opts.on_complete then
        opts.on_complete(true, content ~= nil)
      end
    end,
  })
end

return M
