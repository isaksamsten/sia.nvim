---@diagnostic disable: undefined-global
local TEST_NS = vim.api.nvim_create_namespace("sia_test_ns")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local function contains(lines, needle)
  return vim.tbl_contains(lines, needle)
end

local function agent_conversation_stub(opts)
  opts = opts or {}
  return {
    get_cumulative_usage = function()
      return { total = opts.total_tokens or 0 }
    end,
    get_last_assistant_content = function()
      return opts.last_assistant_content
    end,
  }
end

local function make_agent(id, task, opts)
  opts = opts or {}
  return vim.tbl_extend("force", {
    id = id,
    name = opts.name or string.format("agent-%d", id),
    task = task,
    status = opts.status or "running",
    progress = opts.progress,
    view = opts.view,
    cancellable = opts.cancellable or { is_cancelled = false },
    conversation = opts.conversation or agent_conversation_stub(),
    started_at = opts.started_at,
  }, opts)
end

local function make_process(id, command, opts)
  opts = opts or {}
  local proc = {
    id = id,
    command = command,
    description = opts.description,
    kind = opts.kind or "running",
  }

  if proc.kind == "finished" then
    proc.outcome = opts.outcome or "completed"
    proc.code = opts.code or 0
  end

  return vim.tbl_extend("force", proc, opts)
end

local function make_process_runtime(processes, outputs, opts)
  opts = opts or {}
  return {
    list = function()
      return processes
    end,
    get = function(_, id)
      return vim.iter(processes):find(function(proc)
        return proc.id == id
      end)
    end,
    get_output = function(_, id)
      return outputs[id] or { stdout = "", stderr = "" }
    end,
    stop = function(_, id)
      local proc = vim.iter(processes):find(function(item)
        return item.id == id
      end)
      if not proc then
        return "not_found"
      end
      if proc.kind == "finished" then
        return "already_finished"
      end
      proc.kind = "finished"
      proc.outcome = opts.stop_outcome or "interrupted"
      proc.code = opts.stop_code or 143
      if opts.on_stop then
        opts.on_stop(proc)
      end
      return "stopped"
    end,
  }
end

local function make_agent_runtime(agents, opts)
  opts = opts or {}
  return {
    list = function()
      return agents
    end,
    stop = function(_, id)
      local agent = vim.iter(agents):find(function(item)
        return item.id == id
      end)
      if not agent then
        return false
      end
      agent.cancellable.is_cancelled = true
      agent.status = "cancelled"
      return true
    end,
    can_open = function(_, id)
      if opts.can_open then
        return opts.can_open(id)
      end
      return false
    end,
    open = function(_, id)
      if opts.open then
        return opts.open(id)
      end
      return false
    end,
  }
end

local function make_conversation(id, agents, processes, outputs, opts)
  opts = opts or {}
  return {
    id = id,
    agent_runtime = make_agent_runtime(agents, opts.agent_runtime),
    process_runtime = make_process_runtime(processes, outputs, opts.process_runtime),
  }
end

T["status ui"] = MiniTest.new_set()

T["status ui"]["renders expanded agent and running process details inline"] = function()
  package.loaded["sia.ui.status"] = nil
  package.loaded["sia.ui.list"] = nil

  local status = require("sia.ui.status")
  local agent = make_agent(1, "Inspect files\nDraft notes", {
    name = "code/review",
    progress = "Analyzing",
    started_at = 1,
  })
  local proc = make_process(2, "make test", {
    description = "Run tests",
  })
  local conv = make_conversation(101, { agent }, { proc }, {
    [2] = {
      stdout = table.concat({ "alpha", "beta", "gamma" }, "\n"),
      stderr = "warn",
    },
  })

  local _, view = status._build(conv)
  view:expand("agent", 1)
  view:expand("bash", 2)

  local lines = view:render()

  eq(true, view.has_running)
  eq(true, contains(lines, "    Task:"))
  eq(true, contains(lines, "      Inspect files"))
  eq(true, contains(lines, "      Draft notes"))
  eq(true, contains(lines, "    Command:"))
  eq(true, contains(lines, "      make test"))
  eq(true, contains(lines, "    Status: running"))
  eq(true, contains(lines, "    stdout (last 3 lines):"))
  eq(true, contains(lines, "      gamma"))
  eq(true, contains(lines, "    stderr (last 1 lines):"))
  eq(true, contains(lines, "      warn"))
  eq(true, view:has_action(1, "stop"))

  local agent_line
  for i = 1, 50 do
    local tag, item_id = view:item_at(i)
    if tag == "agent" and item_id == 1 and view:has_action(i, "cancel") then
      agent_line = i
      break
    end
  end
  eq(true, agent_line ~= nil)
end

T["status ui"]["renders running process details from runtime output"] = function()
  package.loaded["sia.ui.status"] = nil
  package.loaded["sia.ui.list"] = nil

  local status = require("sia.ui.status")
  local proc = make_process(1, "make test", {
    description = "Run tests",
  })
  local conv = make_conversation(102, {}, { proc }, {
    [1] = {
      stdout = table.concat({ "alpha", "beta", "gamma" }, "\n"),
      stderr = "warn",
    },
  })

  local _, view = status._build(conv)
  view:expand("bash", 1)
  local lines = view:render()

  eq(true, contains(lines, "    Status: running"))
  eq(true, contains(lines, "    stdout (last 3 lines):"))
  eq(true, contains(lines, "      gamma"))
  eq(true, contains(lines, "    stderr (last 1 lines):"))
  eq(true, contains(lines, "      warn"))
end

T["status ui"]["sorts mixed items newest first with aligned metadata"] = function()
  package.loaded["sia.ui.status"] = nil
  package.loaded["sia.ui.list"] = nil

  local status = require("sia.ui.status")
  local conv = make_conversation(103, {
    make_agent(1, "Inspect repository", { started_at = 1 }),
  }, {
    make_process(2, "make test", { description = "Run tests" }),
  }, {})

  local _, view = status._build(conv)
  view:render()

  local tag1, id1 = view:item_at(1)
  local tag2, id2 = view:item_at(2)

  eq("bash", tag1)
  eq(2, id1)
  eq("agent", tag2)
  eq(1, id2)
end

T["status ui"]["applies line highlights with line_hl_group"] = function()
  package.loaded["sia.ui.status"] = nil
  package.loaded["sia.ui.list"] = nil

  local status = require("sia.ui.status")
  local conv = make_conversation(104, {
    make_agent(1, "Inspect repository"),
  }, {}, {})

  local _, view = status._build(conv)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].modifiable = false
  view:apply(buf, TEST_NS)

  local marks = vim.api.nvim_buf_get_extmarks(buf, TEST_NS, 0, -1, { details = true })

  eq(true, #marks > 0)
  eq(
    true,
    vim.iter(marks):any(function(mark)
      return mark[4].line_hl_group == "SiaStatusActive"
    end)
  )
  eq(
    true,
    vim.iter(marks):any(function(mark)
      return mark[4].hl_group == "SiaStatusMuted"
    end)
  )
end

T["status ui"]["runs cancel and stop actions via trigger"] = function()
  package.loaded["sia.ui.status"] = nil
  package.loaded["sia.ui.list"] = nil

  local status = require("sia.ui.status")
  local agent = make_agent(1, "Inspect repository", {
    name = "code/review",
  })
  local stopped_proc = make_process(1, "make test", {
    description = "Run tests",
  })
  local conv = make_conversation(107, { agent }, { stopped_proc }, {
    [1] = { stdout = "done", stderr = "" },
  })

  local _, view = status._build(conv)
  view:render()

  local agent_line, bash_line
  for i = 1, 50 do
    local tag, id = view:item_at(i)
    if tag == "agent" and id == 1 then
      agent_line = agent_line or i
    elseif tag == "bash" and id == 1 then
      bash_line = bash_line or i
    end
    if agent_line and bash_line then
      break
    end
  end

  eq(true, agent_line ~= nil)
  eq(true, bash_line ~= nil)

  view:trigger(agent_line, "cancel")
  eq(true, agent.cancellable.is_cancelled)
  eq("cancelled", agent.status)

  view:trigger(bash_line, "stop")
  eq("finished", stopped_proc.kind)
  eq("interrupted", stopped_proc.outcome)
end

T["status ui"]["finds next and previous summary lines across expanded items"] = function()
  package.loaded["sia.ui.status"] = nil
  package.loaded["sia.ui.list"] = nil

  local status = require("sia.ui.status")
  local conv = make_conversation(108, {
    make_agent(1, "Inspect files\nDraft notes", { started_at = 1 }),
  }, {
    make_process(1, "make test", { description = "Run tests" }),
  }, {
    [1] = { stdout = "alpha\nbeta", stderr = "warn" },
  })

  local _, view = status._build(conv)
  view:expand("agent", 1)
  view:expand("bash", 1)
  view:render()

  local summary_lines = {}
  local seen_entries = {}
  for i = 1, 50 do
    local tag, id = view:item_at(i)
    if tag then
      local key = tag .. ":" .. id
      if not seen_entries[key] then
        seen_entries[key] = true
        table.insert(summary_lines, i)
      end
    else
      break
    end
  end

  eq(2, #summary_lines)
  local first_summary = summary_lines[1]
  local second_summary = summary_lines[2]

  eq(second_summary, view:find_item(first_summary, 1))
  eq(nil, view:find_item(first_summary, -1))

  local last_line = 1
  for i = 1, 50 do
    if view:item_at(i) then
      last_line = i
    else
      break
    end
  end

  eq(first_summary, view:find_item(last_line, -1))
  eq(nil, view:find_item(last_line, 1))
end

return T
