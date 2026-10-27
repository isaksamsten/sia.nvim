local M = {}

local function directory()
  return vim.fs.joinpath(vim.fn.stdpath("data"), "sia", "conversations")
end

local function path_for(id)
  if type(id) ~= "string" or not id:match("^[%w_-]+$") then
    error("Invalid conversation ID")
  end
  return vim.fs.joinpath(directory(), id .. ".json")
end

--- @param summary sia.ToolSummary?
local function stored_summary(summary)
  if type(summary) ~= "table" then
    return summary
  end
  return { header = summary.header, detail = summary.detail }
end

--- @param conversation sia.Conversation
--- @return table
function M.snapshot(conversation)
  local messages = {}
  for _, message in ipairs(conversation:serialize({ read_only = true })) do
    if message.content ~= nil or message.tool_call ~= nil then
      messages[#messages + 1] = vim.deepcopy({
        role = message.role,
        content = message.content,
        tool_call = message.tool_call,
        hide = message.hide,
        summary = stored_summary(message.summary),
      })
    end
  end
  return {
    format = "sia.conversation",
    version = 1,
    id = conversation.uuid,
    title = conversation.name,
    workspace = conversation.workspace,
    model = conversation.model and conversation.model.name,
    created_at = conversation.created_at,
    updated_at = os.time(),
    messages = messages,
  }
end

--- @param conversation sia.Conversation
--- @return boolean ok
--- @return string? error
function M.save(conversation)
  if conversation.temporary then
    return true
  end
  local temporary
  local ok, err = pcall(function()
    local snapshot = M.snapshot(conversation)
    local encoded = vim.json.encode(snapshot)
    vim.fn.mkdir(directory(), "p", 448) -- 0700
    local path = path_for(snapshot.id)
    temporary = path .. "." .. require("sia.utils").new_uuid() .. ".tmp"
    local fd = assert(vim.uv.fs_open(temporary, "wx", 384)) -- 0600
    local written, write_err = vim.uv.fs_write(fd, encoded, 0)
    local closed, close_err = vim.uv.fs_close(fd)
    assert(written == #encoded, write_err or "Incomplete conversation write")
    assert(closed, close_err)
    assert(vim.uv.fs_rename(temporary, path))
  end)
  if not ok then
    if temporary then
      vim.uv.fs_unlink(temporary)
    end
    return false, tostring(err)
  end
  return true
end

--- @param id string
--- @return table? snapshot
--- @return string? error
function M.load(id)
  local ok, result = pcall(function()
    local snapshot = vim.json.decode(table.concat(vim.fn.readfile(path_for(id)), "\n"))
    assert(type(snapshot) == "table", "Invalid conversation snapshot")
    assert(
      snapshot.format == "sia.conversation" and snapshot.version == 1,
      "Unsupported conversation format"
    )
    assert(snapshot.id == id, "Conversation ID mismatch")
    assert(type(snapshot.title) == "string", "Invalid conversation title")
    assert(type(snapshot.workspace) == "string", "Invalid conversation workspace")
    assert(
      snapshot.model == nil or type(snapshot.model) == "string",
      "Invalid conversation model"
    )
    assert(type(snapshot.created_at) == "number", "Invalid creation timestamp")
    assert(type(snapshot.updated_at) == "number", "Invalid update timestamp")
    assert(
      type(snapshot.messages) == "table" and vim.islist(snapshot.messages),
      "Invalid conversation messages"
    )
    local pending_call
    for _, message in ipairs(snapshot.messages) do
      assert(type(message) == "table", "Invalid conversation message")
      assert(
        message.role == "system"
          or message.role == "user"
          or message.role == "assistant"
          or message.role == "tool",
        "Invalid message role"
      )
      assert(
        message.content == nil
          or type(message.content) == "string"
          or type(message.content) == "table",
        "Invalid message content"
      )
      if pending_call then
        assert(
          message.role == "tool"
            and type(message.tool_call) == "table"
            and message.tool_call.id == pending_call.id,
          "Unpaired tool call"
        )
        pending_call = nil
      elseif message.role == "assistant" and message.tool_call then
        assert(
          type(message.tool_call) == "table"
            and type(message.tool_call.id) == "string"
            and type(message.tool_call.name) == "string",
          "Invalid tool call"
        )
        pending_call = message.tool_call
      else
        assert(message.role ~= "tool", "Unpaired tool result")
      end
    end
    assert(not pending_call, "Unpaired tool call")
    return snapshot
  end)
  if not ok then
    return nil, tostring(result)
  end
  return result
end

--- @return table[]
function M.list()
  local snapshots = {}
  for _, path in ipairs(vim.fn.glob(directory() .. "/*.json", false, true)) do
    local snapshot = M.load(vim.fn.fnamemodify(path, ":t:r"))
    if snapshot then
      snapshot.messages = nil
      snapshots[#snapshots + 1] = snapshot
    end
  end
  table.sort(snapshots, function(a, b)
    if a.updated_at == b.updated_at then
      return a.id < b.id
    end
    return (tonumber(a.updated_at) or 0) > (tonumber(b.updated_at) or 0)
  end)
  return snapshots
end

--- @param id string
--- @param opts sia.NewConversationArgs?
--- @return sia.Conversation? conversation
--- @return string? error
function M.restore(id, opts)
  local snapshot, err = M.load(id)
  if not snapshot then
    return nil, err
  end
  opts = vim.tbl_extend("force", { workspace = snapshot.workspace }, opts or {})
  if not opts.model then
    local ok, model = pcall(require("sia.model").resolve, snapshot.model)
    opts.model = ok and model or require("sia.model").resolve()
  end
  local conversation = require("sia.conversation").new(opts)
  conversation.uuid = snapshot.id
  conversation.name = snapshot.title or conversation.name
  conversation.created_at = snapshot.created_at or conversation.created_at
  local turn_id = require("sia.utils").new_uuid()
  local tool_call
  for _, message in ipairs(snapshot.messages) do
    if message.role == "system" then
      conversation:add_system_message(message.content)
    elseif message.role == "user" then
      turn_id = require("sia.utils").new_uuid()
      conversation:add_user_message(
        message.content,
        nil,
        { turn_id = turn_id, hide = message.hide }
      )
    elseif message.role == "assistant" then
      tool_call = message.tool_call
      if message.content then
        conversation:add_assistant_message(turn_id, message.content)
      end
    elseif message.role == "tool" then
      conversation:add_tool_message(turn_id, tool_call, message.content, {
        summary = message.summary,
      })
      tool_call = nil
    end
  end
  conversation:add_user_message(
    "System Note: This conversation was resumed. File tracking, diffs, agents, processes, "
      .. "approvals, and other runtime state were not restored. Reread files before editing "
      .. "and do not reuse historical runtime IDs or file snapshot tags.",
    nil,
    { hide = true, turn_id = turn_id }
  )
  return conversation
end

return M
