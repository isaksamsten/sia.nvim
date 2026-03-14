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

  if msg.content and type(msg.content) == "string" and msg.content ~= "" then
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
--- @param opts { ratio: number?, on_complete: fun(content: string?)? }
local compact_conversation = function(conversation, opts)
  opts = opts or {}
  local model =
    require("sia.model").resolve(require("sia.config").options.settings.fast_model)
  local new_conversation = require("sia.conversation").new_conversation({
    model = model,
    temporary = true,
  })
  new_conversation:add_instruction({
    role = "system",
    content = [[Provide a detailed prompt for continuing our conversation above.
Focus on information that would be helpful for continuing the conversation, including
what we did, what we're doing, which files we're working on, and what we're going to do
next. The summary that you construct will be used so that another agent can read it and
continue the work.

When constructing the summary, try to stick to this template:

---
## Goal

[What goal(s) is the user trying to accomplish?]

## Instructions

- [What important instructions did the user give you that are relevant]
- [If there is a plan or spec, include information about it so next agent can continue using it]

## Discoveries

[What notable things were learned during this conversation that would be useful for the next agent to know when continuing the work]

## Accomplished

[What work has been completed, what work is still in progress, and what work is left?]

## Relevant files / directories

[Construct a structured list of relevant files that have been read, edited, or created
that pertain to the task at hand. If all the files in a directory are relevant, include
the path to the directory.]
]],
  })

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
    new_conversation:add_instruction(normalize_for_summary(m))
  end

  for i = 1, compact_count do
    local msg = non_system[i].message
    new_conversation:add_instruction(normalize_for_summary(msg))
  end

  require("sia.assistant").fetch_response(new_conversation, function(content)
    if content then
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

      conversation:add_instruction({
        role = "user",
        hide = true,
        content = content,
        meta = {
          compaction = true,
        },
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

  if message.content then
    if type(message.content) == "string" then
      bytes = bytes + #message.content
    elseif type(message.content) == "table" then
      for _, part in ipairs(message.content) do
        if part.text then
          bytes = bytes + #part.text
        end
      end
    end
  end

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
  local context_window = model.params.context_window
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

  --- @type table<string, integer>
  local tool_result_map = {}
  for i, message in ipairs(conversation.messages) do
    if message.role == "tool" and message._tool_call and message._tool_call.id then
      tool_result_map[message._tool_call.id] = i
    end
  end

  for i, message in ipairs(conversation.messages) do
    if message.role == "assistant" and message.tool_calls then
      for _, tc in ipairs(message.tool_calls) do
        if tc.id then
          local tool_idx = tool_result_map[tc.id]
          local tool_name = tc["function"] and tc["function"].name
            or tc["custom"] and tc["custom"].name
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

  local current_tokens = M.estimate_tokens(conversation)
  if current_tokens <= target_tokens then
    return false
  end

  local dropped_any = false
  for _, pair in ipairs(droppable) do
    if current_tokens <= target_tokens then
      break
    end

    local assistant_msg = conversation.messages[pair.assistant_idx]
    local tool_msg = conversation.messages[pair.tool_idx]
    local bytes_freed = 0

    if assistant_msg and assistant_msg.status ~= "dropped" then
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
      bytes_freed = bytes_freed + 40
      conversation:set_message_status(assistant_msg, "dropped")
      dropped_any = true
    end

    if tool_msg and tool_msg.status ~= "dropped" then
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
      bytes_freed = bytes_freed + 40
      conversation:set_message_status(tool_msg, "dropped")
      dropped_any = true
    end

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

  if opts.on_status then
    opts.on_status("Compacting conversation history")
  end

  compact_conversation(conversation, {
    ratio = config.compact_ratio,
    on_complete = function(content)
      if opts.on_complete then
        opts.on_complete(true, content ~= nil)
      end
    end,
  })
end

return M
