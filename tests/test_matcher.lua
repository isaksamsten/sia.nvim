local matcher = require("sia.matcher")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["sia.matcher"] = MiniTest.new_set()

T["sia.matcher"]["exact inline match"] = function()
  local match = matcher.find_best_match("isak", { "hello world isak" })

  eq(false, match.fuzzy)
  eq(false, match.strip_line_number)
  eq(1, #match.matches)
  eq(13, match.matches[1].col_span[1])
  eq(16, match.matches[1].col_span[2])
  eq(1, match.matches[1].span[1])
  eq(1, match.matches[1].span[2])
  eq(1.0, match.matches[1].score)
end

T["sia.matcher"]["exact multiline match"] = function()
  local text = "function hello()\n  print('world')\nend"
  local haystack = { "function hello()", "  print('world')", "end", "other code" }
  local match = matcher.find_best_match(text, haystack)

  eq(false, match.fuzzy)
  eq(false, match.strip_line_number)
  eq(1, #match.matches)
  eq(1, match.matches[1].span[1])
  eq(3, match.matches[1].span[2])
  eq(1.0, match.matches[1].score)
end

T["sia.matcher"]["exact empty string match"] = function()
  local match = matcher.find_best_match("", { "" })

  eq(false, match.fuzzy)
  eq(false, match.strip_line_number)
  eq(1, #match.matches)
  eq(1, match.matches[1].span[1])
  eq(-1, match.matches[1].span[2])
  eq(1.0, match.matches[1].score)
end

T["sia.matcher"]["multiple exact inline matches"] = function()
  local match = matcher.find_best_match("test", { "test this test", "another line" })

  eq(false, match.fuzzy)
  eq(false, match.strip_line_number)
  eq(2, #match.matches)
  eq(1, match.matches[1].col_span[1])
  eq(4, match.matches[1].col_span[2])
  eq(11, match.matches[2].col_span[1])
  eq(14, match.matches[2].col_span[2])
end

T["sia.matcher"]["case insensitive fuzzy match"] = function()
  local match = matcher.find_best_match("ISAK", { "hello isak world" })

  eq(true, match.fuzzy)
  eq(false, match.strip_line_number)
  eq(1, #match.matches)
  eq(7, match.matches[1].col_span[1])
  eq(10, match.matches[1].col_span[2])
  eq(1, match.matches[1].span[1])
  eq(1, match.matches[1].span[2])
end

T["sia.matcher"]["indentation ignored fuzzy match"] = function()
  local text = "function test()\n    return true\nend"
  local haystack = { "  function test()", "return true", "  end" }
  local match = matcher.find_best_match(text, haystack)

  eq(true, match.fuzzy)
  eq(false, match.strip_line_number)
  eq(1, #match.matches)
  eq(1, match.matches[1].span[1])
  eq(3, match.matches[1].span[2])
end

T["sia.matcher"]["similarity threshold fuzzy match"] = function()
  local text = "function hello_world()\n  print('test')\nend"
  local haystack = { "function hello_worlds()", "  print('tests')", "end" }
  local match = matcher.find_best_match(text, haystack)

  eq(true, match.fuzzy)
  eq(false, match.strip_line_number)
  eq(1, #match.matches)
  eq(1, match.matches[1].span[1])
  eq(3, match.matches[1].span[2])
  local score = match.matches[1].score
  eq(true, score < 0.98 and score > 0.97)
end

T["sia.matcher"]["tab format line numbers"] = function()
  local match = matcher.find_best_match("    8\thello", { "hello world" })

  eq(true, match.fuzzy)
  eq(true, match.strip_line_number)
  eq(1, #match.matches)
  eq(1, match.matches[1].col_span[1])
  eq(5, match.matches[1].col_span[2])
  eq(1, match.matches[1].span[1])
  eq(1, match.matches[1].span[2])
end

T["sia.matcher"]["pipe format line numbers"] = function()
  local match = matcher.find_best_match("  42 | hello", { "hello world" })

  eq(true, match.fuzzy)
  eq(true, match.strip_line_number)
  eq(1, #match.matches)
  eq(1, match.matches[1].col_span[1])
  eq(5, match.matches[1].col_span[2])
end

T["sia.matcher"]["space format line numbers"] = function()
  local match = matcher.find_best_match("  123  hello", { "hello world" })

  eq(true, match.fuzzy) -- line number stripping always makes it fuzzy
  eq(true, match.strip_line_number)
  eq(1, #match.matches)
  eq(1, match.matches[1].col_span[1])
  eq(5, match.matches[1].col_span[2])
end

T["sia.matcher"]["multiline with line numbers"] = function()
  local text = "    1\tfunction test()\n    2\t  return true\n    3\tend"
  local haystack = { "function test()", "  return true", "end" }
  local match = matcher.find_best_match(text, haystack)

  eq(true, match.fuzzy)
  eq(true, match.strip_line_number)
  eq(1, #match.matches)
  eq(1, match.matches[1].span[1])
  eq(3, match.matches[1].span[2])
end

T["sia.matcher"]["mixed line number formats"] = function()
  local text = "    1\tfunction test()\n  2 |   return true\n  3  end"
  local haystack = { "function test()", "  return true", "end" }
  local match = matcher.find_best_match(text, haystack)

  eq(true, match.fuzzy)
  eq(true, match.strip_line_number)
  eq(1, #match.matches)
  eq(1, match.matches[1].span[1])
  eq(3, match.matches[1].span[2])
end

T["sia.matcher"]["no matches found"] = function()
  local match = matcher.find_best_match("nonexistent", { "hello", "world" })

  eq(true, match.fuzzy) -- No match case sets fuzzy=true
  eq(false, match.strip_line_number)
  eq(0, #match.matches)
end

T["sia.matcher"]["empty haystack"] = function()
  local match = matcher.find_best_match("test", {})

  eq(true, match.fuzzy)
  eq(false, match.strip_line_number)
  eq(0, #match.matches)
end

T["sia.matcher"]["empty string in empty haystack"] = function()
  local match = matcher.find_best_match("", {})

  eq(false, match.fuzzy)
  eq(false, match.strip_line_number)
  eq(1, #match.matches)
end

T["sia.matcher"]["line numbers but no match after stripping"] = function()
  local match = matcher.find_best_match("    1\tnonexistent", { "hello", "world" })

  eq(true, match.fuzzy)
  eq(true, match.strip_line_number)
  eq(0, #match.matches)
end

T["sia.matcher"]["whitespace only lines"] = function()
  local text = "test\n\n  \nend"
  local haystack = { "test", "", "   ", "end" }
  local match = matcher.find_best_match(text, haystack)

  eq(true, match.fuzzy)
  eq(false, match.strip_line_number)
  eq(1, #match.matches)
  eq(1, match.matches[1].span[1])
  eq(4, match.matches[1].span[2])
end

T["sia.matcher"]["very long line"] = function()
  local long_line = string.rep("x", 1000) .. "target" .. string.rep("y", 1000)
  local match = matcher.find_best_match("target", { long_line })

  eq(false, match.fuzzy)
  eq(false, match.strip_line_number)
  eq(1, #match.matches)
  eq(1001, match.matches[1].col_span[1])
  eq(1006, match.matches[1].col_span[2])
end

T["sia.matcher"]["special regex characters"] = function()
  local match = matcher.find_best_match("test.*[abc]+", { "test.*[abc]+ pattern" })

  eq(false, match.fuzzy)
  eq(false, match.strip_line_number)
  eq(1, #match.matches)
  eq(1, match.matches[1].col_span[1])
  eq(12, match.matches[1].col_span[2])
end

T["sia.matcher"]["unicode characters"] = function()
  local match = matcher.find_best_match("héllo", { "héllo world 🌍" })

  eq(false, match.fuzzy)
  eq(false, match.strip_line_number)
  eq(1, #match.matches)
  eq(1, match.matches[1].col_span[1])
  eq(6, match.matches[1].col_span[2])
end

T["sia.matcher"]["strip_line_numbers tab format"] = function()
  local stripped, had_numbers = matcher.strip_line_numbers("  42\thello world")
  eq(true, had_numbers)
  eq("hello world", stripped[1])
end

T["sia.matcher"]["strip_line_numbers pipe format"] = function()
  local stripped, had_numbers = matcher.strip_line_numbers("  42 | hello world")
  eq(true, had_numbers)
  eq("hello world", stripped[1])
end

T["sia.matcher"]["strip_line_numbers space format"] = function()
  local stripped, had_numbers = matcher.strip_line_numbers("  42  hello world")
  eq(true, had_numbers)
  eq("hello world", stripped[1])
end

T["sia.matcher"]["strip_line_numbers no line numbers"] = function()
  local stripped, had_numbers = matcher.strip_line_numbers("hello world")
  eq(false, had_numbers)
  eq("hello world", stripped[1])
end

T["sia.matcher"]["strip_line_numbers multiline"] = function()
  local text = "  1\tline one\n  2 | line two\n  3  line three\nno numbers here"
  local stripped, had_numbers = matcher.strip_line_numbers(text)
  eq(true, had_numbers)
  eq("line one", stripped[1])
  eq("line two", stripped[2])
  eq("line three", stripped[3])
  eq("no numbers here", stripped[4])
end

T["sia.matcher"]["strip_line_numbers edge cases"] = function()
  local stripped, had_numbers = matcher.strip_line_numbers("  007\thello")
  eq(true, had_numbers)
  eq("hello", stripped[1])

  stripped, had_numbers = matcher.strip_line_numbers("  12345678\thello")
  eq(true, had_numbers)
  eq("hello", stripped[1])

  stripped, had_numbers = matcher.strip_line_numbers("  42\t")
  eq(true, had_numbers)
  eq("", stripped[1])
end

T["sia.matcher"]["multiple matches across different lines"] = function()
  local match = matcher.find_best_match("hello", { "hello world", "goodbye", "hello again" })

  eq(false, match.fuzzy)
  eq(false, match.strip_line_number)
  eq(2, #match.matches)
  eq(1, match.matches[1].span[1])
  eq(1, match.matches[1].span[2])
  eq(1, match.matches[1].col_span[1])
  eq(5, match.matches[1].col_span[2])
  eq(3, match.matches[2].span[1])
  eq(3, match.matches[2].span[2])
  eq(1, match.matches[2].col_span[1])
  eq(5, match.matches[2].col_span[2])
end

T["sia.matcher"]["multiple matches same line overlapping"] = function()
  local match = matcher.find_best_match("aa", { "aaa bbb", "other line" })

  eq(false, match.fuzzy)
  eq(false, match.strip_line_number)
  eq(2, #match.matches)
  eq(1, match.matches[1].col_span[1])
  eq(2, match.matches[1].col_span[2])
  eq(2, match.matches[2].col_span[1])
  eq(3, match.matches[2].col_span[2])
end

T["sia.matcher"]["multiple matches with case variations"] = function()
  local match = matcher.find_best_match("Test", { "Test this TEST", "another line" })

  eq(false, match.fuzzy)
  eq(false, match.strip_line_number)
  eq(1, #match.matches) -- Only exact case match should be found in non-fuzzy mode
  eq(1, match.matches[1].col_span[1])
  eq(4, match.matches[1].col_span[2])
end

T["sia.matcher"]["multiple matches fuzzy case insensitive"] = function()
  local match = matcher.find_best_match("TEST", { "Test this test", "another line" })

  eq(true, match.fuzzy)
  eq(false, match.strip_line_number)
  eq(2, #match.matches)
  eq(1, match.matches[1].col_span[1])
  eq(4, match.matches[1].col_span[2])
  eq(11, match.matches[2].col_span[1])
  eq(14, match.matches[2].col_span[2])
end

T["sia.matcher"]["multiple matches with whitespace"] = function()
  local match = matcher.find_best_match("  test  ", { "  test  and   test  ", "other" })

  eq(false, match.fuzzy)
  eq(false, match.strip_line_number)
  eq(2, #match.matches)
  eq(1, match.matches[1].col_span[1])
  eq(8, match.matches[1].col_span[2])
  eq(13, match.matches[2].col_span[1])
  eq(20, match.matches[2].col_span[2])
end

T["sia.matcher"]["multiple matches empty needle"] = function()
  local match = matcher.find_best_match("", { "", "not empty", "" })

  eq(false, match.fuzzy)
  eq(false, match.strip_line_number)
  eq(0, #match.matches)
end

T["sia.matcher"]["multiple matches single character"] = function()
  local match = matcher.find_best_match("a", { "banana", "apple", "xyz" })

  eq(false, match.fuzzy)
  eq(false, match.strip_line_number)
  eq(true, #match.matches >= 2)
end

T["sia.matcher"]["multiple matches at line boundaries"] = function()
  local match = matcher.find_best_match("end", { "at the end", "end of start", "middle", "end" })

  eq(false, match.fuzzy)
  eq(false, match.strip_line_number)
  eq(1, #match.matches) -- Only finds the exact line match, not inline matches
  eq(4, match.matches[1].span[1]) -- Line 4: "end"
  eq(4, match.matches[1].span[2])
  eq(nil, match.matches[1].col_span) -- Line matches don't have col_span
  eq(1.0, match.matches[1].score)
end

T["sia.matcher"]["multiple inline matches only"] = function()
  local match = matcher.find_best_match("cat", { "catch the cat", "concatenate", "dog" })

  eq(false, match.fuzzy)
  eq(false, match.strip_line_number)
  eq(2, #match.matches) -- Limited to 2 matches now
  eq(1, match.matches[1].span[1])
  eq(1, match.matches[1].span[2])
  eq(1, match.matches[1].col_span[1])
  eq(3, match.matches[1].col_span[2])
  eq(1, match.matches[2].span[1])
  eq(1, match.matches[2].span[2])
  eq(11, match.matches[2].col_span[1])
  eq(13, match.matches[2].col_span[2])
end

T["sia.matcher"]["inline matches with limit parameter"] = function()
  local haystack = { "test this test that test" }

  -- No limit - should find all 3 matches
  local matches_no_limit = matcher.find_inline_matches("test", haystack)
  eq(3, #matches_no_limit)

  -- Limit to 2 - should find only 2 matches
  local matches_limited = matcher.find_inline_matches("test", haystack, { limit = 2 })
  eq(2, #matches_limited)

  -- Limit to 1 - should find only 1 match
  local matches_one = matcher.find_inline_matches("test", haystack, { limit = 1 })
  eq(1, #matches_one)

  -- Limit larger than matches available - should find all available
  local matches_large_limit = matcher.find_inline_matches("test", haystack, { limit = 10 })
  eq(3, #matches_large_limit)
end

T["sia.matcher"]["multiple matches with special characters"] = function()
  local match = matcher.find_best_match("()", { "function() and ()", "() at start", "no match" })

  eq(false, match.fuzzy)
  eq(false, match.strip_line_number)
  eq(2, #match.matches) -- Maximum of 2 matches returned
  eq(1, match.matches[1].span[1])
  eq(9, match.matches[1].col_span[1])
  eq(10, match.matches[1].col_span[2])
  eq(1, match.matches[2].span[1])
  eq(16, match.matches[2].col_span[1])
  eq(17, match.matches[2].col_span[2])
end

return T
