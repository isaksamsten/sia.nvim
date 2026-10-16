local hashline = require("sia.hashline")
local eq = MiniTest.expect.equality
local conversation, lines
local next_id = 0
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      next_id = next_id + 1
      conversation = { id = "clipboard-test-" .. next_id }
      lines = { "one", "two", "three", "four" }
    end,
    post_case = function()
      hashline.clear_clipboard(conversation.id)
    end,
  },
})
local function stage(input, owner, source, path)
  owner, source, path = owner or conversation, source or lines, path or "/test"
  local tag = hashline.view(owner, path, source, 1, #source)[1]:match("#(%x+)%]")
  return hashline.apply(owner, path, source, tag, input)
end
local function capture(input)
  local result, err, commit = stage(input or "CUT 2.=3 @part")
  assert(result, err)
  assert(commit)
  commit()
  return result
end
T["named and anonymous cuts paste against original line numbers"] = function()
  eq(stage("CUT 2.=3 @part\nPUT >4 @part"), { "one", "four", "two", "three" })
  eq(stage("CUT 2.=3\nPUT <1"), { "two", "three", "one", "four" })
end
T["registers persist across files and calls by conversation id"] = function()
  eq(capture(), { "one", "four" })
  local same_id = { id = conversation.id }
  eq(
    stage("PUT >$ @part", same_id, { "destination" }, "/destination"),
    { "destination", "two", "three" }
  )
  eq(stage("PUT 1.=2 @part", same_id), { "two", "three", "three", "four" })
  -- Pasting copies a register; it remains available for another paste.
  eq(stage("PUT <1 @part", same_id), { "two", "three", "one", "two", "three", "four" })
end
T["different conversation ids cannot read each other's registers"] = function()
  capture()
  local result, err = stage("PUT >$ @part", { id = conversation.id .. "-other" })
  eq(result, nil)
  eq(err, "Unknown clipboard register: @part")
end
T["named register operations require a conversation id"] = function()
  for _, input in ipairs({ "CUT 1.=1 @part", "PUT >$ @part", "PUT 1.=1 @part" }) do
    local result, err = stage(input, {})
    eq(result, nil)
    eq(err, "Clipboard registers require a conversation id.")
  end
end
T["staging cuts does not publish registers"] = function()
  local result, err, commit = stage("CUT 2.=3 @part")
  assert(result, err)
  eq(stage("PUT >$ @part"), nil)
  commit()
  eq(stage("PUT >$ @part"), { "one", "two", "three", "four", "two", "three" })
end
T["invalid and overlapping batches preserve existing registers"] = function()
  capture()
  for _, input in ipairs({
    "CUT 1.=1 @part\nunsupported",
    "CUT 1.=2 @part\nPUT 2.=3 @part",
    "CUT 1.=1 @part\nPUT >$ @missing",
    "CUT 1.=1 @part\n+invalid body",
  }) do
    eq(stage(input), nil)
    eq(stage("PUT 1.=4 @part"), { "two", "three" })
  end
end
T["register and anonymous pastes reject bodies and invalid syntax"] = function()
  capture()
  for _, input in ipairs({
    "PUT >1: @part",
    "PUT >1 @part\n+body",
    "PUT 1.=2 @part\n+body",
    "PUT >1 @invalid.name",
    "CUT 1.=1 @invalid.name",
    "PUT 1.=1",
  }) do
    eq(stage(input), nil)
  end
end
T["anonymous pastes require an unambiguous cut in the current call"] = function()
  eq(stage("PUT >$"), nil)
  eq(stage("CUT 1.=1\nCUT 2.=2\nPUT >$"), nil)
  eq(stage("CUT 1.=1 @named\nPUT >$"), nil)
  local result, err, commit = stage("CUT 1.=1")
  assert(result, err)
  eq(commit, nil)
  eq(stage("PUT >$"), nil)
end
T["registers preserve exact text and support upstream names"] = function()
  lines = { "\tindented", "", "+literal", "-literal" }
  capture("CUT 1.=4 @helper-1_name")
  eq(stage("PUT 1.=1 @helper-1_name", nil, { "target" }), lines)
end
T["cleanup removes conversation registers"] = function()
  capture()
  hashline.clear_clipboard(conversation.id)
  eq(stage("PUT >$ @part"), nil)
end
T["staged commits only update registers they captured"] = function()
  local _, _, first = stage("CUT 1.=1 @first")
  local _, _, second = stage("CUT 2.=2 @second")
  first()
  second()
  eq(stage("PUT 1.=4 @first"), { "one" })
  eq(stage("PUT 1.=4 @second"), { "two" })
end
T["numeric conversation ids remain distinct from string ids"] = function()
  local numeric = { id = 987654321 }
  local result, err, commit = stage("CUT 1.=1 @part", numeric)
  assert(result, err)
  commit()
  eq(stage("PUT 1.=4 @part", { id = numeric.id }), { "one" })
  eq(stage("PUT >$ @part", { id = tostring(numeric.id) }), nil)
  hashline.clear_clipboard(numeric.id)
end
T["conversation destruction releases its named registers"] = function()
  local owner = require("sia.conversation").new({ temporary = true })
  local result, err, commit = stage("CUT 1.=1 @part", owner)
  assert(result, err)
  commit()
  owner:destroy()
  eq(stage("PUT >$ @part", { id = owner.id }), nil)
end
return T
