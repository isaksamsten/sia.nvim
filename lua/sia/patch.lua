--- apply_patch parser and commit logic
--- Ported from the canonical Python reference implementation.
local M = {}

--- Section boundary prefixes.
local SECTION_PREFIXES = {
  "@@",
  "*** End Patch",
  "*** Update File:",
  "*** Delete File:",
  "*** Add File:",
  "*** End of File",
}

local HUNK_PREFIXES = {
  "*** End Patch",
  "*** Update File:",
  "*** Delete File:",
  "*** Add File:",
  "*** End of File",
}

local ADD_PREFIXES = {
  "*** End Patch",
  "*** Update File:",
  "*** Delete File:",
  "*** Add File:",
}

--- Check if a line starts with any of the given prefixes.
--- @param line string
--- @param prefixes string[]
--- @return boolean
local function starts_with_any(line, prefixes)
  for _, p in ipairs(prefixes) do
    if vim.startswith(line, p) then
      return true
    end
  end
  return false
end

--- Find context lines in the original file (exact, rstrip, then strip).
--- @param lines string[] original file lines (1-indexed)
--- @param context string[] context lines to match (1-indexed)
--- @param start integer 0-based start index
--- @return integer index 0-based, or -1 if not found
--- @return integer fuzz 0=exact, 1=rstrip, 100=strip
local function find_context_core(lines, context, start)
  if #context == 0 then
    return start, 0
  end

  local ctx_len = #context

  -- Exact match
  for i = start, #lines - ctx_len do
    local match = true
    for j = 1, ctx_len do
      if lines[i + j] ~= context[j] then
        match = false
        break
      end
    end
    if match then
      return i, 0
    end
  end

  -- Rstrip match
  for i = start, #lines - ctx_len do
    local match = true
    for j = 1, ctx_len do
      if lines[i + j]:gsub("%s+$", "") ~= context[j]:gsub("%s+$", "") then
        match = false
        break
      end
    end
    if match then
      return i, 1
    end
  end

  -- Strip match
  for i = start, #lines - ctx_len do
    local match = true
    for j = 1, ctx_len do
      if vim.trim(lines[i + j]) ~= vim.trim(context[j]) then
        match = false
        break
      end
    end
    if match then
      return i, 100
    end
  end

  return -1, 0
end

--- Find context with EOF awareness.
--- @param lines string[]
--- @param context string[]
--- @param start integer 0-based
--- @param eof boolean
--- @return integer index
--- @return integer fuzz
local function find_context(lines, context, start, eof)
  if eof then
    local anchor = #lines - #context
    if anchor < 0 then
      anchor = 0
    end
    local idx, fuzz = find_context_core(lines, context, anchor)
    if idx ~= -1 then
      return idx, fuzz
    end
    idx, fuzz = find_context_core(lines, context, start)
    return idx, fuzz + 10000
  end
  return find_context_core(lines, context, start)
end

--- Read one section of change lines, returning context, chunks, end index, and EOF flag.
--- @param lines string[] all patch lines (1-indexed)
--- @param index integer 1-based
--- @return string[] context
--- @return table[] chunks
--- @return integer end_index 1-based, next line to process
--- @return boolean eof
local function peek_next_section(lines, index)
  local old = {}
  local del_lines = {}
  local ins_lines = {}
  local chunks = {}
  local mode = "keep"
  local orig_index = index

  while index <= #lines do
    local s = lines[index]
    if starts_with_any(s, SECTION_PREFIXES) then
      break
    end
    if s == "***" then
      break
    elseif vim.startswith(s, "***") then
      error("Invalid Line: " .. s)
    end
    index = index + 1
    local last_mode = mode
    if s == "" then
      s = " "
    end
    local ch = s:sub(1, 1)
    if ch == "+" then
      mode = "add"
    elseif ch == "-" then
      mode = "delete"
    elseif ch == " " then
      mode = "keep"
    else
      error("Invalid Line: " .. s)
    end
    s = s:sub(2)

    if mode == "keep" and last_mode ~= mode then
      if #ins_lines > 0 or #del_lines > 0 then
        table.insert(chunks, {
          orig_index = #old - #del_lines,
          del_lines = del_lines,
          ins_lines = ins_lines,
        })
      end
      del_lines = {}
      ins_lines = {}
    end

    if mode == "delete" then
      table.insert(del_lines, s)
      table.insert(old, s)
    elseif mode == "add" then
      table.insert(ins_lines, s)
    elseif mode == "keep" then
      table.insert(old, s)
    end
  end

  if #ins_lines > 0 or #del_lines > 0 then
    table.insert(chunks, {
      orig_index = #old - #del_lines,
      del_lines = del_lines,
      ins_lines = ins_lines,
    })
  end

  if index <= #lines and lines[index] == "*** End of File" then
    index = index + 1
    return old, chunks, index, true
  end

  if index == orig_index then
    error("Nothing in this section - index=" .. index .. " " .. lines[index])
  end

  return old, chunks, index, false
end

--- Parse an update-file section.
--- @param patch_lines string[] all patch lines (1-indexed)
--- @param patch_index integer current 1-based index in patch_lines
--- @param file_text string original file content
--- @return table action {type, chunks, move_path?}
--- @return integer new_patch_index
--- @return integer fuzz
local function parse_update_file(patch_lines, patch_index, file_text)
  local action = { type = "update", chunks = {} }
  local file_lines = vim.split(file_text, "\n", { plain = true })
  local file_index = 0
  local total_fuzz = 0

  while
    patch_index <= #patch_lines
    and not starts_with_any(patch_lines[patch_index], HUNK_PREFIXES)
  do
    local def_str = ""
    local section_str = ""
    if vim.startswith(patch_lines[patch_index], "@@ ") then
      def_str = patch_lines[patch_index]:sub(4)
      patch_index = patch_index + 1
    elseif patch_lines[patch_index] == "@@" then
      section_str = patch_lines[patch_index]
      patch_index = patch_index + 1
    elseif file_index ~= 0 then
      error("Invalid Line:\n" .. patch_lines[patch_index])
    end

    if def_str ~= "" and vim.trim(def_str) ~= "" then
      local found = false
      local has_before = false
      for k = 1, file_index do
        if file_lines[k] == def_str then
          has_before = true
          break
        end
      end
      if not has_before then
        for k = file_index + 1, #file_lines do
          if file_lines[k] == def_str then
            file_index = k
            found = true
            break
          end
        end
      end
      if not found then
        local has_before_stripped = false
        for k = 1, file_index do
          if vim.trim(file_lines[k]) == vim.trim(def_str) then
            has_before_stripped = true
            break
          end
        end
        if not has_before_stripped then
          for k = file_index + 1, #file_lines do
            if vim.trim(file_lines[k]) == vim.trim(def_str) then
              file_index = k
              total_fuzz = total_fuzz + 1
              found = true
              break
            end
          end
        end
      end
    end

    local next_context, chunks, end_patch_index, eof =
      peek_next_section(patch_lines, patch_index)
    local new_index, fuzz = find_context(file_lines, next_context, file_index, eof)
    if new_index == -1 then
      local ctx_text = table.concat(next_context, "\n")
      if eof then
        error("Invalid EOF Context " .. file_index .. ":\n" .. ctx_text)
      else
        error("Invalid Context " .. file_index .. ":\n" .. ctx_text)
      end
    end
    total_fuzz = total_fuzz + fuzz

    for _, ch in ipairs(chunks) do
      ch.orig_index = ch.orig_index + new_index
      table.insert(action.chunks, ch)
    end
    file_index = new_index + #next_context
    patch_index = end_patch_index
  end

  return action, patch_index, total_fuzz
end

--- Parse an add-file section.
--- @param patch_lines string[]
--- @param patch_index integer 1-based
--- @return table action
--- @return integer new_patch_index
local function parse_add_file(patch_lines, patch_index)
  local add_lines = {}
  while
    patch_index <= #patch_lines
    and not starts_with_any(patch_lines[patch_index], ADD_PREFIXES)
  do
    local s = patch_lines[patch_index]
    if not vim.startswith(s, "+") then
      error("Invalid Add File Line: " .. s)
    end
    table.insert(add_lines, s:sub(2))
    patch_index = patch_index + 1
  end
  local action = {
    type = "add",
    new_file = table.concat(add_lines, "\n"),
    chunks = {},
  }
  return action, patch_index
end

--- Parse a full patch text into a Patch structure.
--- @param text string raw patch text
--- @param current_files table<string, string> path → file content
--- @return table patch {actions: table<string, action>}
--- @return integer fuzz
function M.text_to_patch(text, current_files)
  local lines = vim.split(vim.trim(text), "\n", { plain = true })
  if
    #lines < 2
    or not vim.startswith(lines[1], "*** Begin Patch")
    or lines[#lines] ~= "*** End Patch"
  then
    error("Invalid patch text")
  end

  local patch = { actions = {} }
  local index = 2
  local total_fuzz = 0

  while index <= #lines and not vim.startswith(lines[index], "*** End Patch") do
    if vim.startswith(lines[index], "*** Update File: ") then
      local path = lines[index]:sub(#"*** Update File: " + 1)
      if patch.actions[path] then
        error("Update File Error: Duplicate Path: " .. path)
      end
      index = index + 1
      local move_to = nil
      if index <= #lines and vim.startswith(lines[index], "*** Move to: ") then
        move_to = lines[index]:sub(#"*** Move to: " + 1)
        index = index + 1
      end
      if not current_files[path] then
        error("Update File Error: Missing File: " .. path)
      end
      local action, new_index, fuzz =
        parse_update_file(lines, index, current_files[path])
      action.move_path = move_to
      patch.actions[path] = action
      index = new_index
      total_fuzz = total_fuzz + fuzz
    elseif vim.startswith(lines[index], "*** Delete File: ") then
      local path = lines[index]:sub(#"*** Delete File: " + 1)
      if patch.actions[path] then
        error("Delete File Error: Duplicate Path: " .. path)
      end
      if not current_files[path] then
        error("Delete File Error: Missing File: " .. path)
      end
      patch.actions[path] = { type = "delete", chunks = {} }
      index = index + 1
    elseif vim.startswith(lines[index], "*** Add File: ") then
      local path = lines[index]:sub(#"*** Add File: " + 1)
      if patch.actions[path] then
        error("Add File Error: Duplicate Path: " .. path)
      end
      index = index + 1
      local action, new_index = parse_add_file(lines, index)
      patch.actions[path] = action
      index = new_index
    else
      error("Unknown Line: " .. lines[index])
    end
  end

  if index > #lines or not vim.startswith(lines[index], "*** End Patch") then
    error("Missing End Patch")
  end

  return patch, total_fuzz
end

--- Identify which files a patch text needs to read.
--- @param text string
--- @return string[]
function M.identify_files_needed(text)
  local result = {}
  local seen = {}
  for _, line in ipairs(vim.split(vim.trim(text), "\n", { plain = true })) do
    local path
    if vim.startswith(line, "*** Update File: ") then
      path = line:sub(#"*** Update File: " + 1)
    elseif vim.startswith(line, "*** Delete File: ") then
      path = line:sub(#"*** Delete File: " + 1)
    end
    if path and not seen[path] then
      seen[path] = true
      table.insert(result, path)
    end
  end
  return result
end

--- Apply chunks to produce updated file content.
--- @param file_text string
--- @param action table patch action with chunks
--- @param path string for error messages
--- @return string new_content
function M.get_updated_file(file_text, action, path)
  local orig_lines = vim.split(file_text, "\n", { plain = true })
  local dest_lines = {}
  local orig_index = 0

  for _, chunk in ipairs(action.chunks) do
    if chunk.orig_index > #orig_lines then
      error(
        string.format(
          "apply_diff: %s: chunk.orig_index %d > len(lines) %d",
          path,
          chunk.orig_index,
          #orig_lines
        )
      )
    end
    if orig_index > chunk.orig_index then
      error(
        string.format(
          "apply_diff: %s: orig_index %d > chunk.orig_index %d",
          path,
          orig_index,
          chunk.orig_index
        )
      )
    end

    for i = orig_index + 1, chunk.orig_index do
      table.insert(dest_lines, orig_lines[i])
    end
    orig_index = chunk.orig_index

    for _, line in ipairs(chunk.ins_lines) do
      table.insert(dest_lines, line)
    end

    orig_index = orig_index + #chunk.del_lines
  end

  for i = orig_index + 1, #orig_lines do
    table.insert(dest_lines, orig_lines[i])
  end

  return table.concat(dest_lines, "\n")
end
--- @class sia.Commit
--- @field type "delete"|"add"|"update"
--- @field old_content string
--- @field new_content string
--- @field move_path string?

--- Convert a parsed patch into a commit (set of file changes).
--- @param patch table
--- @param orig table<string, string>
--- @return table<string, sia.Commit> commit
function M.patch_to_commit(patch, orig)
  local commit = {}
  for path, action in pairs(patch.actions) do
    if action.type == "delete" then
      commit[path] = { type = "delete", old_content = orig[path] }
    elseif action.type == "add" then
      commit[path] = { type = "add", new_content = action.new_file }
    elseif action.type == "update" then
      local new_content = M.get_updated_file(orig[path], action, path)
      commit[path] = {
        type = "update",
        old_content = orig[path],
        new_content = new_content,
        move_path = action.move_path,
      }
    end
  end
  return commit
end

return M
