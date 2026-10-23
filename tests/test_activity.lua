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

return T

