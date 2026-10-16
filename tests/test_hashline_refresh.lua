local hashline = require("sia.hashline")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()
local function file_lines(count)
  local lines = {}
  for i = 1, count do
    lines[i] = "line " .. i
  end
  return lines
end
local function tag(output)
  return output[1]:match("#(%x+)%]")
end
T["refresh returns fresh tagged context usable without another view"] = function()
  local conversation, before = {}, file_lines(200)
  local old_tag = tag(hashline.view(conversation, "/test", before, 1, 200))
  local after = vim.deepcopy(before)
  after[100] = "changed"
  local output = hashline.refresh(conversation, "/test", before, after)
  eq(output[2], "…")
  eq(output[3], "97:line 97")
  eq(output[6], "100:changed")
  eq(output[#output], "…")
  local result, err =
    hashline.apply(conversation, "/test", after, tag(output), "PUT 100.=100:\n+again")
  assert(result, err)
  eq(result[100], "again")
  eq(hashline.apply(conversation, "/test", after, old_tag, "CUT 100.=100"), nil)
  eq(hashline.apply(conversation, "/test", after, tag(output), "CUT 104.=104"), nil)
end
T["insertion context has new line numbers"] = function()
  local conversation = {}
  local after = { "one", "inserted", "another", "two", "three" }
  local output =
    hashline.refresh(conversation, "/test", { "one", "two", "three" }, after)
  eq(output[5], "4:two")
  local result =
    hashline.apply(conversation, "/test", after, tag(output), "PUT 4.=4:\n+changed")
  eq(result, { "one", "inserted", "another", "changed", "three" })
end
T["deletions return surviving context at both file boundaries"] = function()
  local conversation, before = {}, file_lines(20)
  for index, after in ipairs({
    vim.list_slice(before, 1, 16),
    vim.list_slice(before, 5, 20),
    { "" },
  }) do
    local output = hashline.refresh(conversation, "/test", before, after)
    eq(type(tag(output)), "string")
    local edits = index == 2 and "PUT <1:\n+tail" or "PUT >$:\n+tail"
    local result, err = hashline.apply(conversation, "/test", after, tag(output), edits)
    assert(result, err)
    eq(result[index == 2 and 1 or #result], "tail")
  end
end
T["separate changed regions share a header and omit intermediate lines"] = function()
  local conversation, before = {}, file_lines(200)
  local after = vim.deepcopy(before)
  after[20], after[180] = "first change", "second change"
  local output = hashline.refresh(conversation, "/test", before, after)
  local text = table.concat(output, "\n")
  eq(text:find("20:first change", 1, true) ~= nil, true)
  eq(text:find("180:second change", 1, true) ~= nil, true)
  eq(text:find("100:line 100", 1, true), nil)
  eq(hashline.apply(conversation, "/test", after, tag(output), "CUT 100.=100"), nil)
end
T["large edits have a bounded preview and omitted lines remain unseen"] = function()
  local conversation, before = {}, file_lines(200)
  local after = {}
  for i = 1, 200 do
    after[i] = "new " .. i
  end
  local output = hashline.refresh(conversation, "/test", before, after)
  eq(#output, 42)
  eq(output[41], "40:new 40")
  eq(output[42], "…")
  eq(hashline.apply(conversation, "/test", after, tag(output), "CUT 41.=41"), nil)
end
T["truncated preview rows cannot be used as edit anchors"] = function()
  local conversation = {}
  local after = { "first", string.rep("x", 2500), "last" }
  local output =
    hashline.refresh(conversation, "/test", { "first", "old", "last" }, after)
  eq(output[3]:find("[TRUNCATED]", 1, true) ~= nil, true)
  eq(hashline.apply(conversation, "/test", after, tag(output), "PUT >2:\n+unsafe"), nil)
end
T["preview bytes stay bounded for many long changed lines"] = function()
  local conversation, after = {}, {}
  for i = 1, 100 do
    after[i] = string.rep("x", 1500) .. i
  end
  local output = hashline.refresh(conversation, "/test", { "old" }, after)
  eq(#table.concat(output, "\n") < 8100, true)
  eq(output[#output], "…")
end
return T
