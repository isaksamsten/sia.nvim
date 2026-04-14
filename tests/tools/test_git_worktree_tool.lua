local child = MiniTest.new_child_neovim()
local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      child.restart({ "-u", "assets/minimal.lua" })
    end,
    post_once = function()
      child.stop()
    end,
  },
})

local eq = MiniTest.expect.equality

T["sia.tools.git_worktree"] = MiniTest.new_set()

T["sia.tools.git_worktree"]["create and list track a new worktree"] = function()
  child.lua([[
    local git_worktree = require("sia.tools.git_worktree")

    local function git(cwd, args)
      local result = vim.system(vim.list_extend({ "git" }, args), {
        cwd = cwd,
        text = true,
      }):wait()
      if result.code ~= 0 then
        error((result.stderr ~= "" and result.stderr) or result.stdout)
      end
      return vim.trim(result.stdout or "")
    end

    local function create_repo()
      local repo = vim.fn.tempname() .. "_repo"
      vim.fn.mkdir(repo, "p")
      git(repo, { "init" })
      git(repo, { "config", "user.email", "sia@example.com" })
      git(repo, { "config", "user.name", "Sia Test" })
      vim.fn.writefile({ "base" }, repo .. "/README.md")
      git(repo, { "add", "README.md" })
      git(repo, { "commit", "-m", "Initial commit" })
      return repo
    end

    local repo = create_repo()
    local conversation = {
      id = 201,
      workspace = repo,
      approved_tools = { git_worktree = true },
    }

    local created = nil
    git_worktree.implementation.execute({
      command = "create",
      branch = "feature/test-list",
    }, function(res)
      created = res
    end, {
      conversation = conversation,
    })

    vim.wait(2000, function()
      return created ~= nil
    end)

    local listed = nil
    git_worktree.implementation.execute({
      command = "list",
    }, function(res)
      listed = res
    end, {
      conversation = conversation,
    })

    local path = created.content:match("Path: ([^\n]+)")
    local branch_exists = git(repo, { "branch", "--list", "feature/test-list" })
    local path_exists = path and (vim.fn.isdirectory(path) == 1) or false

    git_worktree.implementation.execute({
      command = "remove",
      branch = "feature/test-list",
    }, function() end, {
      conversation = conversation,
    })

    vim.fn.delete(repo, "rf")

    _G.result = {
      created = created,
      listed = listed,
      path_exists = path_exists,
      branch_exists = branch_exists,
    }
  ]])

  local result = child.lua_get("_G.result")

  eq(true, result.created.content:find("Worktree created.", 1, true) ~= nil)
  eq(true, result.listed.content:find("feature/test%-list", 1) ~= nil)
  eq(true, result.path_exists)
  eq(true, result.branch_exists:find("feature/test%-list", 1) ~= nil)
end

T["sia.tools.git_worktree"]["status and diff inspect tracked changes"] = function()
  child.lua([[
    local git_worktree = require("sia.tools.git_worktree")

    local function git(cwd, args)
      local result = vim.system(vim.list_extend({ "git" }, args), {
        cwd = cwd,
        text = true,
      }):wait()
      if result.code ~= 0 then
        error((result.stderr ~= "" and result.stderr) or result.stdout)
      end
      return vim.trim(result.stdout or "")
    end

    local function create_repo()
      local repo = vim.fn.tempname() .. "_repo"
      vim.fn.mkdir(repo, "p")
      git(repo, { "init" })
      git(repo, { "config", "user.email", "sia@example.com" })
      git(repo, { "config", "user.name", "Sia Test" })
      vim.fn.writefile({ "base" }, repo .. "/README.md")
      git(repo, { "add", "README.md" })
      git(repo, { "commit", "-m", "Initial commit" })
      return repo
    end

    local repo = create_repo()
    local conversation = {
      id = 202,
      workspace = repo,
      approved_tools = { git_worktree = true },
    }

    local created = nil
    git_worktree.implementation.execute({
      command = "create",
      branch = "feature/test-status",
    }, function(res)
      created = res
    end, {
      conversation = conversation,
    })

    vim.wait(2000, function()
      return created ~= nil
    end)

    local path = created.content:match("Path: ([^\n]+)")
    vim.fn.writefile({ "base", "updated" }, path .. "/README.md")
    vim.fn.writefile({ "note" }, path .. "/notes.txt")

    local status = nil
    git_worktree.implementation.execute({
      command = "status",
      branch = "feature/test-status",
    }, function(res)
      status = res
    end, {
      conversation = conversation,
    })

    local diff = nil
    git_worktree.implementation.execute({
      command = "diff",
      branch = "feature/test-status",
    }, function(res)
      diff = res
    end, {
      conversation = conversation,
    })

    git_worktree.implementation.execute({
      command = "remove",
      branch = "feature/test-status",
    }, function() end, {
      conversation = conversation,
    })

    vim.fn.delete(repo, "rf")

    _G.result = {
      status = status,
      diff = diff,
    }
  ]])

  local result = child.lua_get("_G.result")

  eq(true, result.status.content:find("M README%.md", 1) ~= nil)
  eq(true, result.status.content:find("%?%? notes%.txt", 1) ~= nil)
  eq(true, result.status.content:find("README%.md | 1 %+", 1) ~= nil)
  eq(true, result.diff.content:find("%+updated", 1) ~= nil)
  eq(true, result.diff.content:find("notes%.txt", 1) ~= nil)
end

T["sia.tools.git_worktree"]["remove deletes worktree and branch"] = function()
  child.lua([[
    local git_worktree = require("sia.tools.git_worktree")

    local function git(cwd, args)
      local result = vim.system(vim.list_extend({ "git" }, args), {
        cwd = cwd,
        text = true,
      }):wait()
      if result.code ~= 0 then
        error((result.stderr ~= "" and result.stderr) or result.stdout)
      end
      return vim.trim(result.stdout or "")
    end

    local function create_repo()
      local repo = vim.fn.tempname() .. "_repo"
      vim.fn.mkdir(repo, "p")
      git(repo, { "init" })
      git(repo, { "config", "user.email", "sia@example.com" })
      git(repo, { "config", "user.name", "Sia Test" })
      vim.fn.writefile({ "base" }, repo .. "/README.md")
      git(repo, { "add", "README.md" })
      git(repo, { "commit", "-m", "Initial commit" })
      return repo
    end

    local repo = create_repo()
    local conversation = {
      id = 203,
      workspace = repo,
      approved_tools = { git_worktree = true },
    }

    local created = nil
    git_worktree.implementation.execute({
      command = "create",
      branch = "feature/test-remove",
    }, function(res)
      created = res
    end, {
      conversation = conversation,
    })

    vim.wait(2000, function()
      return created ~= nil
    end)

    local path = created.content:match("Path: ([^\n]+)")
    local removed = nil
    git_worktree.implementation.execute({
      command = "remove",
      branch = "feature/test-remove",
    }, function(res)
      removed = res
    end, {
      conversation = conversation,
    })

    local branch_exists = git(repo, { "branch", "--list", "feature/test-remove" })
    local listed = nil
    git_worktree.implementation.execute({
      command = "list",
    }, function(res)
      listed = res
    end, {
      conversation = conversation,
    })

    vim.fn.delete(repo, "rf")

    _G.result = {
      removed = removed,
      listed = listed,
      path_exists = path and (vim.fn.isdirectory(path) == 1) or false,
      branch_exists = branch_exists,
    }
  ]])

  local result = child.lua_get("_G.result")

  eq(true, result.removed.content:find("Worktree removed.", 1, true) ~= nil)
  eq(false, result.path_exists)
  eq("", result.branch_exists)
  eq(true, result.listed.content:find("No tracked git worktrees", 1, true) ~= nil)
end

T["sia.tools.git_worktree"]["conversation cleanup removes worktree path but keeps branch"] = function()
  child.lua([[
    local git_worktree = require("sia.tools.git_worktree")
    local utils = require("sia.utils")

    local function git(cwd, args)
      local result = vim.system(vim.list_extend({ "git" }, args), {
        cwd = cwd,
        text = true,
      }):wait()
      if result.code ~= 0 then
        error((result.stderr ~= "" and result.stderr) or result.stdout)
      end
      return vim.trim(result.stdout or "")
    end

    local function create_repo()
      local repo = vim.fn.tempname() .. "_repo"
      vim.fn.mkdir(repo, "p")
      git(repo, { "init" })
      git(repo, { "config", "user.email", "sia@example.com" })
      git(repo, { "config", "user.name", "Sia Test" })
      vim.fn.writefile({ "base" }, repo .. "/README.md")
      git(repo, { "add", "README.md" })
      git(repo, { "commit", "-m", "Initial commit" })
      return repo
    end

    local repo = create_repo()
    local conversation = {
      id = 204,
      workspace = repo,
      approved_tools = { git_worktree = true },
    }

    local created = nil
    git_worktree.implementation.execute({
      command = "create",
      branch = "feature/test-cleanup",
    }, function(res)
      created = res
    end, {
      conversation = conversation,
    })

    vim.wait(2000, function()
      return created ~= nil
    end)

    local path = created.content:match("Path: ([^\n]+)")
    utils.trigger("ConversationDestroyed", {
      conversation_id = conversation.id,
      workspace = repo,
    })

    local branch_exists = git(repo, { "branch", "--list", "feature/test-cleanup" })
    local listed = nil
    git_worktree.implementation.execute({
      command = "list",
    }, function(res)
      listed = res
    end, {
      conversation = conversation,
    })

    git(repo, { "branch", "-D", "feature/test-cleanup" })
    vim.fn.delete(repo, "rf")

    _G.result = {
      listed = listed,
      path_exists = path and (vim.fn.isdirectory(path) == 1) or false,
      branch_exists = branch_exists,
    }
  ]])

  local result = child.lua_get("_G.result")

  eq(false, result.path_exists)
  eq(true, result.branch_exists:find("feature/test%-cleanup", 1) ~= nil)
  eq(true, result.listed.content:find("No tracked git worktrees", 1, true) ~= nil)
end

T["sia.tools.git_worktree"]["tool metadata exposes supported commands"] = function()
  child.lua([[
    local git_worktree = require("sia.tools.git_worktree")
    _G.metadata = {
      name = git_worktree.definition.name,
      description = git_worktree.definition.description,
      commands = git_worktree.definition.parameters.command.enum,
    }
  ]])

  local metadata = child.lua_get("_G.metadata")

  eq("git_worktree", metadata.name)
  eq(
    true,
    metadata.description:find("Create, inspect, and remove tracked git worktrees", 1, true)
      ~= nil
  )
  eq({ "create", "status", "list", "diff", "remove" }, metadata.commands)
end

T["sia.tools.git_worktree"]["create attaches to an existing branch"] = function()
  child.lua([[
    local git_worktree = require("sia.tools.git_worktree")

    local function git(cwd, args)
      local result = vim.system(vim.list_extend({ "git" }, args), {
        cwd = cwd,
        text = true,
      }):wait()
      if result.code ~= 0 then
        error((result.stderr ~= "" and result.stderr) or result.stdout)
      end
      return vim.trim(result.stdout or "")
    end

    local function create_repo()
      local repo = vim.fn.tempname() .. "_repo"
      vim.fn.mkdir(repo, "p")
      git(repo, { "init" })
      git(repo, { "config", "user.email", "sia@example.com" })
      git(repo, { "config", "user.name", "Sia Test" })
      vim.fn.writefile({ "base" }, repo .. "/README.md")
      git(repo, { "add", "README.md" })
      git(repo, { "commit", "-m", "Initial commit" })
      return repo
    end

    local repo = create_repo()

    -- Create an existing branch with a commit
    git(repo, { "branch", "feature/existing" })
    git(repo, { "checkout", "feature/existing" })
    vim.fn.writefile({ "base", "from-branch" }, repo .. "/README.md")
    git(repo, { "add", "README.md" })
    git(repo, { "commit", "-m", "Branch commit" })
    local branch_tip = git(repo, { "rev-parse", "HEAD" })
    git(repo, { "checkout", "-" })

    local conversation = {
      id = 205,
      workspace = repo,
      approved_tools = { git_worktree = true },
    }

    local created = nil
    git_worktree.implementation.execute({
      command = "create",
      branch = "feature/existing",
    }, function(res)
      created = res
    end, {
      conversation = conversation,
    })

    vim.wait(2000, function()
      return created ~= nil
    end)

    local path = created.content:match("Path: ([^\n]+)")
    local readme = vim.fn.readfile(path .. "/README.md")

    git_worktree.implementation.execute({
      command = "remove",
      branch = "feature/existing",
    }, function() end, {
      conversation = conversation,
    })

    vim.fn.delete(repo, "rf")

    _G.result = {
      created = created,
      has_attached_message = created.content:find("Attached to existing branch", 1, true) ~= nil,
      readme = readme,
      branch_tip = branch_tip,
    }
  ]])

  local result = child.lua_get("_G.result")

  eq(true, result.created.content:find("Worktree created.", 1, true) ~= nil)
  eq(true, result.has_attached_message)
  -- Verify the worktree has the branch's content
  eq({ "base", "from-branch" }, result.readme)
end

T["sia.tools.git_worktree"]["create errors when branch is checked out in another worktree"] = function()
  child.lua([[
    local git_worktree = require("sia.tools.git_worktree")

    local function git(cwd, args)
      local result = vim.system(vim.list_extend({ "git" }, args), {
        cwd = cwd,
        text = true,
      }):wait()
      if result.code ~= 0 then
        error((result.stderr ~= "" and result.stderr) or result.stdout)
      end
      return vim.trim(result.stdout or "")
    end

    local function create_repo()
      local repo = vim.fn.tempname() .. "_repo"
      vim.fn.mkdir(repo, "p")
      git(repo, { "init" })
      git(repo, { "config", "user.email", "sia@example.com" })
      git(repo, { "config", "user.name", "Sia Test" })
      vim.fn.writefile({ "base" }, repo .. "/README.md")
      git(repo, { "add", "README.md" })
      git(repo, { "commit", "-m", "Initial commit" })
      return repo
    end

    local repo = create_repo()

    -- Create a worktree for the branch externally
    local external_path = vim.fn.tempname() .. "_ext_wt"
    git(repo, { "worktree", "add", "-b", "feature/occupied", external_path })

    local conversation = {
      id = 206,
      workspace = repo,
      approved_tools = { git_worktree = true },
    }

    local created = nil
    git_worktree.implementation.execute({
      command = "create",
      branch = "feature/occupied",
    }, function(res)
      created = res
    end, {
      conversation = conversation,
    })

    vim.wait(2000, function()
      return created ~= nil
    end)

    -- Cleanup: remove the external worktree
    git(repo, { "worktree", "remove", "--force", external_path })
    git(repo, { "branch", "-D", "feature/occupied" })
    vim.fn.delete(repo, "rf")

    _G.result = {
      created = created,
      is_error = created.content:find("already checked out", 1, true) ~= nil,
    }
  ]])

  local result = child.lua_get("_G.result")

  eq(true, result.is_error)
end

T["sia.tools.git_worktree"]["create re-adopts an orphaned worktree"] = function()
  child.lua([[
    local git_worktree = require("sia.tools.git_worktree")
    local utils = require("sia.utils")

    local function git(cwd, args)
      local result = vim.system(vim.list_extend({ "git" }, args), {
        cwd = cwd,
        text = true,
      }):wait()
      if result.code ~= 0 then
        error((result.stderr ~= "" and result.stderr) or result.stdout)
      end
      return vim.trim(result.stdout or "")
    end

    local function create_repo()
      local repo = vim.fn.tempname() .. "_repo"
      vim.fn.mkdir(repo, "p")
      git(repo, { "init" })
      git(repo, { "config", "user.email", "sia@example.com" })
      git(repo, { "config", "user.name", "Sia Test" })
      vim.fn.writefile({ "base" }, repo .. "/README.md")
      git(repo, { "add", "README.md" })
      git(repo, { "commit", "-m", "Initial commit" })
      return repo
    end

    local repo = create_repo()
    local conversation = {
      id = 207,
      workspace = repo,
      approved_tools = { git_worktree = true },
    }

    -- Step 1: create a worktree normally
    local created = nil
    git_worktree.implementation.execute({
      command = "create",
      branch = "feature/orphan-test",
    }, function(res)
      created = res
    end, {
      conversation = conversation,
    })

    vim.wait(2000, function()
      return created ~= nil
    end)

    local path = created.content:match("Path: ([^\n]+)")

    -- Make a change in the worktree so we can verify it survives
    vim.fn.writefile({ "orphan-content" }, path .. "/orphan.txt")

    -- Step 2: simulate a crash by firing ConversationDestroyed
    -- This removes the worktree from module state but the worktree
    -- directory and branch survive because cleanup only does
    -- `git worktree remove` (which detaches the directory).
    -- However, for this test we need the directory to survive,
    -- so we clear the module state directly without removing the
    -- worktree directory.
    -- We re-create the worktree tracking manually to simulate
    -- state loss (the directory stays, tracking is gone).
    -- Actually, let's just create a fresh worktree externally at
    -- the same cache path that create_worktree would use.

    -- Remove tracking but keep the worktree directory intact
    -- by requiring a fresh module state (simulate restart).
    -- Since we can't easily unload a module, we'll directly
    -- manipulate: destroy fires cleanup which removes the directory.
    -- Instead, let's create the orphan scenario manually:
    -- 1. Remove the record from tracking
    -- 2. The worktree directory still exists on disk
    -- 3. A new create call should re-adopt it

    -- Clear the module's tracking for this conversation
    utils.trigger("ConversationDestroyed", {
      conversation_id = conversation.id,
      workspace = repo,
    })

    -- The cleanup removed the worktree directory. Re-create it
    -- externally to simulate an orphan (e.g., cleanup failed or
    -- Neovim crashed before cleanup ran).
    local orphan_path = utils.dirs.worktrees(conversation.id) .. "/feature/orphan-test"
    git(repo, { "worktree", "add", orphan_path, "feature/orphan-test" })
    vim.fn.writefile({ "orphan-content" }, orphan_path .. "/orphan.txt")

    -- Step 3: create again with the same branch — should re-adopt
    local readopted = nil
    git_worktree.implementation.execute({
      command = "create",
      branch = "feature/orphan-test",
    }, function(res)
      readopted = res
    end, {
      conversation = conversation,
    })

    vim.wait(2000, function()
      return readopted ~= nil
    end)

    local readopted_path = readopted.content:match("Path: ([^\n]+)")
    local orphan_file = vim.fn.readfile(readopted_path .. "/orphan.txt")

    -- Cleanup
    git_worktree.implementation.execute({
      command = "remove",
      branch = "feature/orphan-test",
    }, function() end, {
      conversation = conversation,
    })

    vim.fn.delete(repo, "rf")

    _G.result = {
      readopted = readopted,
      has_readopt_message = readopted.content:find("Re-adopted orphaned worktree", 1, true) ~= nil,
      has_created_message = readopted.content:find("Worktree created.", 1, true) ~= nil,
      orphan_file = orphan_file,
    }
  ]])

  local result = child.lua_get("_G.result")

  eq(true, result.has_created_message)
  eq(true, result.has_readopt_message)
  -- Verify the orphan's content survived
  eq({ "orphan-content" }, result.orphan_file)
end

return T
