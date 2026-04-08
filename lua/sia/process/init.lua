local STATUS_OUTPUT_TAIL_LINES = 20

--- @param text string?
--- @param n integer
--- @return string[]
local function tail_lines(text, n)
  if not text or text == "" then
    return {}
  end

  local lines = vim.split(text, "\n", { plain = true })
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end

  if #lines <= n then
    return lines
  end

  local result = {}
  for i = #lines - n + 1, #lines do
    table.insert(result, lines[i])
  end
  return result
end

--- @param path string?
--- @return string
local function read_output_file(path)
  if not path or vim.fn.filereadable(path) ~= 1 then
    return ""
  end
  return table.concat(vim.fn.readfile(path), "\n")
end

--- @param conversation_id integer?
--- @param proc_id integer
--- @param stream "stdout"|"stderr"
--- @param content string?
--- @return string?
local function write_bash_output(content, conversation_id, proc_id, stream)
  if not content or content == "" or not conversation_id then
    return nil
  end

  local dir = require("sia.utils").dirs.bash(conversation_id)
  vim.fn.mkdir(dir, "p")
  local path = vim.fs.joinpath(dir, string.format("process_%d_%s", proc_id, stream))
  vim.fn.writefile(vim.split(content, "\n", { plain = true }), path)
  return path
end

--- @param content string[]
--- @param stdout string?
--- @param stderr string?
--- @param tail_line_count integer
--- @param header_prefix string
--- @param empty_message string?
local function append_output_sections(
  content,
  stdout,
  stderr,
  tail_line_count,
  header_prefix,
  empty_message
)
  local stdout_tail = tail_lines(stdout, tail_line_count)
  local stderr_tail = tail_lines(stderr, tail_line_count)

  if #stdout_tail > 0 then
    table.insert(content, "")
    table.insert(
      content,
      string.format(
        "%s stdout (last %d lines):",
        header_prefix,
        math.min(#stdout_tail, tail_line_count)
      )
    )
    vim.list_extend(content, stdout_tail)
  end

  if #stderr_tail > 0 then
    table.insert(content, "")
    table.insert(
      content,
      string.format(
        "%s stderr (last %d lines):",
        header_prefix,
        math.min(#stderr_tail, tail_line_count)
      )
    )
    vim.list_extend(content, stderr_tail)
  end

  if #stdout_tail == 0 and #stderr_tail == 0 and empty_message then
    table.insert(content, empty_message)
  end
end

--- @class sia.process.Process
--- @field id integer
--- @field command string
--- @field description string?
--- @field status "running"|"completed"|"failed"|"timed_out"
--- @field code integer?
--- @field stdout_file string? temp file path with full stdout
--- @field stderr_file string? temp file path with full stderr
--- @field interrupted boolean?
--- @field started_at number
--- @field completed_at number?
--- @field cancellable sia.Cancellable
--- @field detached_handle sia.DetachedProcess? handle for async/detached processes
--- @field _conversation_id integer?
local M = {}
M.__index = M

--- @param id integer
--- @param command string
--- @param description string?
function M.new(id, command, description)
  local instance = setmetatable({
    id = id,
    command = command,
    description = description,
    status = "running",
    started_at = vim.uv.hrtime() / 1e9,
    -- _conversation_id = self.id,
    cancellable = { is_cancelled = false },
  }, M)
  return instance
end

--- @param opts? { tail_lines?: integer }
--- @return string
function M:get_preview(opts)
  opts = opts or {}
  local tail_line_count = opts.tail_lines or STATUS_OUTPUT_TAIL_LINES
  local content = {
    string.format("Process ID: %d", self.id),
    string.format("Command: %s", self.command),
    string.format("Status: %s", self.status),
  }

  if self.status == "running" then
    table.insert(
      content,
      string.format("Running for: %.1fs", (vim.uv.hrtime() / 1e9) - self.started_at)
    )

    if not self.detached_handle then
      table.insert(content, "Output preview is unavailable for synchronous processes.")
      return table.concat(content, "\n")
    end

    local output = self.detached_handle.get_output()
    append_output_sections(
      content,
      output.stdout,
      output.stderr,
      tail_line_count,
      "Recent",
      "No output yet."
    )
    return table.concat(content, "\n")
  end

  table.insert(content, string.format("Exit code: %d", self.code or -1))
  if self.interrupted then
    table.insert(content, "Interrupted: yes")
  end
  if self.stdout_file then
    table.insert(content, string.format("Full stdout: %s", self.stdout_file))
  end
  if self.stderr_file then
    table.insert(content, string.format("Full stderr: %s", self.stderr_file))
  end

  append_output_sections(
    content,
    read_output_file(self.stdout_file),
    read_output_file(self.stderr_file),
    tail_line_count,
    "Recent",
    "No output captured."
  )

  return table.concat(content, "\n")
end

--- @return string[]? content
--- @return string? err
function M:stop()
  if self.status ~= "running" then
    return nil,
      string.format(
        "Process %d is already %s (exit code: %s)",
        self.id,
        self.status,
        tostring(self.code)
      )
  end

  self.completed_at = vim.uv.hrtime() / 1e9
  local stdout, stderr
  if not self.detached_handle then
    self.cancellable.is_cancelled = true
  else
    local output = self.detached_handle.get_output()
    stdout = output.stdout
    stderr = output.stderr
    self.detached_handle.kill()
    self.detached_handle = nil

    self.status = "failed"
    self.code = 143
    self.interrupted = true
    self.stdout_file =
      write_bash_output(output.stdout, self._conversation_id, self.id, "stdout")
    self.stderr_file =
      write_bash_output(output.stderr, self._conversation_id, self.id, "stderr")
  end

  local content = {
    string.format("Process %d terminated.", self.id),
    string.format("Command: %s", self.command),
    string.format("Ran for: %.1fs", self.completed_at - self.started_at),
  }

  append_output_sections(
    content,
    stdout,
    stderr,
    STATUS_OUTPUT_TAIL_LINES,
    "Final",
    "No output captured."
  )

  return content
end

return M
