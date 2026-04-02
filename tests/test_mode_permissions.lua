local permissions = require("sia.permissions")
local utils = require("sia.tools.utils")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

--- Helper to create a compiled mode allow rule from raw patterns.
--- @param allow_rules table<string, true|{arguments: table<string, string[]>}>
--- @return table<string, true|{arguments: table<string, string[]>}>
local function make_allow(allow_rules)
  return allow_rules
end

--- Create an active mode for testing.
--- @param opts { name: string, deny: string[]?, allow: table<string, any>?, deny_message: function? }
--- @return sia.ActiveMode
local function make_mode(opts)
  return permissions.create_active_mode(opts.name, {
    permissions = {
      deny = opts.deny,
      allow = opts.allow and make_allow(opts.allow) or nil,
    },
    deny_message = opts.deny_message,
    enter_prompt = "",
    exit_prompt = "",
  })
end

local function create_dummy_tool(name, read_only, runner)
  return utils.new_tool({
    definition = {
      name = name,
      description = "dummy",
      required = {},
      parameters = {},
    },
    read_only = read_only,
  }, function(args, conversation, callback, opts)
    runner(args, conversation, callback, opts)
  end)
end

-- ─── resolve_mode_permission ────────────────────────────────────────────

T["mode permissions"] = MiniTest.new_set()

T["mode permissions"]["deny blocks tool"] = function()
  local mode = make_mode({ name = "plan", deny = { "bash", "agent" } })

  local result = permissions.resolve_mode_permission(mode, "bash", {})
  eq(true, result.deny)
  eq("OPERATION BLOCKED BY CURRENT MODE (plan)", result.reason[1])
end

T["mode permissions"]["deny does not affect unlisted tool"] = function()
  local mode = make_mode({ name = "plan", deny = { "bash" } })

  local result = permissions.resolve_mode_permission(mode, "view", {})
  eq(nil, result)
end

T["mode permissions"]["blanket allow auto-approves"] = function()
  local mode = make_mode({ name = "plan", allow = { view = true, grep = true } })

  local result = permissions.resolve_mode_permission(mode, "view", {})
  eq(1, result.auto_allow)
end

T["mode permissions"]["blanket allow does not affect unlisted tool"] = function()
  local mode = make_mode({ name = "plan", allow = { view = true } })

  local result = permissions.resolve_mode_permission(mode, "bash", {})
  eq(nil, result)
end

T["mode permissions"]["conditional allow approves matching args"] = function()
  local mode = make_mode({
    name = "plan",
    allow = {
      write = { arguments = { path = { "^plan_.*\\.md$" } } },
    },
  })

  local result =
    permissions.resolve_mode_permission(mode, "write", { path = "plan_config.md" })
  eq(1, result.auto_allow)
end

T["mode permissions"]["conditional allow denies non-matching args"] = function()
  local mode = make_mode({
    name = "plan",
    allow = {
      write = { arguments = { path = { "^plan_.*\\.md$" } } },
    },
  })

  local result =
    permissions.resolve_mode_permission(mode, "write", { path = "main.lua" })
  eq(true, result.deny)
  eq("OPERATION RESTRICTED BY CURRENT MODE (plan)", result.reason[1])
end

T["mode permissions"]["conditional allow with multiple patterns matches any"] = function()
  local mode = make_mode({
    name = "plan",
    allow = {
      write = { arguments = { path = { "^plan_.*\\.md$", "^\\.sia/plans/" } } },
    },
  })

  local r1 =
    permissions.resolve_mode_permission(mode, "write", { path = "plan_foo.md" })
  eq(1, r1.auto_allow)

  local r2 =
    permissions.resolve_mode_permission(mode, "write", { path = ".sia/plans/v1.md" })
  eq(1, r2.auto_allow)

  local r3 =
    permissions.resolve_mode_permission(mode, "write", { path = "src/main.lua" })
  eq(true, r3.deny)
end

T["mode permissions"]["conditional allow with multiple argument keys requires all to match"] = function()
  local mode = make_mode({
    name = "plan",
    allow = {
      edit = {
        arguments = {
          target_file = { "^plan_.*\\.md$" },
          old_string = { "." },
        },
      },
    },
  })

  -- Both match
  local r1 = permissions.resolve_mode_permission(
    mode,
    "edit",
    { target_file = "plan_config.md", old_string = "something" }
  )
  eq(1, r1.auto_allow)

  -- File matches but old_string is empty → "." requires at least 1 char → deny
  local r2 = permissions.resolve_mode_permission(
    mode,
    "edit",
    { target_file = "plan_config.md", old_string = "" }
  )
  eq(true, r2.deny)

  -- File doesn't match
  local r3 = permissions.resolve_mode_permission(
    mode,
    "edit",
    { target_file = "main.lua", old_string = "something" }
  )
  eq(true, r3.deny)
end

T["mode permissions"]["deny takes priority over allow for the same tool"] = function()
  -- If a tool is in both deny and allow, deny wins because it's checked first
  local mode = make_mode({
    name = "strict",
    deny = { "write" },
    allow = { write = true },
  })

  local result = permissions.resolve_mode_permission(mode, "write", {})
  eq(true, result.deny)
  eq("OPERATION BLOCKED BY CURRENT MODE (strict)", result.reason[1])
end

T["mode permissions"]["no permissions returns nil for all tools"] = function()
  local mode = permissions.create_active_mode("empty", {
    enter_prompt = "",
    exit_prompt = "",
  })

  eq(nil, permissions.resolve_mode_permission(mode, "view", {}))
  eq(nil, permissions.resolve_mode_permission(mode, "bash", {}))
end

T["mode permissions"]["custom deny_message is used when provided"] = function()
  local mode = make_mode({
    name = "plan",
    deny = { "bash" },
    deny_message = function(tool_name, _, kind)
      return { string.format("CUSTOM: %s %s in plan", tool_name, kind) }
    end,
  })

  local result = permissions.resolve_mode_permission(mode, "bash", {})
  eq(true, result.deny)
  eq("CUSTOM: bash denied in plan", result.reason[1])
end

T["mode permissions"]["custom deny_message is used for restricted too"] = function()
  local mode = make_mode({
    name = "plan",
    allow = {
      write = { arguments = { path = { "^plan" } } },
    },
    deny_message = function(tool_name, _, kind)
      return { string.format("CUSTOM: %s %s", tool_name, kind) }
    end,
  })

  local result =
    permissions.resolve_mode_permission(mode, "write", { path = "main.lua" })
  eq(true, result.deny)
  eq("CUSTOM: write restricted", result.reason[1])
end

T["mode permissions"]["compiled allow is cached"] = function()
  local mode = make_mode({
    name = "plan",
    allow = { view = true },
  })

  -- First call compiles
  permissions.resolve_mode_permission(mode, "view", {})
  local first_cache = mode._compiled_allow

  -- Second call should use the same cache
  permissions.resolve_mode_permission(mode, "view", {})
  eq(true, first_cache == mode._compiled_allow)
end

-- ─── Integration with tool execution ────────────────────────────────────

T["mode tool integration"] = MiniTest.new_set()

T["mode tool integration"]["mode deny blocks tool execution"] = function()
  local mode = make_mode({ name = "plan", deny = { "dummy" } })

  local executed = false
  local tool = create_dummy_tool("dummy", false, function(_, _, callback, _)
    executed = true
    callback({ kind = "ok", content = { "ran" } })
  end)

  local result
  tool.implementation.execute({}, function(res)
    result = res
  end, { conversation = { auto_confirm_tools = {}, active_mode = mode } })

  eq(false, executed)
  eq("OPERATION BLOCKED BY CURRENT MODE (plan)", result.content[1])
end

T["mode tool integration"]["mode allow auto-approves tool execution"] = function()
  local mode = make_mode({ name = "plan", allow = { dummy = true } })

  local executed = false
  local tool = create_dummy_tool("dummy", true, function(_, _, callback, _)
    executed = true
    callback({ kind = "ok", content = { "ran" } })
  end)

  local result
  tool.implementation.execute({}, function(res)
    result = res
  end, { conversation = { auto_confirm_tools = {}, active_mode = mode } })

  eq(true, executed)
  eq("ok", result.kind)
end

T["mode tool integration"]["mode conditional allow blocks non-matching args"] = function()
  local mode = make_mode({
    name = "plan",
    allow = {
      dummy = { arguments = { path = { "^plan_" } } },
    },
  })

  local executed = false
  local tool = create_dummy_tool("dummy", false, function(_, _, callback, _)
    executed = true
    callback({ kind = "ok", content = { "ran" } })
  end)

  local result
  tool.implementation.execute({ path = "main.lua" }, function(res)
    result = res
  end, { conversation = { auto_confirm_tools = {}, active_mode = mode } })

  eq(false, executed)
  eq("OPERATION RESTRICTED BY CURRENT MODE (plan)", result.content[1])
end

T["mode tool integration"]["mode conditional allow approves matching args"] = function()
  local mode = make_mode({
    name = "plan",
    allow = {
      dummy = { arguments = { path = { "^plan_" } } },
    },
  })

  local executed = false
  local tool = create_dummy_tool("dummy", true, function(_, _, callback, _)
    executed = true
    callback({ kind = "ok", content = { "ran" } })
  end)

  local result
  tool.implementation.execute({ path = "plan_config.md" }, function(res)
    result = res
  end, { conversation = { auto_confirm_tools = {}, active_mode = mode } })

  eq(true, executed)
  eq("ok", result.kind)
end

T["mode tool integration"]["unlisted tool falls through to default behavior"] = function()
  local mode = make_mode({ name = "plan", deny = { "bash" } })

  local executed = false
  local tool = create_dummy_tool("dummy", true, function(_, _, callback, _)
    executed = true
    callback({ kind = "ok", content = { "ran" } })
  end)

  local result
  tool.implementation.execute({}, function(res)
    result = res
  end, { conversation = { auto_confirm_tools = { dummy = 1 }, active_mode = mode } })

  eq(true, executed)
  eq("ok", result.kind)
end

T["mode tool integration"]["mode deny blocks even when auto_confirm is set for the tool"] = function()
  local mode = make_mode({ name = "plan", deny = { "dummy" } })

  local executed = false
  local tool = create_dummy_tool("dummy", true, function(_, _, callback, _)
    executed = true
    callback({ kind = "ok", content = { "ran" } })
  end)

  local result
  tool.implementation.execute({}, function(res)
    result = res
  end, { conversation = { auto_confirm_tools = { dummy = 1 }, active_mode = mode } })

  eq(false, executed)
  eq("OPERATION BLOCKED BY CURRENT MODE (plan)", result.content[1])
end

-- ─── create_active_mode ─────────────────────────────────────────────────

T["create_active_mode"] = MiniTest.new_set()

T["create_active_mode"]["sets name and state from init_state"] = function()
  local mode = permissions.create_active_mode("plan", {
    enter_prompt = "",
    exit_prompt = "",
    init_state = function()
      return { plan_file = "plan_42" }
    end,
  })

  eq("plan", mode.name)
  eq("plan_42", mode.state.plan_file)
end

T["create_active_mode"]["defaults state to empty table when no init_state"] = function()
  local mode = permissions.create_active_mode("plan", {
    enter_prompt = "",
    exit_prompt = "",
  })

  eq("plan", mode.name)
  eq({}, mode.state)
end

return T
