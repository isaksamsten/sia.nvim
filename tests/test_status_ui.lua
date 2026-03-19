---@diagnostic disable: undefined-global, missing-fields
local TEST_NS = vim.api.nvim_create_namespace("sia_test_ns")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local function contains(lines, needle)
  return vim.tbl_contains(lines, needle)
end

T["status ui"] = MiniTest.new_set()

T["status ui"]["renders expanded agent and running process details inline"] = function()
  package.loaded["sia.ui.status"] = nil
  package.loaded["sia.ui.list"] = nil

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

  local model, view = status._build(conv)
  view:expand("agent", 1)
  view:expand("bash", 1)
  view.spinner_frame = 2

  local lines = view:render()

  eq(true, view.has_running)
  eq(true, contains(lines, "    Task:"))
  eq(true, contains(lines, "      Inspect files"))
  eq(true, contains(lines, "      Draft notes"))
  eq(true, contains(lines, "    Command:"))
  eq(true, contains(lines, "      make test"))
  eq(true, contains(lines, "    stdout (last 3 lines):"))
  eq(true, contains(lines, "      gamma"))
  eq(true, contains(lines, "    stderr (last 1 lines):"))
  eq(true, contains(lines, "      warn"))

  -- First item (newest) should be the bash process (has stop action)
  eq(true, view:has_action(1, "stop"))
  -- Find the agent summary line
  local agent_line
  for i = 1, 50 do
    local tag, id = view:item_at(i)
    if tag == "agent" and id == 1 and view:has_action(i, "cancel") then
      agent_line = i
      break
    end
  end
  eq(true, agent_line ~= nil)
end

T["status ui"]["sorts mixed items newest first with aligned metadata"] = function()
  package.loaded["sia.ui.status"] = nil
  package.loaded["sia.ui.list"] = nil

  local Conversation = require("sia.conversation")
  local status = require("sia.ui.status")
  local conv = Conversation.new_conversation({ temporary = true })

  conv:new_agent("code/review", "Inspect repository")
  vim.uv.sleep(10)
  conv:new_bash_process("make test", "Run tests")

  local model, view = status._build(conv)
  view:render()

  -- Newest first: proc was created after agent
  local tag1, id1 = view:item_at(1)
  local tag2, id2 = view:item_at(2)

  eq("bash", tag1)
  eq(1, id1)
  eq("agent", tag2)
  eq(1, id2)
end

T["status ui"]["applies line highlights with line_hl_group"] = function()
  package.loaded["sia.ui.status"] = nil
  package.loaded["sia.ui.list"] = nil

  local Conversation = require("sia.conversation")
  local status = require("sia.ui.status")
  local conv = Conversation.new_conversation({ temporary = true })

  conv:new_agent("code/review", "Inspect repository")

  local model, view = status._build(conv)
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

T["status ui"]["renders completed process output paths and tail lines"] = function()
  package.loaded["sia.ui.status"] = nil
  package.loaded["sia.ui.list"] = nil

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

  local model, view = status._build(conv)
  view:expand("bash", 1)
  local lines = view:render()

  eq(true, contains(lines, "    Exit code: 143"))
  eq(true, contains(lines, "    stdout file: " .. proc.stdout_file))
  eq(true, contains(lines, "    stderr file: " .. proc.stderr_file))
  eq(true, contains(lines, "    stdout (last 2 lines):"))
  eq(true, contains(lines, "      beta"))
  eq(true, contains(lines, "      warn"))
end

T["status ui"]["applies detail highlights for file paths"] = function()
  package.loaded["sia.ui.status"] = nil
  package.loaded["sia.ui.list"] = nil

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

  local model, view = status._build(conv)
  view:expand("bash", 1)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].modifiable = false
  view:apply(buf, TEST_NS)

  local marks = vim.api.nvim_buf_get_extmarks(buf, TEST_NS, 0, -1, { details = true })

  eq(
    true,
    vim.iter(marks):any(function(mark)
      return mark[4].hl_group == "SiaStatusPath"
    end)
  )
end

T["status ui"]["runs cancel and stop actions via trigger"] = function()
  package.loaded["sia.ui.status"] = nil
  package.loaded["sia.ui.list"] = nil

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

  local model, view = status._build(conv)
  view:render() -- build line mappings

  -- Find agent and bash summary lines
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

  -- Cancel agent
  view:trigger(agent_line, "cancel")
  eq(true, agent.cancellable.is_cancelled)

  -- Stop process
  view:trigger(bash_line, "stop")
  eq(true, killed)
  eq(true, proc.interrupted)
end

T["status ui"]["finds next and previous summary lines across expanded items"] = function()
  package.loaded["sia.ui.status"] = nil
  package.loaded["sia.ui.list"] = nil

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

  local model, view = status._build(conv)
  view:expand("agent", 1)
  view:expand("bash", 1)
  view:render()

  -- Find the two summary lines by scanning for different entries
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

  -- From first summary, next goes to second
  eq(second_summary, view:find_item(first_summary, 1))
  -- From first summary, prev finds nothing
  eq(nil, view:find_item(first_summary, -1))
  -- From last rendered line, prev goes to first
  -- (find the last line with content)
  local last_line = 1
  for i = 1, 50 do
    if view:item_at(i) then
      last_line = i
    else
      break
    end
  end
  eq(first_summary, view:find_item(last_line, -1))
  -- From last line, next finds nothing
  eq(nil, view:find_item(last_line, 1))
end

return T
