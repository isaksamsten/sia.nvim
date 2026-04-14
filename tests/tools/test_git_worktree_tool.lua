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
      path_exists = path and (vim.fn.isdirectory(path) == 1) or false,
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

return T
