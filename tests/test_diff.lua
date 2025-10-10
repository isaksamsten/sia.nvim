local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local diff = require("sia.diff")

T["sia.diff"] = MiniTest.new_set()

local function create_test_buffer()
  return vim.api.nvim_create_buf(false, true)
end

local function setup_diff_state(buf, original_lines, current_lines)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, original_lines)
  diff.update_baseline_content(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, current_lines)
  diff.update_reference_content(buf)
  diff.update_diff(buf)
end

T["sia.diff"]["accept_single_hunk"] = MiniTest.new_set()

T["sia.diff"]["accept_single_hunk"]["accepts added lines"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "line 2", "line 3" }
  local current = { "line 1", "new line", "line 2", "line 3" }

  setup_diff_state(buf, original, current)

  local hunks = diff.get_hunks(buf)
  eq(#hunks, 1)
  eq(hunks and hunks[1].type, "add")

  local success = diff.accept_single_hunk(buf, 1)
  eq(success, true)

  hunks = diff.get_hunks(buf)
  eq(hunks, nil)
end

T["sia.diff"]["accept_single_hunk"]["accepts deleted lines"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "to delete", "line 2", "line 3" }
  local current = { "line 1", "line 2", "line 3" }

  setup_diff_state(buf, original, current)

  local hunks = diff.get_hunks(buf)
  eq(#hunks, 1)
  eq(hunks and hunks[1].type, "delete")

  local success = diff.accept_single_hunk(buf, 1)
  eq(success, true)

  hunks = diff.get_hunks(buf)
  eq(hunks, nil)
end

T["sia.diff"]["accept_single_hunk"]["accepts modified lines"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "old content", "line 3" }
  local current = { "line 1", "new content", "line 3" }

  setup_diff_state(buf, original, current)

  local hunks = diff.get_hunks(buf)
  eq(#hunks, 1)
  eq(hunks and hunks[1].type, "change")

  local success = diff.accept_single_hunk(buf, 1)
  eq(success, true)

  hunks = diff.get_hunks(buf)
  eq(hunks, nil)
end

T["sia.diff"]["accept_single_hunk"]["accepts specific hunk from multiple"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "line 2", "line 3", "line 4" }
  local current = { "line 1", "modified 2", "line 3", "modified 4" }

  setup_diff_state(buf, original, current)

  local hunks = diff.get_hunks(buf)
  eq(#hunks, 2)

  local success = diff.accept_single_hunk(buf, 1)
  eq(success, true)

  hunks = diff.get_hunks(buf)
  eq(#hunks, 1)

  eq(hunks[1].new_start, 4)
end

T["sia.diff"]["accept_single_hunk"]["handles invalid hunk index"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "line 2" }
  local current = { "line 1", "modified 2" }

  setup_diff_state(buf, original, current)

  local success = diff.accept_single_hunk(buf, 5)
  eq(success, false)

  local hunks = diff.get_hunks(buf)
  eq(#hunks, 1)
end

T["sia.diff"]["reject_single_hunk"] = MiniTest.new_set()

T["sia.diff"]["reject_single_hunk"]["reverts added lines"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "line 2", "line 3" }
  local current = { "line 1", "new line", "line 2", "line 3" }

  setup_diff_state(buf, original, current)

  local hunks = diff.get_hunks(buf)
  eq(#hunks, 1)

  local success = diff.reject_single_hunk(buf, 1)
  eq(success, true)

  local buffer_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(buffer_content, original)

  hunks = diff.get_hunks(buf)
  eq(hunks, nil)
end

T["sia.diff"]["reject_single_hunk"]["reverts deleted lines"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "to restore", "line 2", "line 3" }
  local current = { "line 1", "line 2", "line 3" }

  setup_diff_state(buf, original, current)

  local hunks = diff.get_hunks(buf)
  eq(#hunks, 1)

  local success = diff.reject_single_hunk(buf, 1)
  eq(success, true)

  local buffer_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(buffer_content, original)

  hunks = diff.get_hunks(buf)
  eq(hunks, nil)
end

T["sia.diff"]["reject_single_hunk"]["reverts modified lines"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "original content", "line 3" }
  local current = { "line 1", "modified content", "line 3" }

  setup_diff_state(buf, original, current)

  local hunks = diff.get_hunks(buf)
  eq(#hunks, 1)

  local success = diff.reject_single_hunk(buf, 1)
  eq(success, true)

  local buffer_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(buffer_content, original)

  hunks = diff.get_hunks(buf)
  eq(hunks, nil)
end

T["sia.diff"]["reject_single_hunk"]["rejects specific hunk from multiple"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "line 2", "line 3", "line 4" }
  local current = { "line 1", "modified 2", "line 3", "modified 4" }

  setup_diff_state(buf, original, current)

  local hunks = diff.get_hunks(buf)
  eq(#hunks, 2)

  local success = diff.reject_single_hunk(buf, 1)
  eq(success, true)

  local buffer_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(buffer_content, { "line 1", "line 2", "line 3", "modified 4" })

  hunks = diff.get_hunks(buf)
  eq(#hunks, 1)
end

T["sia.diff"]["reject_single_hunk"]["handles invalid hunk index"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "line 2" }
  local current = { "line 1", "modified 2" }

  setup_diff_state(buf, original, current)

  local success = diff.reject_single_hunk(buf, 5)
  eq(success, false)

  local hunks = diff.get_hunks(buf)
  eq(#hunks, 1)
  local buffer_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(buffer_content, current)
end

T["sia.diff"]["get_hunk_at_line"] = MiniTest.new_set()

T["sia.diff"]["get_hunk_at_line"]["finds hunk for added lines"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "line 2", "line 3" }
  local current = { "line 1", "new line 1", "new line 2", "line 2", "line 3" }

  setup_diff_state(buf, original, current)

  eq(diff.get_hunk_at_line(buf, 2), 1)
  eq(diff.get_hunk_at_line(buf, 3), 1)

  eq(diff.get_hunk_at_line(buf, 1), nil)
  eq(diff.get_hunk_at_line(buf, 4), nil)
  eq(diff.get_hunk_at_line(buf, 5), nil)
end

T["sia.diff"]["get_hunk_at_line"]["finds hunk for deleted lines"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "deleted line", "line 2", "line 3" }
  local current = { "line 1", "line 2", "line 3" }

  setup_diff_state(buf, original, current)

  eq(diff.get_hunk_at_line(buf, 1), 1)
  eq(diff.get_hunk_at_line(buf, 3), nil)
end

T["sia.diff"]["get_hunk_at_line"]["finds correct hunk from multiple"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "line 2", "line 3", "line 4", "line 5" }
  local current = { "line 1", "modified 2", "line 3", "added line", "line 4", "line 5" }

  setup_diff_state(buf, original, current)

  local hunks = diff.get_hunks(buf)
  eq(#hunks, 2)

  eq(diff.get_hunk_at_line(buf, 2), 1)
  eq(diff.get_hunk_at_line(buf, 4), 2)

  eq(diff.get_hunk_at_line(buf, 1), nil)
  eq(diff.get_hunk_at_line(buf, 3), nil)
  eq(diff.get_hunk_at_line(buf, 5), nil)
  eq(diff.get_hunk_at_line(buf, 6), nil)
end

T["sia.diff"]["accept_single_hunk"]["updates baseline correctly"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "line 2", "line 3", "line 4" }
  local current = { "line 1", "modified 2", "line 3", "modified 4" }

  setup_diff_state(buf, original, current)

  local initial_baseline = diff.get_baseline(buf)
  eq(initial_baseline, original)

  local hunks = diff.get_hunks(buf)
  eq(#hunks, 2)

  local success = diff.accept_single_hunk(buf, 1)
  eq(success, true)

  local updated_baseline = diff.get_baseline(buf)
  local expected_baseline = { "line 1", "modified 2", "line 3", "line 4" }
  eq(updated_baseline, expected_baseline)

  local buffer_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(buffer_content, current)

  hunks = diff.get_hunks(buf)
  eq(#hunks, 1)
  eq(hunks[1].new_start, 4)
end

T["sia.diff"]["reject_single_hunk"]["preserves baseline"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "line 2", "line 3", "line 4" }
  local current = { "line 1", "modified 2", "line 3", "modified 4" }

  setup_diff_state(buf, original, current)

  local initial_baseline = diff.get_baseline(buf)

  local hunks = diff.get_hunks(buf)
  eq(#hunks, 2)

  local success = diff.reject_single_hunk(buf, 1)
  eq(success, true)

  local updated_baseline = diff.get_baseline(buf)
  eq(updated_baseline, initial_baseline)

  local buffer_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local expected_buffer = { "line 1", "line 2", "line 3", "modified 4" }
  eq(buffer_content, expected_buffer)

  hunks = diff.get_hunks(buf)
  eq(#hunks, 1)
  eq(hunks[1].new_start, 4)
end

T["sia.diff"]["get_hunk_at_line"]["handles invalid buffer"] = function()
  eq(diff.get_hunk_at_line(999, 1), nil)
end

local BASELINE_JAVA_NO_NL_EOF = {
  "import java.util.Scanner;",
  "",
  "class test {",
  "  public static void main(String[] args) {",
  '    System.out.println("Hello world!");',
  "",
  "    try (var scanner = new Scanner(System.in)) {",
  "      while (scanner.hasNextInt()) {",
  "        System.out.println(scanner.nextInt());",
  "      }",
  "    } catch (Exception e) {",
  "      e.printStackTrace();",
  "    }",
  "    int maxNumber = Integer.MIN_VALUE; // Initialize maxNumber to the smallest integer",
  "    while (scanner.hasNextInt()) {",
  "      int number = scanner.nextInt();",
  "      maxNumber = (int) max(maxNumber, number); // Update maxNumber with the maximum value",
  "    }",
  "    System.out.println(maxNumber);",
  "  }",
  "",
  "  public static double max(int a, int b) {",
  "    return Math.max(a, b); // Use Math.max to return the correct maximum value",
  "  }",
  "}",
}

local MODIFIED_JAVA_NL_EOF = {
  "import java.util.Scanner;",
  "import java.util.List;",
  "import java.util.ArrayList;",
  "",
  "class test {",
  "  public static void main(String[] args) {",
  '    System.out.println("Hello world!");',
  "",
  "    List<Integer> numbers;",
  "    try (var scanner = new Scanner(System.in)) {",
  "      numbers = readNumbers(scanner);",
  "    } catch (Exception e) {",
  "      e.printStackTrace();",
  "      return;",
  "    }",
  "",
  "    for (int n : numbers) {",
  "      System.out.println(n);",
  "    }",
  "",
  "    int maxNumber = Integer.MIN_VALUE;",
  "    for (int number : numbers) {",
  "      maxNumber = (int) max(maxNumber, number);",
  "    }",
  "    System.out.println(maxNumber);",
  "  }",
  "",
  "  public static List<Integer> readNumbers(Scanner scanner) {",
  "    List<Integer> numbers = new ArrayList<>();",
  "    while (scanner.hasNextInt()) {",
  "      numbers.add(scanner.nextInt());",
  "    }",
  "    return numbers;",
  "  }",
  "",
  "  public static double max(int a, int b) {",
  "    return Math.max(a, b);",
  "  }",
  "}",
  "",
}

T["sia.diff"]["reject last hunk eof newline difference"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, BASELINE_JAVA_NO_NL_EOF)
  diff.update_baseline_content(buf)
  diff.update_diff(buf)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, MODIFIED_JAVA_NL_EOF)
  -- This is a reference change
  diff.update_reference_content(buf)

  diff.update_diff(buf)
  local hunk_idx = diff.get_hunk_at_line(buf, 39)
  eq(hunk_idx, 8)
  local hunks = diff.get_hunks(buf)
  local s = diff.reject_single_hunk(buf, 8)
  eq(s, true)
  eq(hunks[hunk_idx], {
    new_count = 1,
    new_start = 39,
    old_count = 1,
    old_start = 25,
    type = "change",
  })

  eq({ "}" }, vim.api.nvim_buf_get_lines(buf, 38, 40, false))
end

T["sia.diff"]["accept last hunk eof newline difference"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, BASELINE_JAVA_NO_NL_EOF)
  diff.update_baseline_content(buf)
  diff.update_diff(buf)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, MODIFIED_JAVA_NL_EOF)
  -- This is a reference change
  diff.update_reference_content(buf)

  diff.update_diff(buf)
  local hunk_idx = diff.get_hunk_at_line(buf, 39)
  eq(hunk_idx, 8)
  local hunks = diff.get_hunks(buf)
  local s = diff.accept_single_hunk(buf, 8)
  eq(s, true)
  eq(hunks[hunk_idx], {
    new_count = 1,
    new_start = 39,
    old_count = 1,
    old_start = 25,
    type = "change",
  })

  eq({ "}", "" }, vim.api.nvim_buf_get_lines(buf, 38, 40, false))
end

T["sia.diff"]["reject_diff"] = MiniTest.new_set()

T["sia.diff"]["reject_diff"]["rejects all hunks with single addition"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "line 2", "line 3" }
  local current = { "line 1", "new line", "line 2", "line 3" }

  setup_diff_state(buf, original, current)

  local hunks = diff.get_hunks(buf)
  eq(#hunks, 1)

  local success = diff.reject_diff(buf)
  eq(success, true)

  local buffer_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(buffer_content, original)

  hunks = diff.get_hunks(buf)
  eq(hunks, nil)
end

T["sia.diff"]["reject_diff"]["rejects all hunks with multiple changes"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "line 2", "line 3", "line 4", "line 5" }
  local current =
    { "line 1", "modified 2", "added line", "line 3", "modified 4", "line 5" }

  setup_diff_state(buf, original, current)

  local hunks = diff.get_hunks(buf)
  eq(#hunks, 2)

  local success = diff.reject_diff(buf)
  eq(success, true)

  local buffer_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(buffer_content, original)

  hunks = diff.get_hunks(buf)
  eq(hunks, nil)
end

T["sia.diff"]["reject_diff"]["rejects all hunks with mixed operations"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "to delete", "line 2", "to modify", "line 3" }
  local current = { "line 1", "line 2", "modified content", "added line", "line 3" }

  setup_diff_state(buf, original, current)

  local hunks = diff.get_hunks(buf)
  eq(#hunks, 2)

  local success = diff.reject_diff(buf)
  eq(success, true)

  local buffer_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(buffer_content, original)

  hunks = diff.get_hunks(buf)
  eq(hunks, nil)
end

T["sia.diff"]["reject_diff"]["handles buffer with no changes"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "line 2", "line 3" }

  setup_diff_state(buf, original, original)

  local hunks = diff.get_hunks(buf)
  eq(hunks, nil)

  local success = diff.reject_diff(buf)
  eq(success, true)

  local buffer_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(buffer_content, original)
end

T["sia.diff"]["reject_diff"]["handles invalid buffer"] = function()
  local success = diff.reject_diff(999)
  eq(success, false)
end

T["sia.diff"]["reject_diff"]["handles buffer without diff state"] = function()
  local buf = create_test_buffer()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line 1", "line 2" })

  local success = diff.reject_diff(buf)
  eq(success, false)
end

T["sia.diff"]["reject_diff"]["with different trailing nl"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, BASELINE_JAVA_NO_NL_EOF)
  diff.update_baseline_content(buf)
  diff.update_diff(buf)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, MODIFIED_JAVA_NL_EOF)
  diff.update_reference_content(buf)
  diff.update_diff(buf)

  local hunks = diff.get_hunks(buf)
  local initial_hunk_count = #hunks

  local success = diff.reject_diff(buf)
  eq(success, true)

  local buffer_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(buffer_content, BASELINE_JAVA_NO_NL_EOF)

  hunks = diff.get_hunks(buf)
  eq(hunks, nil)
end

T["sia.diff"]["accept_diff"] = MiniTest.new_set()

T["sia.diff"]["accept_diff"]["accepts all hunks with single addition"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "line 2", "line 3" }
  local current = { "line 1", "new line", "line 2", "line 3" }

  setup_diff_state(buf, original, current)

  local hunks = diff.get_hunks(buf)
  eq(#hunks, 1)

  local success = diff.accept_diff(buf)
  eq(success, true)

  local buffer_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(buffer_content, current)

  hunks = diff.get_hunks(buf)
  eq(hunks, nil)
end

T["sia.diff"]["accept_diff"]["accepts all hunks with multiple changes"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "line 2", "line 3", "line 4", "line 5" }
  local current =
    { "line 1", "modified 2", "added line", "line 3", "modified 4", "line 5" }

  setup_diff_state(buf, original, current)

  local hunks = diff.get_hunks(buf)
  eq(#hunks, 2)

  local success = diff.accept_diff(buf)
  eq(success, true)

  local buffer_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(buffer_content, current)

  hunks = diff.get_hunks(buf)
  eq(hunks, nil)
end

T["sia.diff"]["accept_diff"]["accepts all hunks with mixed operations"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "to delete", "line 2", "to modify", "line 3" }
  local current = { "line 1", "line 2", "modified content", "added line", "line 3" }

  setup_diff_state(buf, original, current)

  local hunks = diff.get_hunks(buf)
  eq(#hunks, 2)

  local success = diff.accept_diff(buf)
  eq(success, true)

  local buffer_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(buffer_content, current)

  hunks = diff.get_hunks(buf)
  eq(hunks, nil)
end

T["sia.diff"]["accept_diff"]["handles buffer with no changes"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "line 2", "line 3" }

  setup_diff_state(buf, original, original)

  local hunks = diff.get_hunks(buf)
  eq(hunks, nil)

  local success = diff.accept_diff(buf)
  eq(success, true)

  local buffer_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(buffer_content, original)
end

T["sia.diff"]["accept_diff"]["handles invalid buffer"] = function()
  local success = diff.accept_diff(999)
  eq(success, false)
end

T["sia.diff"]["accept_diff"]["handles buffer without diff state"] = function()
  local buf = create_test_buffer()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line 1", "line 2" })

  local success = diff.accept_diff(buf)
  eq(success, false)
end

T["sia.diff"]["accept_diff"]["with different trailing nl"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, BASELINE_JAVA_NO_NL_EOF)
  diff.update_baseline_content(buf)
  diff.update_diff(buf)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, MODIFIED_JAVA_NL_EOF)
  diff.update_reference_content(buf)
  diff.update_diff(buf)

  local hunks = diff.get_hunks(buf)

  local success = diff.accept_diff(buf)
  eq(success, true)

  local buffer_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(buffer_content, MODIFIED_JAVA_NL_EOF)

  hunks = diff.get_hunks(buf)
  eq(hunks, nil)
end

T["sia.diff"]["accept_diff"]["sequential accept and reject operations"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "line 2", "line 3" }
  local modified = { "line 1", "modified line 2", "added line", "line 3" }
  local final_change =
    { "line 1", "modified line 2", "added line", "line 3", "final addition" }

  -- Setup initial diff
  setup_diff_state(buf, original, modified)

  -- Accept all changes
  local success = diff.accept_diff(buf)
  eq(success, true)

  local buffer_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(buffer_content, modified)

  diff.update_baseline_content(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, final_change)
  diff.update_reference_content(buf)
  diff.update_diff(buf)

  local hunks = diff.get_hunks(buf)
  eq(#hunks, 1)

  -- Reject the new changes
  success = diff.reject_diff(buf)
  eq(success, true)

  buffer_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(buffer_content, modified)
end

return T
