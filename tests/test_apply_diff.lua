local child = MiniTest.new_child_neovim()
local expect, eq = MiniTest.expect, MiniTest.expect.equality
local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      child.restart({ "-u", "assets/minimal.lua" })
      child.lua([[patch = require("sia.patch")]])
    end,
    post_once = function()
      child.stop()
    end,
  },
})

T["identify_files_needed"] = MiniTest.new_set()

T["identify_files_needed"]["finds update and delete files"] = function()
  local result = child.lua_get([[
    patch.identify_files_needed(table.concat({
      "*** Begin Patch",
      "*** Update File: src/main.lua",
      "@@",
      " hello",
      "*** Delete File: old.lua",
      "*** Add File: new.lua",
      "+content",
      "*** End Patch",
    }, "\n"))
  ]])
  eq(result, { "src/main.lua", "old.lua" })
end

T["identify_files_needed"]["returns empty for add-only patches"] = function()
  local result = child.lua_get([[
    patch.identify_files_needed(table.concat({
      "*** Begin Patch",
      "*** Add File: new.lua",
      "+hello",
      "*** End Patch",
    }, "\n"))
  ]])
  eq(result, {})
end

T["identify_files_needed"]["deduplicates paths"] = function()
  local result = child.lua_get([[
    patch.identify_files_needed(table.concat({
      "*** Begin Patch",
      "*** Update File: a.lua",
      "*** Update File: a.lua",
      "*** End Patch",
    }, "\n"))
  ]])
  eq(result, { "a.lua" })
end

T["add file"] = MiniTest.new_set()

T["add file"]["creates new file"] = function()
  local result = child.lua_get([[(function()
    local text = table.concat({
      "*** Begin Patch",
      "*** Add File: new.lua",
      "+local M = {}",
      "+return M",
      "*** End Patch",
    }, "\n")
    local p, fuzz = patch.text_to_patch(text, {})
    local commit = patch.patch_to_commit(p, {})
    return { commit = commit, fuzz = fuzz }
  end)()]])
  eq(result.fuzz, 0)
  eq(result.commit["new.lua"].type, "add")
  eq(result.commit["new.lua"].new_content, "local M = {}\nreturn M")
end

T["add file"]["creates file with empty lines"] = function()
  local result = child.lua_get([[(function()
    local text = table.concat({
      "*** Begin Patch",
      "*** Add File: new.lua",
      "+line1",
      "+",
      "+line3",
      "*** End Patch",
    }, "\n")
    local p, fuzz = patch.text_to_patch(text, {})
    local commit = patch.patch_to_commit(p, {})
    return commit["new.lua"].new_content
  end)()]])
  eq(result, "line1\n\nline3")
end

T["delete file"] = MiniTest.new_set()

T["delete file"]["marks file for deletion"] = function()
  local result = child.lua_get([[(function()
    local text = table.concat({
      "*** Begin Patch",
      "*** Delete File: old.lua",
      "*** End Patch",
    }, "\n")
    local orig = { ["old.lua"] = "content" }
    local p, fuzz = patch.text_to_patch(text, orig)
    local commit = patch.patch_to_commit(p, orig)
    return commit["old.lua"]
  end)()]])
  eq(result.type, "delete")
  eq(result.old_content, "content")
end

T["delete file"]["errors on missing file"] = function()
  expect.error(function()
    child.lua([[(function()
      local text = table.concat({
        "*** Begin Patch",
        "*** Delete File: missing.lua",
        "*** End Patch",
      }, "\n")
      patch.text_to_patch(text, {})
    end)()]])
  end)
end

T["update file"] = MiniTest.new_set()

T["update file"]["simple single-line replacement"] = function()
  local result = child.lua_get([[(function()
    local orig = { ["a.lua"] = "line1\nline2\nline3" }
    local text = table.concat({
      "*** Begin Patch",
      "*** Update File: a.lua",
      "@@",
      " line1",
      "-line2",
      "+line2_new",
      " line3",
      "*** End Patch",
    }, "\n")
    local p, fuzz = patch.text_to_patch(text, orig)
    local commit = patch.patch_to_commit(p, orig)
    return { content = commit["a.lua"].new_content, fuzz = fuzz }
  end)()]])
  eq(result.content, "line1\nline2_new\nline3")
  eq(result.fuzz, 0)
end

T["update file"]["insert lines"] = function()
  local result = child.lua_get([[(function()
    local orig = { ["a.lua"] = "line1\nline3" }
    local text = table.concat({
      "*** Begin Patch",
      "*** Update File: a.lua",
      "@@",
      " line1",
      "+line2",
      " line3",
      "*** End Patch",
    }, "\n")
    local p = patch.text_to_patch(text, orig)
    local commit = patch.patch_to_commit(p, orig)
    return commit["a.lua"].new_content
  end)()]])
  eq(result, "line1\nline2\nline3")
end

T["update file"]["delete lines"] = function()
  local result = child.lua_get([[(function()
    local orig = { ["a.lua"] = "line1\nline2\nline3" }
    local text = table.concat({
      "*** Begin Patch",
      "*** Update File: a.lua",
      "@@",
      " line1",
      "-line2",
      " line3",
      "*** End Patch",
    }, "\n")
    local p = patch.text_to_patch(text, orig)
    local commit = patch.patch_to_commit(p, orig)
    return commit["a.lua"].new_content
  end)()]])
  eq(result, "line1\nline3")
end

T["update file"]["multiple hunks in same file"] = function()
  local result = child.lua_get([[(function()
    local orig = { ["a.lua"] = "a\nb\nc\nd\ne\nf" }
    local text = table.concat({
      "*** Begin Patch",
      "*** Update File: a.lua",
      "@@",
      " a",
      "-b",
      "+B",
      " c",
      "@@",
      " e",
      "-f",
      "+F",
      "*** End Patch",
    }, "\n")
    local p = patch.text_to_patch(text, orig)
    local commit = patch.patch_to_commit(p, orig)
    return commit["a.lua"].new_content
  end)()]])
  eq(result, "a\nB\nc\nd\ne\nF")
end

T["update file"]["@@ skip-ahead to context line"] = function()
  local result = child.lua_get([[(function()
    local orig = { ["a.lua"] = "header\na\nb\nc\nfooter" }
    local text = table.concat({
      "*** Begin Patch",
      "*** Update File: a.lua",
      "@@ c",
      "-footer",
      "+new_footer",
      "*** End Patch",
    }, "\n")
    local p = patch.text_to_patch(text, orig)
    local commit = patch.patch_to_commit(p, orig)
    return commit["a.lua"].new_content
  end)()]])
  eq(result, "header\na\nb\nc\nnew_footer")
end

T["update file"]["move file"] = function()
  local result = child.lua_get([[(function()
    local orig = { ["old.lua"] = "content" }
    local text = table.concat({
      "*** Begin Patch",
      "*** Update File: old.lua",
      "*** Move to: new.lua",
      "@@",
      "-content",
      "+new_content",
      "*** End Patch",
    }, "\n")
    local p = patch.text_to_patch(text, orig)
    local commit = patch.patch_to_commit(p, orig)
    return {
      type = commit["old.lua"].type,
      move_path = commit["old.lua"].move_path,
      new_content = commit["old.lua"].new_content,
    }
  end)()]])
  eq(result.type, "update")
  eq(result.move_path, "new.lua")
  eq(result.new_content, "new_content")
end

T["update file"]["fuzzy rstrip matching"] = function()
  local result = child.lua_get([[(function()
    local orig = { ["a.lua"] = "line1  \nline2\nline3" }
    local text = table.concat({
      "*** Begin Patch",
      "*** Update File: a.lua",
      "@@",
      " line1",
      "-line2",
      "+line2_new",
      " line3",
      "*** End Patch",
    }, "\n")
    local p, fuzz = patch.text_to_patch(text, orig)
    local commit = patch.patch_to_commit(p, orig)
    return { content = commit["a.lua"].new_content, fuzz = fuzz }
  end)()]])
  eq(result.content, "line1  \nline2_new\nline3")
  -- fuzz > 0 indicates non-exact match
  expect.no_equality(result.fuzz, 0)
end

T["update file"]["End of File marker"] = function()
  local result = child.lua_get([[(function()
    local orig = { ["a.lua"] = "first\nsecond\nlast" }
    local text = table.concat({
      "*** Begin Patch",
      "*** Update File: a.lua",
      " second",
      "-last",
      "+new_last",
      "*** End of File",
      "*** End Patch",
    }, "\n")
    local p = patch.text_to_patch(text, orig)
    local commit = patch.patch_to_commit(p, orig)
    return commit["a.lua"].new_content
  end)()]])
  eq(result, "first\nsecond\nnew_last")
end

T["multiple files"] = MiniTest.new_set()

T["multiple files"]["update + add + delete"] = function()
  local result = child.lua_get([[(function()
    local orig = {
      ["keep.lua"] = "old_line",
      ["remove.lua"] = "bye",
    }
    local text = table.concat({
      "*** Begin Patch",
      "*** Update File: keep.lua",
      "@@",
      "-old_line",
      "+new_line",
      "*** Delete File: remove.lua",
      "*** Add File: brand_new.lua",
      "+hello world",
      "*** End Patch",
    }, "\n")
    local p = patch.text_to_patch(text, orig)
    local commit = patch.patch_to_commit(p, orig)
    return {
      keep = commit["keep.lua"],
      remove = commit["remove.lua"],
      brand_new = commit["brand_new.lua"],
    }
  end)()]])
  eq(result.keep.type, "update")
  eq(result.keep.new_content, "new_line")
  eq(result.remove.type, "delete")
  eq(result.brand_new.type, "add")
  eq(result.brand_new.new_content, "hello world")
end

T["errors"] = MiniTest.new_set()

T["errors"]["invalid patch text - missing markers"] = function()
  expect.error(function()
    child.lua([[
      patch.text_to_patch("not a patch", {})
    ]])
  end)
end

T["errors"]["duplicate path"] = function()
  expect.error(function()
    child.lua([[(function()
      local orig = { ["a.lua"] = "content" }
      local text = table.concat({
        "*** Begin Patch",
        "*** Update File: a.lua",
        "@@",
        "-content",
        "+new",
        "*** Update File: a.lua",
        "@@",
        "-new",
        "+newer",
        "*** End Patch",
      }, "\n")
      patch.text_to_patch(text, orig)
    end)()]])
  end)
end

T["errors"]["update missing file"] = function()
  expect.error(function()
    child.lua([[(function()
      local text = table.concat({
        "*** Begin Patch",
        "*** Update File: nonexistent.lua",
        "@@",
        "-old",
        "+new",
        "*** End Patch",
      }, "\n")
      patch.text_to_patch(text, {})
    end)()]])
  end)
end

T["errors"]["invalid add file line"] = function()
  expect.error(function()
    child.lua([[(function()
      local text = table.concat({
        "*** Begin Patch",
        "*** Add File: new.lua",
        "not starting with plus",
        "*** End Patch",
      }, "\n")
      patch.text_to_patch(text, {})
    end)()]])
  end)
end

T["get_updated_file"] = MiniTest.new_set()

T["get_updated_file"]["applies chunks correctly"] = function()
  local result = child.lua_get([[(function()
    local action = {
      type = "update",
      chunks = {
        {
          orig_index = 1,
          del_lines = { "old" },
          ins_lines = { "new1", "new2" },
        },
      },
    }
    return patch.get_updated_file("first\nold\nlast", action, "test")
  end)()]])
  eq(result, "first\nnew1\nnew2\nlast")
end

T["get_updated_file"]["handles empty chunks"] = function()
  local result = child.lua_get([[(function()
    local action = { type = "update", chunks = {} }
    return patch.get_updated_file("unchanged", action, "test")
  end)()]])
  eq(result, "unchanged")
end

T["get_updated_file"]["insert at beginning"] = function()
  local result = child.lua_get([[(function()
    local action = {
      type = "update",
      chunks = {
        {
          orig_index = 0,
          del_lines = {},
          ins_lines = { "header" },
        },
      },
    }
    return patch.get_updated_file("first\nsecond", action, "test")
  end)()]])
  eq(result, "header\nfirst\nsecond")
end

T["get_updated_file"]["delete at end"] = function()
  local result = child.lua_get([[(function()
    local action = {
      type = "update",
      chunks = {
        {
          orig_index = 2,
          del_lines = { "last" },
          ins_lines = {},
        },
      },
    }
    return patch.get_updated_file("first\nsecond\nlast", action, "test")
  end)()]])
  eq(result, "first\nsecond")
end

return T
