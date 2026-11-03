local activity = require("sia.activity")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["pending previews exclude hidden and non-text context"] = function()
  eq({ "↳ visible query" }, activity.pending({
    { content = "secret", hide = true },
    { content = { { type = "text", text = "attachment" } } },
    { content = " \n " },
    { content = "visible\n\tquery" },
  }))
end

T["pending previews bound both count and Unicode length"] = function()
  local previews = activity.pending({
    { content = string.rep("å", 121) },
    { content = "second" },
    { content = "third" },
    { content = "fourth" },
    { content = "hidden", hide = true },
  }, { content = "mode query", hidden_messages = { "secret" } })
  eq({
    "↳ " .. string.rep("å", 119) .. "…",
    "↳ second",
    "↳ third",
    "+2 more pending",
  }, previews)
end

T["pending mode queries are visible without exposing hidden messages"] = function()
  eq({ "↳ mode query" }, activity.pending({}, {
    content = "mode query",
    hidden_messages = { "secret" },
  }))
  eq({}, activity.pending({}, { hidden_messages = { "secret" } }))
  eq({}, activity.pending({}))
end

T["verification uses the existing activity line and restores normal progress"] = function()
  local state = activity.new()
  local statuses = {
    { name = "bash", status = "running", verifying = true, activity = { header = "Run checks" } },
  }
  activity.tools(state, statuses)
  eq("Verifying bash…", state.message)
  eq("tools", state.phase)
  eq(0, state.completed)
  statuses[1].verifying = false
  activity.tools(state, statuses)
  eq("Run checks", state.message)
  statuses[1].status = "done"
  activity.tools(state, statuses)
  eq("Waiting for model…", state.message)
  eq(1, state.completed)
end

T["verification stays visible alongside other running tools"] = function()
  local state = activity.new()
  activity.tools(state, {
    { name = "grep", status = "running" },
    { name = "bash", status = "running", verifying = true },
  })
  eq("Verifying bash… (+1 running)", state.message)
end

return T

