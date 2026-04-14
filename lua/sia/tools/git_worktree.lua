local utils = require("sia.utils")
local tool_utils = require("sia.tools.utils")
local icons = require("sia.ui").icons
local tool_names = tool_utils.tool_names

local GIT_TIMEOUT = 10000
local MAX_DIFF_LINES = 400

--- @class sia.git_worktree.WorktreeRecord
--- @field path string
--- @field branch string
--- @field base_ref string
--- @field repo_root string
--- @field created_at integer

--- @type table<integer, table<string, sia.git_worktree.WorktreeRecord?>>
local worktrees = {}

local augroup = vim.api.nvim_create_augroup("SiaGitWorktree", { clear = true })

--- @param cwd string
--- @param args string[]
--- @return vim.SystemCompleted
local function git(cwd, args)
  return vim
    .system(vim.list_extend({ "git" }, args), {
      cwd = cwd,
      text = true,
      timeout = GIT_TIMEOUT,
    })
    :wait()
end

--- @param text string?
--- @return string
local function trim(text)
  return vim.trim(text or "")
end

--- @param result vim.SystemCompleted
--- @param fallback string
--- @return string
local function git_error(result, fallback)
  local message = trim(result.stderr)
  if message ~= "" then
    return message
  end

  message = trim(result.stdout)
  if message ~= "" then
    return message
  end

  return fallback
end

--- @param conversation_id integer
--- @param branch string
local function remove_record(conversation_id, branch)
  local records = worktrees[conversation_id]
  if not records then
    return
  end

  records[branch] = nil
end

--- @param ref string
--- @return string
local function short_ref(ref)
  return ref:sub(1, 7)
end

--- @param path string
--- @return string
local function display_path(path)
  local relative = vim.fn.fnamemodify(path, ":~")
  if relative == "" then
    return path
  end
  return relative
end

--- @param conversation sia.Conversation
--- @return integer
local function conversation_id(conversation)
  return conversation.id or 0
end

--- @param workspace string
--- @return string?
local function get_repo_root(workspace)
  local result = git(workspace, { "rev-parse", "--show-toplevel" })
  if result.code ~= 0 then
    return nil
  end

  return trim(result.stdout)
end

--- @param repo_root string
--- @param branch string
--- @return boolean
local function validate_branch(repo_root, branch)
  local result = git(repo_root, { "check-ref-format", "--branch", branch })
  if result.code ~= 0 then
    return false
  end

  return true
end

--- @param repo_root string
--- @param branch string
--- @return boolean
local function branch_exists(repo_root, branch)
  local result = git(repo_root, { "rev-parse", "--verify", "refs/heads/" .. branch })
  return result.code == 0
end

--- Check if a branch is already checked out in any worktree.
--- @param repo_root string
--- @param branch string
--- @return string? worktree_path  path to the worktree if checked out, nil otherwise
local function branch_checked_out_in_worktree(repo_root, branch)
  local result = git(repo_root, { "worktree", "list", "--porcelain" })
  if result.code ~= 0 then
    return nil
  end

  local target_ref = "refs/heads/" .. branch
  local current_path = nil
  for _, line in ipairs(vim.split(result.stdout, "\n", { plain = true })) do
    if vim.startswith(line, "worktree ") then
      current_path = line:sub(#"worktree " + 1)
    elseif line == "branch " .. target_ref then
      return current_path
    elseif line == "" then
      current_path = nil
    end
  end

  return nil
end

--- @param repo_root string
--- @param base string
--- @return string?
local function resolve_base_ref(repo_root, base)
  local result = git(repo_root, { "rev-parse", base })
  if result.code ~= 0 then
    return nil
  end

  return trim(result.stdout)
end

--- @param record sia.git_worktree.WorktreeRecord
--- @return boolean
local function workspace_exists(record)
  if vim.fn.isdirectory(record.path) == 1 then
    return true
  end

  return false
end

--- Check if a path is a valid git worktree for a specific branch.
--- @param path string
--- @param branch string
--- @return boolean
local function is_valid_worktree_for(path, branch)
  if vim.fn.isdirectory(path) ~= 1 then
    return false
  end

  -- Check that it's a git directory at all
  local toplevel = git(path, { "rev-parse", "--show-toplevel" })
  if toplevel.code ~= 0 then
    return false
  end

  -- Check the branch that's checked out
  local head_ref = git(path, { "symbolic-ref", "--short", "HEAD" })
  if head_ref.code ~= 0 then
    return false
  end

  return trim(head_ref.stdout) == branch
end

--- @param lines string[]
--- @param title string
--- @param body string|string[]
local function append_section(lines, title, body)
  table.insert(lines, title .. ":")

  local values = body
  if type(values) == "string" then
    values = vim.split(values, "\n", { plain = true, trimempty = true })
  end

  if #values == 0 then
    table.insert(lines, "(none)")
    return
  end

  vim.list_extend(lines, values)
end

vim.api.nvim_create_autocmd("User", {
  group = augroup,
  pattern = "SiaConversationDestroyed",
  callback = function(args)
    local data = args.data or {}
    if type(data.conversation_id) == "number" then
      local cid = data.conversation_id
      local records = worktrees[cid]
      if not records then
        return
      end

      for _, record in pairs(records) do
        pcall(git, record.repo_root, { "worktree", "remove", "--force", record.path })
      end

      worktrees[cid] = nil
    end
  end,
})

--- @param args table
--- @return string
local function summary(args)
  local branch = args.branch or "unknown"
  if args.command == "create" then
    return string.format("%s Creating worktree %s", icons.started, branch)
  elseif args.command == "remove" then
    return string.format("%s Removing worktree %s", icons.delete, branch)
  elseif args.command == "status" then
    return string.format("%s Checking worktree %s", icons.directory, branch)
  elseif args.command == "diff" then
    return string.format("%s Diffing worktree %s", icons.view, branch)
  end

  return string.format("%s Listing git worktrees", icons.directory)
end

--- @param args table
--- @param conversation sia.Conversation
--- @param callback fun(result:sia.ToolResult)
local function create_worktree(args, conversation, callback)
  local branch = args.branch
  if not branch or branch == "" then
    callback({ content = "Error: 'branch' parameter is required for 'create'" })
    return
  end

  local repo_root = get_repo_root(conversation.workspace)
  if not repo_root then
    callback({
      content = "Not a git repository",
    })
    return
  end

  if not validate_branch(repo_root, branch) then
    callback({
      content = string.format("Invalid branch name: %s", branch),
    })
    return
  end

  local records = worktrees[conversation.id]
  if records == nil then
    records = {}
    worktrees[conversation.id] = records
  end

  local existing = records[branch]
  if existing then
    callback({
      content = string.format(
        "Error: Worktree for branch '%s' is already tracked at %s",
        branch,
        display_path(existing.path)
      ),
    })
    return
  end

  local target_path = vim.fs.joinpath(utils.dirs.worktrees(conversation.id), branch)

  -- Re-adopt: if the target path already exists and is a valid worktree for
  -- this branch (e.g., left over from a crashed session), adopt it into
  -- tracking instead of failing.
  if is_valid_worktree_for(target_path, branch) then
    local base_ref = resolve_base_ref(target_path, "HEAD")
    if not base_ref then
      callback({
        content = string.format(
          "Error: Found existing worktree at %s but failed to resolve HEAD",
          display_path(target_path)
        ),
      })
      return
    end

    local record = {
      path = target_path,
      branch = branch,
      base_ref = base_ref,
      repo_root = repo_root,
      created_at = os.time(),
    }
    records[branch] = record

    callback({
      content = table.concat({
        "Worktree created.",
        "Path: " .. target_path,
        "Branch: " .. branch,
        string.format("Re-adopted orphaned worktree (tip: %s)", short_ref(base_ref)),
        "Repo: " .. repo_root,
        "",
        "Pass this path as `workspace` when starting agents to work in this worktree.",
      }, "\n"),
      summary = string.format("%s Re-adopted git worktree %s", icons.started, branch),
    })
    return
  end

  local parent_dir = vim.fn.fnamemodify(target_path, ":h")
  if parent_dir ~= "" and parent_dir ~= "." then
    vim.fn.mkdir(parent_dir, "p")
  end

  local existing_branch = branch_exists(repo_root, branch)

  -- If the branch is already checked out in another worktree, we can't use it
  if existing_branch then
    local checked_out_at = branch_checked_out_in_worktree(repo_root, branch)
    if checked_out_at then
      callback({
        content = string.format(
          "Error: Branch '%s' is already checked out in worktree at %s. "
            .. "Choose a different branch name or remove that worktree first.",
          branch,
          display_path(checked_out_at)
        ),
      })
      return
    end
  end

  local base = args.base or "HEAD"
  local result
  if existing_branch then
    -- Branch exists: check it out in a new worktree (ignore base param)
    result = git(repo_root, { "worktree", "add", target_path, branch })
  else
    -- New branch: create it from the base ref
    result = git(repo_root, { "worktree", "add", "-b", branch, target_path, base })
  end

  if result.code ~= 0 then
    callback({
      content = string.format(
        "Error: Failed to create worktree for branch '%s': %s",
        branch,
        git_error(result, "git worktree add failed")
      ),
    })
    return
  end

  -- Resolve the base_ref after worktree creation:
  -- - For new branches, it's the resolved base commit
  -- - For existing branches, it's the branch tip at attachment time (so diff
  --   shows only changes made in this session)
  local base_ref
  if existing_branch then
    base_ref = resolve_base_ref(target_path, "HEAD")
  else
    base_ref = resolve_base_ref(repo_root, base)
  end

  if not base_ref then
    callback({
      content = string.format(
        "Worktree created but failed to resolve base ref for '%s'",
        base
      ),
    })
    return
  end

  local record = {
    path = target_path,
    branch = branch,
    base_ref = base_ref,
    repo_root = repo_root,
    created_at = os.time(),
  }
  records[branch] = record

  local message_lines = {
    "Worktree created.",
    "Path: " .. target_path,
    "Branch: " .. branch,
  }

  if existing_branch then
    table.insert(
      message_lines,
      string.format("Attached to existing branch (tip: %s)", short_ref(base_ref))
    )
  else
    table.insert(
      message_lines,
      string.format("Base: %s (%s)", short_ref(base_ref), base)
    )
  end

  vim.list_extend(message_lines, {
    "Repo: " .. repo_root,
    "",
    "Pass this path as `workspace` when starting agents to work in this worktree.",
  })

  callback({
    content = table.concat(message_lines, "\n"),
    summary = string.format("%s Created git worktree %s", icons.started, branch),
  })
end

--- @param conversation sia.Conversation
--- @param callback fun(result:sia.ToolResult)
local function list_worktrees(conversation, callback)
  local records = worktrees[conversation_id(conversation)] or {}
  if vim.tbl_isempty(records) then
    callback({
      content = "No tracked git worktrees for this conversation.",
      summary = string.format("%s No git worktrees", icons.directory),
      ephemeral = true,
    })
    return
  end

  local lines = {
    string.format(
      "Tracked git worktrees for conversation %d:",
      conversation_id(conversation)
    ),
    "",
  }

  local count = 0
  for _, record in pairs(records) do
    count = count + 1
    table.insert(lines, string.format("- Branch: %s", record.branch))
    table.insert(lines, string.format("  Path: %s", display_path(record.path)))
    table.insert(lines, string.format("  Base: %s", short_ref(record.base_ref)))
    table.insert(lines, string.format("  Repo: %s", display_path(record.repo_root)))
  end

  callback({
    content = table.concat(lines, "\n"),
    summary = string.format("%s Listed %d git worktree(s)", icons.directory, count),
  })
end

--- @param args table
--- @param conversation sia.Conversation
--- @param callback fun(result:sia.ToolResult)
local function status_worktree(args, conversation, callback)
  local branch = args.branch
  if not branch or branch == "" then
    callback({ content = "Error: 'branch' parameter is required for 'status'" })
    return
  end
  local records = worktrees[conversation.id] or {}
  local record = records[branch]
  if not record then
    callback({
      content = string.format(
        "Error: No tracked worktree found for branch '%s'",
        branch
      ),
    })
    return
  end

  local exists = workspace_exists(record)
  if not exists then
    callback({
      content = string.format(
        "Tracked worktree for branch '%s' no longer exists at %s",
        record.branch,
        display_path(record.path)
      ),
    })
    return
  end

  local status_result = git(record.path, { "status", "--short" })
  if status_result.code ~= 0 then
    callback({
      content = string.format(
        "Error: Failed to inspect worktree '%s': %s",
        branch,
        git_error(status_result, "git status failed")
      ),
    })
    return
  end

  local stat_result =
    git(record.path, { "diff", "--stat", "--no-ext-diff", record.base_ref })
  if stat_result.code ~= 0 then
    callback({
      content = string.format(
        "Error: Failed to diff worktree '%s': %s",
        branch,
        git_error(stat_result, "git diff --stat failed")
      ),
    })
    return
  end

  local log_result = git(
    record.path,
    { "log", "--oneline", "--decorate", "--max-count=10", record.base_ref .. "..HEAD" }
  )
  if log_result.code ~= 0 then
    callback({
      content = string.format(
        "Error: Failed to read history for '%s': %s",
        branch,
        git_error(log_result, "git log failed")
      ),
    })
    return
  end

  local lines = {
    string.format("Worktree status for branch '%s'", branch),
    "Path: " .. display_path(record.path),
    "Repo: " .. display_path(record.repo_root),
    "Base: " .. short_ref(record.base_ref),
    "",
  }

  append_section(
    lines,
    "Status",
    trim(status_result.stdout) ~= "" and trim(status_result.stdout)
      or "Working tree clean."
  )
  table.insert(lines, "")
  append_section(
    lines,
    "Diff stat",
    trim(stat_result.stdout) ~= "" and trim(stat_result.stdout)
      or "No changes relative to base."
  )
  table.insert(lines, "")
  append_section(
    lines,
    "Recent commits",
    trim(log_result.stdout) ~= "" and trim(log_result.stdout)
      or "No commits yet on this branch."
  )

  callback({
    content = table.concat(lines, "\n"),
    summary = string.format("%s Status for git worktree %s", icons.directory, branch),
  })
end

--- @param args table
--- @param conversation sia.Conversation
--- @param callback fun(result:sia.ToolResult)
local function diff_worktree(args, conversation, callback)
  local branch = args.branch
  if not branch or branch == "" then
    callback({ content = "Error: 'branch' parameter is required for 'diff'" })
    return
  end

  local records = worktrees[conversation.id] or {}
  local record = records[branch]
  if not record then
    callback({
      content = string.format(
        "Error: No tracked worktree found for branch '%s'",
        branch
      ),
    })
    return
  end

  local exists = workspace_exists(record)
  if not exists then
    callback({
      content = string.format(
        "Tracked worktree for branch '%s' no longer exists at %s",
        record.branch,
        display_path(record.path)
      ),
    })
    return
  end

  local diff_result = git(record.path, { "diff", "--no-ext-diff", record.base_ref })
  if diff_result.code ~= 0 then
    callback({
      content = string.format(
        "Error: Failed to diff worktree '%s': %s",
        branch,
        git_error(diff_result, "git diff failed")
      ),
    })
    return
  end

  local untracked_result =
    git(record.path, { "ls-files", "--others", "--exclude-standard" })
  if untracked_result.code ~= 0 then
    callback({
      content = string.format(
        "Error: Failed to list untracked files for '%s': %s",
        branch,
        git_error(untracked_result, "git ls-files failed")
      ),
    })
    return
  end

  local diff_output = trim(diff_result.stdout)
  local untracked_output = trim(untracked_result.stdout)
  if diff_output == "" and untracked_output == "" then
    callback({
      content = string.format("No changes in worktree '%s' relative to base.", branch),
      summary = string.format("%s No diff for git worktree %s", icons.view, branch),
      ephemeral = true,
    })
    return
  end

  local lines = {
    string.format("Diff for worktree '%s'", branch),
    "Path: " .. display_path(record.path),
    "Base: " .. short_ref(record.base_ref),
    "",
  }

  if diff_output ~= "" then
    local diff_lines = vim.split(diff_output, "\n", { plain = true })
    if #diff_lines > MAX_DIFF_LINES then
      local truncated = vim.list_slice(diff_lines, 1, MAX_DIFF_LINES)
      table.insert(
        truncated,
        string.format("... diff truncated (%d total lines).", #diff_lines)
      )
      diff_lines = truncated
    end

    append_section(lines, "Patch", diff_lines)
  end

  if untracked_output ~= "" then
    if diff_output ~= "" then
      table.insert(lines, "")
    end
    append_section(lines, "Untracked files", untracked_output)
  end

  callback({
    content = table.concat(lines, "\n"),
    summary = string.format("%s Diffed git worktree %s", icons.view, branch),
  })
end

--- @param args table
--- @param conversation sia.Conversation
--- @param callback fun(result:sia.ToolResult)
local function remove_worktree(args, conversation, callback)
  local branch = args.branch
  if not branch or branch == "" then
    callback({ content = "Error: 'branch' parameter is required for 'remove'" })
    return
  end

  local records = worktrees[conversation.id] or {}
  local record = records[branch]
  if not record then
    callback({
      content = string.format(
        "Error: No tracked worktree found for branch '%s'",
        branch
      ),
    })
    return
  end

  local remove_result =
    git(record.repo_root, { "worktree", "remove", "--force", record.path })
  if remove_result.code ~= 0 then
    callback({
      content = string.format(
        "Error: Failed to remove worktree '%s': %s",
        branch,
        git_error(remove_result, "git worktree remove failed")
      ),
    })
    return
  end

  remove_record(conversation.id, branch)

  local delete_branch_result = git(record.repo_root, { "branch", "-D", branch })
  if delete_branch_result.code ~= 0 then
    callback({
      content = table.concat({
        string.format("Worktree directory for '%s' was removed.", branch),
        string.format(
          "Branch deletion failed: %s",
          git_error(delete_branch_result, "git branch -D failed")
        ),
      }, "\n"),
      summary = string.format("%s Removed git worktree %s", icons.delete, branch),
    })
    return
  end

  callback({
    content = table.concat({
      "Worktree removed.",
      "Path: " .. record.path,
      "Branch deleted: " .. branch,
    }, "\n"),
    summary = string.format("%s Removed git worktree %s", icons.delete, branch),
  })
end

return tool_utils.new_tool({
  definition = {
    type = "function",
    name = tool_names.git_worktree,
    description = "Create, inspect, and remove tracked git worktrees for the current conversation",
    parameters = {
      command = {
        type = "string",
        enum = { "create", "status", "list", "diff", "remove" },
        description = "The command to execute: create a worktree, inspect it, list tracked worktrees, show a diff, or remove it",
      },
      branch = {
        type = "string",
        description = "Branch name. Required for create, status, diff, and remove.",
      },
      base = {
        type = "string",
        description = "Base ref to branch from. Only used by create and defaults to HEAD.",
      },
    },
    required = { "command" },
  },
  summary = summary,
  instructions = [[Manage tracked git worktrees for the current conversation.

- Use `create` to make an isolated worktree for delegated work. If the branch already exists, it will be checked out in the new worktree. If the branch is new, it will be created from the `base` ref (default: HEAD).
- Use `list` to see which worktrees this conversation already owns
- Use `status` to inspect status, diff stats, and recent commits for one tracked branch
- Use `diff` to inspect the full patch relative to the base commit used at creation time
- Use `remove` to delete the worktree directory and the branch
- Closing the conversation automatically removes tracked worktree directories, but keeps the branch so work is not lost
- After `create`, pass the returned path as `workspace` when starting an agent]],
}, function(args, conversation, callback, opts)
  if args.command == "create" then
    local branch = args.branch or "<missing branch>"
    opts.user_input(
      string.format(
        "Create git worktree branch '%s'%s",
        branch,
        args.base and (" from " .. args.base) or ""
      ),
      {
        on_accept = function()
          create_worktree(args, conversation, callback)
        end,
      }
    )
    return
  end

  if args.command == "remove" then
    local branch = args.branch or "<missing branch>"
    opts.user_input(
      string.format("Remove git worktree branch '%s' and delete the branch", branch),
      {
        -- level = "warn",
        on_accept = function()
          remove_worktree(args, conversation, callback)
        end,
      }
    )
    return
  end

  if args.command == "list" then
    list_worktrees(conversation, callback)
  elseif args.command == "status" then
    status_worktree(args, conversation, callback)
  elseif args.command == "diff" then
    diff_worktree(args, conversation, callback)
  else
    callback({
      content = string.format(
        "Error: Unknown command '%s'. Expected one of: create, status, list, diff, remove",
        tostring(args.command)
      ),
    })
  end
end)
