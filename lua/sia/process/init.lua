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

--- Write content to a persistent temp file.
--- @param content string?
--- @param conversation_id integer
--- @param proc_id integer
--- @param stream "stdout"|"stderr"
--- @return string? path the temp file path, or nil if content is empty
local function write_output(content, conversation_id, proc_id, stream)
  if not content or content == "" then
    return nil
  end
  local dir = require("sia.utils").dirs.bash(conversation_id)
  vim.fn.mkdir(dir, "p")
  local path = vim.fs.joinpath(dir, string.format("process_%d_%s", proc_id, stream))
  vim.fn.writefile(vim.split(content, "\n", { plain = true }), path)
  return path
end

--- Append stdout/stderr tail sections to a content table.
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

--- @param proc sia.process.Process
--- @param conversation_id integer
--- @param result sia.ShellResult
local function finalize(proc, conversation_id, result)
  proc.completed_at = vim.uv.hrtime() / 1e9
  proc.code = result.code or 0
  proc.interrupted = result.interrupted

  if result.interrupted then
    proc.status = "timed_out"
  elseif result.code == 143 then
    proc.status = "timed_out"
  else
    proc.status = "completed"
  end

  proc.stdout_file = write_output(result.stdout, conversation_id, proc.id, "stdout")
  proc.stderr_file = write_output(result.stderr, conversation_id, proc.id, "stderr")
end

--- @param proc sia.process.Process
--- @param conversation_id integer
--- @param captured { stdout: string?, stderr: string? }
local function persist_stop_output(proc, conversation_id, captured)
  proc.stdout_file = write_output(captured.stdout, conversation_id, proc.id, "stdout")
  proc.stderr_file = write_output(captured.stderr, conversation_id, proc.id, "stderr")
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
local Process = {}
Process.__index = Process

--- @param id integer
--- @param command string
--- @param description string?
function Process.new(id, command, description)
  local instance = setmetatable({
    id = id,
    command = command,
    description = description,
    status = "running",
    started_at = vim.uv.hrtime() / 1e9,
    cancellable = { is_cancelled = false },
  }, Process)
  return instance
end

--- @return string
function Process:read_stdout()
  return read_output_file(self.stdout_file)
end

--- @return string
function Process:read_stderr()
  return read_output_file(self.stderr_file)
end

--- @param opts? { tail_lines?: integer }
--- @return string
function Process:get_preview(opts)
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

    local handle_output = self.detached_handle.get_output()
    append_output_sections(
      content,
      handle_output.stdout,
      handle_output.stderr,
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
    self:read_stdout(),
    self:read_stderr(),
    tail_line_count,
    "Recent",
    "No output captured."
  )

  return table.concat(content, "\n")
end

--- @class sia.process.Runtime
--- @field shell sia.Shell?
--- @field items sia.process.Process[]
--- @field conversation_id integer
--- @field shell_config { project_root: string, shell_opts: sia.config.Shell? }
local Runtime = {}
Runtime.__index = Runtime

--- @private
--- @return sia.Shell
function Runtime:_ensure_shell()
  if not self.shell then
    self.shell = require("sia.process.shell").new(
      self.shell_config.project_root,
      self.shell_config.shell_opts
    )
  end
  return self.shell
end

--- @param command string
--- @param description string?
--- @return sia.process.Process
function Runtime:create(command, description)
  local proc_id = #self.items + 1
  local proc = Process.new(proc_id, command, description)
  table.insert(self.items, proc)
  return proc
end

--- @class sia.process.runtime.ExecOpts
--- @field description string?
--- @field timeout number?
--- @field is_cancelled fun():boolean
--- @field on_complete fun(proc: sia.process.Process)?

--- @param command string
--- @param opts sia.process.runtime.ExecOpts
--- @return sia.process.Process
function Runtime:exec(command, opts)
  local shell = self:_ensure_shell()
  local proc = self:create(command, opts.description)

  shell:exec(command, opts.timeout or 120000, function()
    return opts.is_cancelled() or (proc and proc.cancellable.is_cancelled)
  end, function(result)
    finalize(proc, self.conversation_id, result)
    if opts.on_complete then
      opts.on_complete(proc)
    end
  end)

  return proc
end

--- @param command string
--- @param opts sia.process.runtime.ExecOpts
--- @return sia.process.Process
function Runtime:exec_async(command, opts)
  local shell = self:_ensure_shell()
  local proc = self:create(command, opts.description)

  local handle = shell:spawn_detached(
    command,
    opts.timeout,
    opts.is_cancelled,
    function(result)
      if proc.status ~= "running" then
        return
      end
      proc.detached_handle = nil
      finalize(proc, self.conversation_id, result)
      if opts.on_complete then
        opts.on_complete(proc)
      end
    end
  )
  proc.detached_handle = handle

  return proc
end

--- Stop a running process and persist its captured output.
--- For async/detached processes, kills the process and persists output.
--- For sync processes, requests cancellation (actual termination happens
--- when the shell callback fires).
--- @param id integer
--- @return string[]? content formatted message
--- @return string? err
function Runtime:stop(id)
  local proc = self:get(id)
  if not proc then
    return nil, string.format("No process with ID %d found", id)
  end

  if proc.status ~= "running" then
    return nil,
      string.format(
        "Process %d is already %s (exit code: %s)",
        proc.id,
        proc.status,
        tostring(proc.code)
      )
  end

  if not proc.detached_handle then
    proc.cancellable.is_cancelled = true
    return {
      string.format("Cancellation requested for process %d.", proc.id),
      string.format("Command: %s", proc.command),
      "The process will be terminated when the shell completes the current command.",
    }
  end

  local handle_output = proc.detached_handle.get_output()
  proc.detached_handle.kill()
  proc.detached_handle = nil

  proc.completed_at = vim.uv.hrtime() / 1e9
  proc.status = "failed"
  proc.code = 143
  proc.interrupted = true

  persist_stop_output(proc, self.conversation_id, handle_output)

  local content = {
    string.format("Process %d terminated.", proc.id),
    string.format("Command: %s", proc.command),
    string.format("Ran for: %.1fs", proc.completed_at - proc.started_at),
  }

  append_output_sections(
    content,
    handle_output.stdout,
    handle_output.stderr,
    STATUS_OUTPUT_TAIL_LINES,
    "Final",
    "No output captured."
  )

  return content
end

--- @return string
function Runtime:pwd()
  local shell = self:_ensure_shell()
  return shell:pwd()
end

--- @param id integer
--- @return sia.process.Process?
function Runtime:get(id)
  return self.items[id]
end

--- @return sia.process.Process[]
function Runtime:list()
  return self.items
end

function Runtime:destroy()
  for _, proc in ipairs(self.items) do
    if proc.status == "running" and proc.detached_handle then
      proc.detached_handle.kill()
    end
  end

  if self.shell then
    self.shell:close()
    self.shell = nil
  end

  self.items = {}
end

return {
  --- @param conversation_id integer
  --- @param shell_config { project_root: string, shell_opts: sia.config.Shell? }
  --- @return sia.process.Runtime
  new_runtime = function(conversation_id, shell_config)
    return setmetatable({
      shell = nil,
      items = {},
      conversation_id = conversation_id,
      shell_config = shell_config,
    }, Runtime)
  end,
}
