local M = {}

--- @class sia.engine.ToolCall
--- @field key string?
--- @field index integer
--- @field tool_call sia.ToolCall
--- @field name string?
--- @field args any
--- @field summary sia.ToolSummary?
--- @field parallel boolean
--- @field error string?

--- @class sia.engine.Status
--- @field key string
--- @field index integer
--- @field name string?
--- @field summary sia.ToolSummary?
--- @field status "pending"|"running"|"done"
--- @field actions table<string, boolean>?

--- @class sia.engine.Entry
--- @field tool sia.engine.ToolCall
--- @field result sia.ToolResult

--- @class sia.engine.ExecuteOpts
--- @field cancellable sia.Cancellable?
--- @field turn_id string
--- @field on_status fun(statuses: sia.engine.Status[])?
--- @field on_complete fun(results: sia.engine.Entry[], status: sia.engine.Status[])

--- @param tool_call sia.ToolCall
--- @param index integer
--- @param conversation sia.Conversation
--- @return sia.engine.ToolCall
local function parse_tool_call(tool_call, index, conversation)
  --- @type sia.engine.ToolCall
  local parsed = {
    key = tool_call.key,
    index = index,
    tool_call = tool_call,
    name = nil,
    args = nil,
    summary = nil,
    parallel = false,
    error = nil,
  }

  if tool_call.type == "custom" then
    parsed.name = tool_call.name
    parsed.args = tool_call.input
    local implementation = conversation.tool_implementation[tool_call.name]
    if implementation then
      parsed.summary = implementation.summary(parsed.args)
      parsed.parallel = implementation.allow_parallel ~= nil
        and implementation.allow_parallel(parsed.args, conversation)
    end
  elseif tool_call.type == "function" then
    parsed.name = tool_call.name
    local is_arguments_parsed, args
    if tool_call.arguments and tool_call.arguments:match("%S") then
      is_arguments_parsed, args = pcall(vim.fn.json_decode, tool_call.arguments)
    else
      is_arguments_parsed, args = true, {}
    end
    if is_arguments_parsed then
      parsed.args = args
      local implementation = conversation.tool_implementation[tool_call.name]
      if implementation then
        parsed.summary = implementation.summary(args)
        parsed.parallel = implementation.allow_parallel ~= nil
          and implementation.allow_parallel(args, conversation)
      end
    else
      parsed.error = "Could not parse tool arguments"
    end
  else
    parsed.error = "Unknown tool type"
  end

  return parsed
end

--- Execute tool calls: parse, partition, run parallel/sequential, collect results.
--- @param tool_calls sia.ToolCall[]
--- @param conversation sia.Conversation
--- @param opts sia.engine.ExecuteOpts
function M.execute_tools(tool_calls, conversation, opts)
  if #tool_calls == 0 then
    opts.on_complete({}, {})
    return
  end

  --- @type sia.engine.ToolCall[]
  local parallel_tools = {}
  --- @type sia.engine.ToolCall[]
  local sequential_tools = {}
  --- @type sia.engine.Status[]
  local all_statuses = {}
  --- @type sia.engine.Entry[]
  local tool_results = {}

  for i, tool_call in ipairs(tool_calls) do
    local parsed = parse_tool_call(tool_call, i, conversation)
    all_statuses[i] = {
      key = parsed.key,
      index = parsed.index,
      name = parsed.name,
      summary = parsed.summary,
      status = "pending",
    }
    tool_results[i] = nil

    if parsed.error then
      table.insert(sequential_tools, parsed)
    elseif parsed.parallel then
      table.insert(parallel_tools, parsed)
    else
      table.insert(sequential_tools, parsed)
    end
  end

  if opts.on_status then
    opts.on_status(all_statuses)
  end

  local total_tools = #sequential_tools + #parallel_tools
  local completed_count = 0

  --- @param idx integer
  --- @param status "pending"|"running"|"done"
  local function update_status(idx, status)
    all_statuses[idx].status = status
    if opts.on_status then
      opts.on_status(all_statuses)
    end
  end

  --- @param parsed sia.engine.ToolCall
  --- @param result sia.ToolResult
  local function on_tool_finished(parsed, result)
    if result.summary == nil then
      result.summary = parsed.summary
    end
    completed_count = completed_count + 1
    update_status(parsed.index, "done")
    tool_results[parsed.index] = { tool = parsed, result = result }

    if completed_count == total_tools then
      --- @type sia.engine.Entry[]
      local ordered_results = {}
      --- @type sia.engine.Status[]
      local statuses = {}
      for i = 1, #tool_calls do
        if tool_results[i] then
          table.insert(ordered_results, tool_results[i])
          --- @type table<string, boolean>
          local actions = {}
          local result_actions = tool_results[i].result.actions
          if result_actions then
            for _, action in ipairs(result_actions) do
              actions[action.type] = true
            end
          end
          table.insert(statuses, {
            key = tool_results[i].tool.key,
            index = tool_results[i].tool.index,
            name = tool_results[i].tool.name,
            summary = tool_results[i].result.summary,
            status = "done",
            actions = actions,
          } --[[@as sia.engine.Status]])
        end
      end
      opts.on_complete(ordered_results, statuses)
    end
  end

  --- Execute a single parsed tool call.
  --- @param parsed sia.engine.ToolCall
  --- @param execute_next fun()?
  local function execute_one(parsed, execute_next)
    update_status(parsed.index, "running")

    if parsed.error then
      if parsed.tool_call.type == "function" then
        parsed.tool_call.arguments = "{}"
      end
      on_tool_finished(parsed, { content = parsed.error, ephemeral = true })
      if execute_next then
        execute_next()
      end
      return
    end

    if parsed.name and parsed.args then
      conversation:execute_tool(parsed.name, parsed.args, {
        cancellable = opts.cancellable,
        turn_id = opts.turn_id,
        callback = vim.schedule_wrap(function(tool_result)
          if not tool_result then
            tool_result = { content = "Could not find tool...", ephemeral = true }
          end
          on_tool_finished(parsed, tool_result)
          if execute_next then
            execute_next()
          end
        end),
      })
    elseif not parsed.name then
      on_tool_finished(parsed, {
        content = "Tool is not a function. Try without parallel tool calls.",
        ephemeral = true,
      })
      if execute_next then
        execute_next()
      end
    else
      on_tool_finished(parsed, { content = "Could not find tool...", ephemeral = true })
      if execute_next then
        execute_next()
      end
    end
  end

  for _, tool in ipairs(parallel_tools) do
    vim.schedule(function()
      execute_one(tool)
    end)
  end

  local seq_index = 1
  local function execute_next()
    if seq_index > #sequential_tools then
      return
    end
    local tool = sequential_tools[seq_index]
    seq_index = seq_index + 1
    execute_one(tool, execute_next)
  end

  if #sequential_tools > 0 then
    execute_next()
  end
end

return M
