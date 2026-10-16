-- Core snapshot/range editing adapted from oh-my-pi's hashline design.
-- See THIRD-PARTY-NOTICES.md for attribution and license.
local M = {}
local stores = setmetatable({}, { __mode = "k" })
local registers = {}

--- Release named registers when their conversation is destroyed.
function M.clear_clipboard(conversation_id)
  registers[conversation_id] = nil
end

local function digest(lines)
  return vim.fn.sha256(table.concat(lines, "\n"))
end

--- Record only fully displayed lines; truncated lines cannot be edited.
function M.view(conversation, path, lines, first, last, max_length)
  path = vim.fn.fnamemodify(path, ":p")
  local store = stores[conversation]
  if not store then
    store = {}
    stores[conversation] = store
  end
  local hash = digest(lines)
  local snapshot = store[path]
  if not snapshot or snapshot.digest ~= hash then
    -- Bound retained snapshot metadata per conversation.
    if vim.tbl_count(store) >= 256 then
      store[next(store)] = nil
    end
    snapshot = { digest = hash, seen = {} }
    store[path] = snapshot
  end
  local tag = hash:sub(1, 4):upper()
  local output = { string.format("[%s#%s]", path, tag) }
  for i = first, last do
    local line = lines[i]
    if max_length and #line > max_length then
      output[#output + 1] =
        string.format("%d:%s[TRUNCATED]", i, line:sub(1, max_length))
    else
      snapshot.seen[i] = true
      output[#output + 1] = string.format("%d:%s", i, line)
    end
  end
  return output
end

--- Refresh the snapshot with bounded, post-edit context around changed lines.
--- Preserve displayed lines whose content and line number are unchanged.
function M.refresh(conversation, path, before, lines)
  path = vim.fn.fnamemodify(path, ":p")
  local prior = stores[conversation] and stores[conversation][path]
  local seen = prior and prior.digest == digest(before) and prior.seen or {}
  local changes =
    vim.diff(table.concat(before, "\n") .. "\n", table.concat(lines, "\n") .. "\n", {
      result_type = "indices",
    })
  local carried = {}
  local old_line, new_line = 1, 1
  local function carry_until(last)
    if old_line == new_line then
      for i = old_line, last do
        if seen[i] then
          carried[i] = true
        end
      end
    end
  end
  for _, change in ipairs(changes) do
    -- Zero-length diff ranges name the line before the insertion/deletion.
    local old_start = change[1] + (change[2] == 0 and 1 or 0)
    local new_start = change[3] + (change[4] == 0 and 1 or 0)
    carry_until(old_start - 1)
    old_line, new_line = old_start + change[2], new_start + change[4]
  end
  carry_until(#before)
  local windows = {}
  for _, change in ipairs(changes) do
    local anchor = math.max(1, math.min(#lines, change[3]))
    local first = math.max(1, anchor - 3)
    local last = math.min(#lines, math.max(anchor, change[3] + change[4] - 1) + 3)
    local previous = windows[#windows]
    if previous and first <= previous[2] + 1 then
      previous[2] = math.max(previous[2], last)
    else
      windows[#windows + 1] = { first, last }
    end
  end
  if #windows == 0 then
    windows = { { 1, math.min(#lines, 7) } }
  end

  local output, displayed, bytes, previous_last = {}, 0, 0, 0
  for _, window in ipairs(windows) do
    local last = window[1] - 1
    for i = window[1], window[2] do
      local size = #tostring(i) + 2 + math.min(#lines[i], 2000) + 11
      if displayed >= 40 or bytes + size > 8000 then
        break
      end
      displayed, bytes, last = displayed + 1, bytes + size, i
    end
    if last < window[1] then
      break
    end
    local chunk = M.view(conversation, path, lines, window[1], last, 2000)
    if #output == 0 then
      output[1] = chunk[1]
    end
    if window[1] > previous_last + 1 then
      output[#output + 1] = "…"
    end
    for i = 2, #chunk do
      output[#output + 1] = chunk[i]
    end
    previous_last = last
    if last < window[2] then
      break
    end
  end
  if previous_last < #lines then
    output[#output + 1] = "…"
  end
  local snapshot = stores[conversation] and stores[conversation][path]
  if snapshot and snapshot.digest == digest(lines) then
    for i in pairs(carried) do
      snapshot.seen[i] = true
    end
  end
  return output
end

--- Stage a batch against original line numbers, without mutating the input.
--- Returns nil and a diagnostic on any invalid operation.
--- The third return value commits captured registers after a successful file write.
function M.apply(conversation, path, lines, tag, input)
  path = vim.fn.fnamemodify(path, ":p")
  local snapshot = stores[conversation] and stores[conversation][path]
  if
    type(tag) ~= "string"
    or not snapshot
    or tag:upper() ~= snapshot.digest:sub(1, 4):upper()
    or digest(lines) ~= snapshot.digest
  then
    return nil, "Stale or unknown snapshot. Use view before editing."
  end
  if type(input) ~= "string" or input == "" then
    return nil, "No hashline operations provided."
  end
  local edits, current = {}, nil
  local pending_registers = {}
  local anonymous, pending_cuts = nil, 0
  local conversation_id = conversation.id
  local function read_register(name)
    return pending_registers[name]
      or (registers[conversation_id] and registers[conversation_id][name])
  end
  for _, row in ipairs(vim.split(input, "\n", { plain = true })) do
    if row:sub(1, 1) == "+" then
      if not current or current.cut or current.paste then
        return nil, "Unexpected body row; only PUT operations ending in : accept +TEXT."
      end
      current.lines[#current.lines + 1] = row:sub(2)
    elseif row ~= "" then
      local command, register = row:match("^(.-) @([%w_-]+)$")
      command = command or row
      if
        register
        and (
          type(conversation_id) ~= "number" and type(conversation_id) ~= "string"
          or conversation_id == ""
        )
      then
        return nil, "Clipboard registers require a conversation id."
      end
      local cut = command:sub(1, 4) == "CUT "
      local paste = not cut and command:sub(-1) ~= ":"
      if register and not cut and not paste then
        return nil, "Register pastes have no colon or +TEXT body."
      end
      local first, last
      if cut then
        first, last = command:match("^CUT (%d+)%.=(%d+)$")
      elseif paste then
        if register then
          first, last = command:match("^PUT (%d+)%.=(%d+)$")
        end
      else
        first, last = command:match("^PUT (%d+)%.=(%d+):$")
      end
      local gap, anchor =
        command:match(paste and "^PUT ([<>])([%d$]+)$" or "^PUT ([<>])([%d$]+):$")
      local start, finish
      if first then
        first, last = tonumber(first), tonumber(last)
        if first < 1 or last < first or last > #lines then
          return nil, "Invalid inclusive line range: " .. row
        end
        for i = first, last do
          if not snapshot.seen[i] then
            return nil,
              "Line " .. i .. " was not fully displayed. Read it before editing."
          end
        end
        start, finish = first - 1, last
      elseif gap then
        local n = anchor == "$" and gap == ">" and #lines or tonumber(anchor)
        if not n or n < 1 or n > #lines then
          return nil, "Invalid insertion anchor: " .. row
        end
        if not snapshot.seen[n] then
          return nil,
            "Insertion anchor was not fully displayed. Read it before editing."
        end
        start = gap == "<" and n - 1 or n
        finish = start
      else
        return nil, "Unsupported hashline operation: " .. row
      end
      current = {
        start = start,
        finish = finish,
        lines = {},
        cut = cut,
        paste = paste,
        order = #edits + 1,
      }
      if cut then
        local captured = {}
        for i = start + 1, finish do
          captured[#captured + 1] = lines[i]
        end
        if register then
          pending_registers[register] = captured
        else
          anonymous, pending_cuts = captured, pending_cuts + 1
        end
      elseif paste then
        if register then
          local captured = read_register(register)
          if not captured then
            return nil, "Unknown clipboard register: @" .. register
          end
          current.lines = vim.deepcopy(captured)
        else
          if not anonymous then
            return nil,
              "No anonymous cut available in this edit. Use CUT first or name a register."
          end
          if pending_cuts > 1 then
            return nil,
              "Ambiguous anonymous paste after multiple cuts. Use named registers."
          end
          current.lines = vim.deepcopy(anonymous)
          pending_cuts = 0
        end
      end
      edits[#edits + 1] = current
    end
  end
  if #edits == 0 then
    return nil, "No hashline operations provided."
  end
  for i, edit in ipairs(edits) do
    if not edit.cut and #edit.lines == 0 then
      return nil, "PUT requires +TEXT body rows; use CUT to delete."
    end
    for j = 1, i - 1 do
      local other = edits[j]
      if
        math.max(edit.start, other.start) < math.min(edit.finish, other.finish)
        or (edit.start == edit.finish and edit.start > other.start and edit.start < other.finish)
        or (
          other.start == other.finish
          and other.start > edit.start
          and other.start < edit.finish
        )
      then
        return nil, "Overlapping operations are not allowed."
      end
    end
  end
  table.sort(edits, function(a, b)
    if a.start ~= b.start then
      return a.start > b.start
    end
    if a.finish ~= b.finish then
      return a.finish > b.finish
    end
    return a.order > b.order
  end)
  local result = vim.deepcopy(lines)
  for _, edit in ipairs(edits) do
    for _ = edit.start + 1, edit.finish do
      table.remove(result, edit.start + 1)
    end
    for i = #edit.lines, 1, -1 do
      table.insert(result, edit.start + 1, edit.lines[i])
    end
  end
  -- Neovim represents an empty file with one empty line.
  if #result == 0 then
    result = { "" }
  end
  local commit
  if next(pending_registers) then
    commit = function()
      local clipboard = registers[conversation_id] or {}
      for name, captured in pairs(pending_registers) do
        clipboard[name] = captured
      end
      registers[conversation_id] = clipboard
    end
  end
  return result, nil, commit
end

return M
