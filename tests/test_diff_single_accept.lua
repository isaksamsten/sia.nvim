local diff = require("sia.diff")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local any = MiniTest.expect.no_equality

T["sia.diff.single_accept"] = MiniTest.new_set()

T["sia.diff.single_accept"]["get_hunk_at_line"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  
  -- Set up buffer with some content
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "line 1",
    "line 2 modified",
    "line 3",
    "new line 4",
    "line 5"
  })
  
  -- Set up diff state with original content
  local original_content = {
    "line 1",
    "line 2 original", 
    "line 3",
    "line 5"
  }
  
  diff.highlight_diff_changes(buf, original_content)
  
  -- Test finding hunk at modified line
  local hunk_info = diff.get_hunk_at_line(buf, 2)
  eq(true, hunk_info ~= nil)
  eq("change", hunk_info.hunk.type)
  
  -- Test finding hunk at added line
  local hunk_info2 = diff.get_hunk_at_line(buf, 4)
  eq(true, hunk_info2 ~= nil)
  eq("add", hunk_info2.hunk.type)
  
  -- Test line without hunk
  local hunk_info3 = diff.get_hunk_at_line(buf, 1)
  eq(true, hunk_info3 == nil)
  
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.diff.single_accept"]["accept_single_hunk"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  
  -- Set up buffer with some content
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "line 1",
    "line 2 modified",
    "line 3 modified",
    "line 4"
  })
  
  -- Set up diff state with original content
  local original_content = {
    "line 1",
    "line 2 original", 
    "line 3 original",
    "line 4"
  }
  
  diff.highlight_diff_changes(buf, original_content)
  
  local initial_count = diff.get_hunk_count(buf)
  eq(true, initial_count > 0)
  
  -- Accept the first hunk
  local success = diff.accept_single_hunk(buf, 1)
  eq(true, success)
  
  -- Check that we have fewer hunks now
  local remaining_count = diff.get_hunk_count(buf)
  eq(initial_count - 1, remaining_count)
  
  vim.api.nvim_buf_delete(buf, { force = true })
end

return T