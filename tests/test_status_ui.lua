---@diagnostic disable: undefined-global, missing-fields

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local function contains(lines, needle)
  return vim.tbl_contains(lines, needle)
end

local function find_meta_line(line_meta, predicate)
  for i, meta in pairs(line_meta) do
    if predicate(meta) then
      return i
    end
  end
  return nil
end

T["status ui"] = MiniTest.new_set()

T["status ui"]["renders expanded agent and running process details inline"] = function()
  package.loaded["sia.ui.status"] = nil

  local Conversation = require("sia.conversation")
  local status = require("sia.ui.status")
  local conv = Conversation.new_conversation({ temporary = true })

  local agent = conv:new_agent("code/review", "Inspect files\nDraft notes")
  agent.progress = "Analyzing"

  local proc = conv:new_bash_process("make test", "Run tests")
  proc.detached_handle = {
    get_output = function()
      return {
        stdout = table.concat({ "alpha", "beta", "gamma" }, "\n"),
        stderr = "warn",
      }
    end,
    is_done = function()
      return false
    end,
    kill = function() end,
  }

  local lines, _, line_meta, has_running = status._render_snapshot(conv, {
    expanded = {
      ["agent:1"] = true,
      ["bash:1"] = true,
    },
    spinner_frame = 2,
  })

  eq(true, has_running)
  eq(true, contains(lines, "    Task:"))
  eq(true, contains(lines, "      Inspect files"))
  eq(true, contains(lines, "      Draft notes"))
  eq(true, contains(lines, "    Command:"))
  eq(true, contains(lines, "      make test"))
  eq(true, contains(lines, "    stdout (last 3 lines):"))
  eq(true, contains(lines, "      gamma"))
  eq(true, contains(lines, "    stderr (last 1 lines):"))
  eq(true, contains(lines, "      warn"))
  eq("stop", line_meta[1].action)
  eq(
    "cancel",
    line_meta[find_meta_line(line_meta, function(meta)
      return meta and meta.kind == "agent" and meta.id == agent.id
    end)].action
  )
end

T["status ui"]["sorts mixed items newest first with aligned metadata"] = function()
  package.loaded["sia.ui.status"] = nil

  local Conversation = require("sia.conversation")
  local status = require("sia.ui.status")
  local conv = Conversation.new_conversation({ temporary = true })

  local agent = conv:new_agent("code/review", "Inspect repository")
  local proc = conv:new_bash_process("make test", "Run tests")

  local _, _, line_meta = status._render_snapshot(conv, {
    expanded = {},
    spinner_frame = 1,
  })

  eq(proc.id, line_meta[1].id)
  eq("bash", line_meta[1].kind)
  eq(agent.id, line_meta[2].id)
  eq("agent", line_meta[2].kind)
end

T["status ui"]["applies line highlights with line_hl_group"] = function()
  package.loaded["sia.ui.status"] = nil

  local Conversation = require("sia.conversation")
  local status = require("sia.ui.status")
  local conv = Conversation.new_conversation({ temporary = true })

  conv:new_agent("code/review", "Inspect repository")

  local state = {
    conversation = conv,
    buf = vim.api.nvim_create_buf(false, true),
    expanded = {},
    line_meta = {},
    spinner_frame = 1,
    has_running = false,
  }

  vim.bo[state.buf].modifiable = false
  status._apply_to_state(state)

  local marks = vim.api.nvim_buf_get_extmarks(
    state.buf,
    vim.api.nvim_create_namespace("sia_status_ui"),
    0,
    -1,
    { details = true }
  )

  eq(true, #marks > 0)
  eq("SiaStatusActive", marks[1][4].line_hl_group)
  eq(
    true,
    vim.iter(marks):any(function(mark)
      return mark[4].hl_group == "SiaStatusTag"
    end)
  )
end

T["status ui"]["renders completed process output paths and tail lines"] = function()
  package.loaded["sia.ui.status"] = nil

  local Conversation = require("sia.conversation")
  local status = require("sia.ui.status")
  local conv = Conversation.new_conversation({ temporary = true })

  local proc = conv:new_bash_process("make test", "Run tests")
  proc.detached_handle = {
    get_output = function()
      return {
        stdout = table.concat({ "alpha", "beta" }, "\n"),
        stderr = "warn",
      }
    end,
    is_done = function()
      return false
    end,
    kill = function() end,
  }

  local _, err = proc:stop()
  eq(nil, err)

  local lines = status._render_snapshot(conv, {
    expanded = { ["bash:1"] = true },
    spinner_frame = 1,
  })

  -- eq(true, contains(lines, "    Status: stopped"))
  eq(true, contains(lines, "    Exit code: 143"))
  eq(true, contains(lines, "    stdout file: " .. proc.stdout_file))
  eq(true, contains(lines, "    stderr file: " .. proc.stderr_file))
  eq(true, contains(lines, "    stdout (last 2 lines):"))
  eq(true, contains(lines, "      beta"))
  eq(true, contains(lines, "      warn"))
end

T["status ui"]["applies detail highlights for file paths"] = function()
  package.loaded["sia.ui.status"] = nil

  local Conversation = require("sia.conversation")
  local status = require("sia.ui.status")
  local conv = Conversation.new_conversation({ temporary = true })

  local proc = conv:new_bash_process("make test", "Run tests")
  proc.detached_handle = {
    get_output = function()
      return { stdout = "done", stderr = "" }
    end,
    is_done = function()
      return false
    end,
    kill = function() end,
  }

  local _, err = proc:stop()
  eq(nil, err)

  local state = {
    conversation = conv,
    buf = vim.api.nvim_create_buf(false, true),
    expanded = { ["bash:1"] = true },
    line_meta = {},
    spinner_frame = 1,
    has_running = false,
  }

  vim.bo[state.buf].modifiable = false
  status._apply_to_state(state)

  local marks = vim.api.nvim_buf_get_extmarks(
    state.buf,
    vim.api.nvim_create_namespace("sia_status_ui"),
    0,
    -1,
    { details = true }
  )

  eq(
    true,
    vim.iter(marks):any(function(mark)
      return mark[4].hl_group == "SiaStatusPath"
    end)
  )
end

T["status ui"]["runs cancel and stop actions from line metadata"] = function()
  package.loaded["sia.ui.status"] = nil

  local Conversation = require("sia.conversation")
  local status = require("sia.ui.status")
  local conv = Conversation.new_conversation({ temporary = true })

  local agent = conv:new_agent("code/review", "Inspect repository")
  local proc = conv:new_bash_process("make test", "Run tests")
  local killed = false

  proc.detached_handle = {
    get_output = function()
      return { stdout = "done", stderr = "" }
    end,
    is_done = function()
      return false
    end,
    kill = function()
      killed = true
    end,
  }

  local agent_message, agent_err = status._run_action(conv, {
    kind = "agent",
    id = agent.id,
    action = "cancel",
  })
  eq(nil, agent_err)
  eq("Cancellation requested for agent 1.", agent_message)
  eq(true, agent.cancellable.is_cancelled)

  local proc_message, proc_err = status._run_action(conv, {
    kind = "bash",
    id = proc.id,
    action = "stop",
  })
  eq(nil, proc_err)
  eq("Process 1 terminated.", proc_message)
  eq(true, killed)
  eq(true, proc.interrupted)
end

T["status ui"]["finds next and previous summary lines across expanded items"] = function()
  package.loaded["sia.ui.status"] = nil

  local Conversation = require("sia.conversation")
  local status = require("sia.ui.status")
  local conv = Conversation.new_conversation({ temporary = true })

  conv:new_agent("code/review", "Inspect files\nDraft notes")
  local proc = conv:new_bash_process("make test", "Run tests")
  proc.detached_handle = {
    get_output = function()
      return { stdout = "alpha\nbeta", stderr = "warn" }
    end,
    is_done = function()
      return false
    end,
    kill = function() end,
  }

  local state = {
    conversation = conv,
    buf = vim.api.nvim_create_buf(false, true),
    expanded = {
      ["agent:1"] = true,
      ["bash:1"] = true,
    },
    line_meta = {},
    spinner_frame = 1,
    has_running = false,
  }

  vim.bo[state.buf].modifiable = false
  status._apply_to_state(state)

  eq(7, status._find_item_line(state, 1, 1))
  eq(nil, status._find_item_line(state, 1, -1))
  eq(1, status._find_item_line(state, 8, -1))
  eq(nil, status._find_item_line(state, 8, 1))
end

return T
