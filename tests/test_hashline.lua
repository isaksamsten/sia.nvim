local hashline = require("sia.hashline")
local eq = MiniTest.expect.equality
local conversation, lines, tag
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      conversation = {}
      lines = { "one", "  two", "three", "four" }
      tag = hashline.view(conversation, "/test", lines, 1, 4)[1]:match("#(%x+)%]")
    end,
  },
})
local function apply(input, source, owner, snapshot)
  return hashline.apply(
    owner or conversation,
    "/test",
    source or lines,
    snapshot or tag,
    input
  )
end

T["formats compact rows preserving whitespace"] = function()
  local output = hashline.view(conversation, "/test", lines, 2, 3)
  eq(output, { "[/test#" .. tag .. "]", "2:  two", "3:three" })
end
T["applies multiple operations against original numbers"] = function()
  eq(
    apply("PUT 1.=1:\n+first\n+extra\nCUT 3.=3\nPUT >4:\n+last"),
    { "first", "extra", "  two", "four", "last" }
  )
  eq(lines, { "one", "  two", "three", "four" })
end
T["supports ranges, gaps, blanks and literal plus"] = function()
  eq(
    apply("PUT 2.=3:\n+  changed\n+\n++literal\nPUT <1:\n+head\nPUT >$:\n+tail"),
    { "head", "one", "  changed", "", "+literal", "four", "tail" }
  )
end
T["keeps adjacent insertions and replacements in order"] = function()
  eq(
    apply("PUT 2.=2:\n+replace\nPUT <2:\n+before\nPUT >2:\n+after"),
    { "one", "before", "replace", "after", "three", "four" }
  )
  eq(apply("PUT >1:\n+a\nPUT >1:\n+b"), { "one", "a", "b", "  two", "three", "four" })
end
T["rejects stale, missing and other conversation snapshots"] = function()
  eq(apply("CUT 1.=1", { "changed", "  two", "three", "four" }), nil)
  eq(apply("CUT 1.=1", nil, {}), nil)
  eq(apply("CUT 1.=1", nil, nil, "bad"), nil)
end
T["rejects unseen and truncated ranges and anchors"] = function()
  conversation = {}
  tag = hashline.view(conversation, "/test", lines, 1, 2, 3)[1]:match("#(%x+)%]")
  eq(apply("CUT 1.=3"), nil)
  eq(apply("PUT >2:\n+x"), nil)
  eq(apply("PUT >$:\n+x"), nil)
  hashline.view(conversation, "/test", lines, 2, 4)
  eq(apply("CUT 2.=4"), { "one" })
end
T["new snapshot clears previously seen lines"] = function()
  lines[1] = "new"
  tag = hashline.view(conversation, "/test", lines, 1, 1)[1]:match("#(%x+)%]")
  eq(apply("CUT 2.=2"), nil)
end
T["rejects malformed batches without modifying input"] = function()
  for _, input in ipairs({
    "",
    "\n",
    "+orphan",
    "PUT 1.=1:",
    "CUT 1.=1\n+body",
    "CUT 0.=1",
    "CUT 3.=2",
    "CUT 1.=5",
    "PUT >0:\n+x",
    "PUT <$:\n+x",
    "PUT >2$:\n+x",
    "PUT 1*:\n+x",
    "CUT 1.=1\nunsupported",
    "CUT 1.=2\nCUT 2.=3",
    "CUT 1.=3\nPUT >2:\n+x",
    "PUT >2:\n+x\nCUT 1.=3",
  }) do
    local result, err = apply(input)
    eq(result, nil)
    eq(type(err), "string")
    eq(lines, { "one", "  two", "three", "four" })
  end
end
T["whole-file deletion yields an empty buffer"] = function()
  eq(apply("CUT 1.=4"), { "" })
end
T["empty files accept insertion"] = function()
  lines = { "" }
  tag = hashline.view(conversation, "/test", lines, 1, 1)[1]:match("#(%x+)%]")
  eq(apply("PUT 1.=1:\n+hello"), { "hello" })
end
return T
