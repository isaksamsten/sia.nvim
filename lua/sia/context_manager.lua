local M = {}

local function get_context_config()
  return require("sia.config").options.settings.context or {}
end

--- @param entry sia.Entry
--- @return { role: "user"|"assistant", content: string }
local function normalize_for_summary(entry)
  local parts = {}

  local content = entry.content
  if content then
    if type(content) == "string" then
      if content ~= "" then
        table.insert(parts, content)
      end
    elseif type(content) == "table" then
      for _, part in ipairs(content) do
        if part.text and part.text ~= "" then
          table.insert(parts, part.text)
        end
      end
    end
  end

  local reasoning = entry.reasoning
  if entry.role == "assistant" and reasoning then
    if reasoning.text and reasoning.text ~= "" then
      table.insert(parts, string.format("[Reasoning: %s]", reasoning.text))
    end
  end

  if entry.role == "tool" then
    local tc = entry.tool_call
    if tc then
      local name = tc.name or ""
      local args = tc.type == "function" and tc.arguments or tc.input or ""
      table.insert(parts, 1, string.format("[Tool call: %s(%s)]", name, args))
      table.insert(parts, string.format("[Tool result: %s]", name))
    end
  end

  local role = entry.role
  if role == "tool" or role == "system" then
    role = "user"
  end

  return {
    role = role,
    content = table.concat(parts, "\n"),
  }
end

--- @param conversation sia.Conversation
--- @param msg { role: "user"|"assistant", content: string }
local function add_summary_message(conversation, msg)
  if msg.role == "assistant" then
    conversation:add_assistant_message(tostring(math.random(1e9)), msg.content)
  else
    conversation:add_user_message(msg.content)
  end
end

--- @param part sia.MultiPart
--- @return integer bytes
local function media_part_bytes(part)
  if part.type == "image" and part.image and type(part.image.url) == "string" then
    return #part.image.url
  end
  if part.type == "file" and part.file and type(part.file.file_data) == "string" then
    return #part.file.file_data
  end
  return 0
end

--- Compact a conversation by summarizing previous entries
--- @param conversation sia.Conversation The conversation object to compact
--- @param opts { oldest_fraction: number?, on_complete: fun(content: string?)? }
local compact_conversation = function(conversation, opts)
  opts = opts or {}
  local model =
    require("sia.model").resolve(require("sia.config").options.settings.fast_model)
  local new_conversation = require("sia.conversation").new({
    model = model,
    temporary = true,
  })
  new_conversation:add_system_message(
    [[Provide a detailed prompt for continuing our conversation above.
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
]]
  )

  --- @type sia.Entry[]
  local dropped_entries = {}
  for _, entry in ipairs(conversation.entries) do
    if entry.dropped and entry.role ~= "system" then
      if entry.role == "tool" or entry.content or entry.reasoning then
        table.insert(dropped_entries, entry)
      end
    end
  end

  --- @type {index: integer, entry: sia.Entry}[]
  local non_system = {}
  for i, entry in ipairs(conversation.entries) do
    if entry.role ~= "system" and not entry.dropped then
      table.insert(non_system, { index = i, entry = entry })
    end
  end

  local compact_count = #non_system
  if opts.oldest_fraction and opts.oldest_fraction > 0 and opts.oldest_fraction < 1 then
    compact_count = math.max(1, math.floor(#non_system * opts.oldest_fraction))
  end

  for _, entry in ipairs(dropped_entries) do
    add_summary_message(new_conversation, normalize_for_summary(entry))
  end

  for i = 1, compact_count do
    local entry = non_system[i].entry
    add_summary_message(new_conversation, normalize_for_summary(entry))
  end

  require("sia.assistant").fetch_response(new_conversation, function(content)
    if content then
      local dropped = 0
      for _, entry in ipairs(conversation.entries) do
        if entry.role ~= "system" and not entry.dropped then
          entry.dropped = true
          dropped = dropped + 1
          if dropped >= compact_count then
            break
          end
        end
      end

      local summarized_set = {}
      for _, entry in ipairs(dropped_entries) do
        summarized_set[entry.id] = true
      end
      for i = 1, compact_count do
        summarized_set[non_system[i].entry.id] = true
      end

      conversation.entries = vim
        .iter(conversation.entries)
        --- @param entry sia.Entry
        :filter(function(entry)
          return not summarized_set[entry.id]
        end)
        :totable()

      conversation:add_user_message(content, nil, { hide = true })
      if opts.on_complete then
        opts.on_complete(content)
      end
    elseif opts.on_complete then
      opts.on_complete(nil)
    end
  end)
end

--- Estimate the number of bytes in an entry.
--- @param entry sia.Entry
--- @return integer bytes
local function entry_bytes(entry)
  local bytes = 0

  if entry.content then
    local content = entry.content
    if type(content) == "string" then
      bytes = bytes + #content
    elseif type(content) == "table" then
      for _, part in ipairs(content) do
        if part.text then
          bytes = bytes + #part.text
        end
      end
    end
  end

  local reasoning = entry.reasoning
  if entry.role == "assistant" and reasoning then
    if reasoning.text then
      bytes = bytes + #reasoning.text
    end
  end

  if entry.role == "tool" then
    local tc = entry.tool_call
    if tc then
      bytes = bytes + #(tc.name or "")
      if tc.type == "function" then
        bytes = bytes + #(tc.arguments or "")
      elseif tc.type == "custom" then
        bytes = bytes + #(tc.input or "")
      end
    end
  end

  bytes = bytes + 40

  return bytes
end

--- @param conversation sia.Conversation
--- @return { entry: sia.Entry, part_index: integer, kind: "image"|"document", bytes: integer }[], integer
local function collect_media_parts(conversation)
  local parts = {}
  local total_bytes = 0

  for _, entry in ipairs(conversation.entries) do
    if not entry.dropped and type(entry.content) == "table" then
      for part_index, part in ipairs(entry.content) do
        local bytes = media_part_bytes(part)
        if bytes > 0 then
          total_bytes = total_bytes + bytes
          table.insert(parts, {
            entry = entry,
            part_index = part_index,
            kind = part.type == "file" and "document" or "image",
            bytes = bytes,
          })
        end
      end
    end
  end

  return parts, total_bytes
end

--- Replace old base64-heavy image/document parts with small text placeholders.
--- @param conversation sia.Conversation
--- @param max_bytes integer
--- @param keep_last integer
--- @return integer pruned_count
function M.prune_oldest_media(conversation, max_bytes, keep_last)
  if max_bytes <= 0 then
    return 0
  end
  keep_last = math.max(0, keep_last or 0)

  local media_parts, total_bytes = collect_media_parts(conversation)
  local prunable_count = math.max(0, #media_parts - keep_last)
  if total_bytes <= max_bytes or prunable_count == 0 then
    return 0
  end

  local pruned = 0
  for i = 1, prunable_count do
    if total_bytes <= max_bytes then
      break
    end

    local item = media_parts[i]
    local content = item.entry.content
    if type(content) == "table" then
      content[item.part_index] = {
        type = "text",
        text = string.format(
          "[Pruned older %s content from context to reduce request size.]",
          item.kind
        ),
      }
      total_bytes = total_bytes - item.bytes
      pruned = pruned + 1
    end
  end

  return pruned
end

--- Estimate the number of bytes in tool definitions.
--- Cached on the conversation since tools don't change during its lifetime.
--- @param conversation sia.Conversation
--- @return integer bytes
local function tool_definition_bytes(conversation)
  local bytes = 0
  if conversation.tool_definitions then
    for _, tool in ipairs(conversation.tool_definitions) do
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
  return bytes
end

--- Estimate the token count for a conversation's entries.
--- Uses the heuristic: tokens ≈ bytes / 4
--- @param conversation sia.Conversation
--- @return integer estimated_tokens
function M.estimate_tokens(conversation)
  local total_bytes = 0
  for _, entry in ipairs(conversation.entries) do
    if not entry.dropped then
      total_bytes = total_bytes + entry_bytes(entry)
    end
  end
  total_bytes = total_bytes + tool_definition_bytes(conversation)
  return math.floor(total_bytes / 4)
end

--- Get the context window budget information for a conversation.
--- @param conversation sia.Conversation
--- @return { estimated: integer, limit: integer, percent: number }?
function M.get_token_estimate(conversation)
  local model = conversation.model
  if not model then
    return nil
  end
  local context_window = model.context_window
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

--- Find tool entries that can be dropped.
--- Tool entries are self-contained: they store both the tool call metadata
--- and the result content in a single entry.
--- @param conversation sia.Conversation
--- @return { index: integer, entry: sia.ToolEntry }[]
local function find_droppable_tool_entries(conversation)
  local context_config = get_context_config()
  local preserve = context_config.tools and context_config.tools.preserve or {}

  --- @type { index: integer, entry: sia.ToolEntry }[]
  local result = {}

  for i, entry in ipairs(conversation.entries) do
    if
      entry.role == "tool"
      and entry.tool_call
      and not entry.dropped
      and not vim.tbl_contains(preserve, entry.tool_call.name)
    then
      table.insert(result, { index = i, entry = entry })
    end
  end

  return result
end

--- Hard-drop the oldest tool entries by marking them as "dropped".
--- Unlike "outdated" (which replaces content with a pruning note),
--- "dropped" causes entries to be fully filtered from prepared output.
--- Uses incremental byte estimation to avoid calling estimate_tokens() in a loop.
--- @param conversation sia.Conversation
--- @param target_tokens integer Target token count to get below
--- @return boolean dropped Whether any entries were dropped
function M.drop_oldest_tool_calls(conversation, target_tokens)
  local droppable = find_droppable_tool_entries(conversation)
  if #droppable == 0 then
    return false
  end

  local current_tokens = M.estimate_tokens(conversation)
  if current_tokens <= target_tokens then
    return false
  end

  local dropped_any = false
  for _, item in ipairs(droppable) do
    if current_tokens <= target_tokens then
      break
    end

    local entry = item.entry
    local bytes_freed = entry_bytes(entry)
    entry.dropped = true
    dropped_any = true

    current_tokens = current_tokens - math.floor(bytes_freed / 4)
  end

  return dropped_any
end

--- Prune conversation if context budget is exceeded.
--- Strategy:
--- 1. If estimated tokens >= prune_threshold * context_window:
---    Hard-drop oldest tool entries until we reach target_after_prune
--- 2. If still over target after dropping all eligible tool entries:
---    Compact the oldest user+assistant entries
---
--- @param conversation sia.Conversation
--- @param opts { on_complete: fun(pruned: boolean, compacted: boolean), on_status: fun(message:string)? }
function M.ensure_token_budget(conversation, opts)
  local config = get_context_config().tokens
  if not config then
    if opts.on_complete then
      opts.on_complete(false, false)
    end
    return
  end

  local budget = M.get_token_estimate(conversation)
  if not budget then
    if opts.on_complete then
      opts.on_complete(false, false)
    end
    return
  end

  local prune_config = config.prune or {}
  local prune_threshold = prune_config.at_fraction or 0.85
  local target_after_prune = prune_config.to_fraction or 0.70
  local media_config = config.media or {}
  local media_pruned = 0
  if media_config.max_bytes then
    media_pruned = M.prune_oldest_media(
      conversation,
      media_config.max_bytes,
      media_config.keep_last or 1
    )
  end

  -- Not over threshold yet
  if budget.percent < prune_threshold then
    if opts.on_complete then
      opts.on_complete(media_pruned > 0, false)
    end
    return
  end

  local target_tokens = math.floor(budget.limit * target_after_prune)

  if opts.on_status then
    opts.on_status(
      string.format("Pruning context (%d%%)", math.floor(budget.percent * 100))
    )
  end

  local dropped = M.drop_oldest_tool_calls(conversation, target_tokens)
  local current = M.estimate_tokens(conversation)

  if current <= target_tokens then
    if opts.on_complete then
      opts.on_complete(dropped, false)
    end
    return
  end

  if opts.on_status then
    opts.on_status("Compacting history…")
  end

  compact_conversation(conversation, {
    oldest_fraction = config.compact and config.compact.oldest_fraction,
    on_complete = function(content)
      if content and opts.on_status then
        local common = require("sia.provider.common")
        opts.on_status(
          string.format(
            "Compacted to %s",
            common.format_token_count(M.estimate_tokens(conversation))
          )
        )
      end
      if opts.on_complete then
        opts.on_complete(true, content ~= nil)
      end
    end,
  })
end

return M
