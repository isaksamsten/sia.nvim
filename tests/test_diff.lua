local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local diff = require("sia.diff")

T["sia.diff"] = MiniTest.new_set()

local function create_test_buffer()
  return vim.api.nvim_create_buf(false, true)
end

local function setup_diff_state(buf, original_lines, current_lines)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, original_lines)
  diff.update_baseline(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, current_lines)
  diff.update_reference(buf)
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
  diff.update_baseline(buf)
  diff.update_diff(buf)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, MODIFIED_JAVA_NL_EOF)
  -- This is a reference change
  diff.update_reference(buf)

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
  diff.update_baseline(buf)
  diff.update_diff(buf)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, MODIFIED_JAVA_NL_EOF)
  -- This is a reference change
  diff.update_reference(buf)

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
  diff.update_baseline(buf)
  diff.update_diff(buf)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, MODIFIED_JAVA_NL_EOF)
  diff.update_reference(buf)
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
  diff.update_baseline(buf)
  diff.update_diff(buf)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, MODIFIED_JAVA_NL_EOF)
  diff.update_reference(buf)
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

  diff.update_baseline(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, final_change)
  diff.update_reference(buf)
  diff.update_diff(buf)

  local hunks = diff.get_hunks(buf)
  eq(#hunks, 1)

  -- Reject the new changes
  success = diff.reject_diff(buf)
  eq(success, true)

  buffer_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(buffer_content, modified)
end

-- Helper that sets up diff state with a tagged turn_id
local function setup_diff_state_tagged(buf, original_lines, current_lines, turn_id)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, original_lines)
  diff.update_baseline(buf)
  -- Simulate tool call: update_baseline with turn_id snapshots before tool writes
  diff.update_baseline(buf, { turn_id = turn_id })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, current_lines)
  diff.update_reference(buf)
  diff.update_diff(buf)
end

T["sia.diff"]["rollback_to_turn"] = MiniTest.new_set()

T["sia.diff"]["rollback_to_turn"]["reverts buffer to pre-change state"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "line 2", "line 3" }
  local current = { "line 1", "modified 2", "line 3" }

  setup_diff_state_tagged(buf, original, current, "msg-1")

  local hunks = diff.get_hunks(buf)
  eq(#hunks, 1)

  local success = diff.rollback("msg-1")
  eq(success, true)

  local buffer_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(buffer_content, original)

  -- Diff state should be cleaned up (no remaining hunks)
  eq(diff.get_hunks(buf), nil)
end

T["sia.diff"]["rollback_to_turn"]["reverts multiple changes with same turn_id"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "line 2", "line 3" }

  -- Initial baseline
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, original)
  diff.update_baseline(buf)

  -- First tool call in the round
  diff.update_baseline(buf, { turn_id = "msg-1" })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line 1", "modified 2", "line 3" })
  diff.update_reference(buf)

  -- Second tool call in the same round (same turn_id)
  diff.update_baseline(buf, { turn_id = "msg-1" })
  vim.api.nvim_buf_set_lines(
    buf,
    0,
    -1,
    false,
    { "line 1", "modified 2", "line 3", "added line" }
  )
  diff.update_reference(buf)
  diff.update_diff(buf)

  local hunks = diff.get_hunks(buf)
  -- After two tool calls, baseline has absorbed round 1 changes,
  -- so only round 2's addition is a visible hunk
  eq(#hunks, 1)

  -- Rollback should revert to original (before first tool call)
  local success = diff.rollback("msg-1")
  eq(success, true)

  local buffer_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(buffer_content, original)
end

T["sia.diff"]["rollback_to_turn"]["preserves accepted hunks"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "line 2", "line 3", "line 4" }
  local current = { "line 1", "modified 2", "line 3", "modified 4" }

  setup_diff_state_tagged(buf, original, current, "msg-1")

  local hunks = diff.get_hunks(buf)
  eq(#hunks, 2)

  -- Accept the first hunk (modified 2)
  diff.accept_single_hunk(buf, 1)
  hunks = diff.get_hunks(buf)
  eq(#hunks, 1) -- only modified 4 remains

  -- Rollback should only revert the unaccepted hunk (modified 4)
  local success = diff.rollback("msg-1")
  eq(success, true)

  local buffer_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  -- modified 2 was accepted, so it stays; modified 4 was not, so it reverts
  eq(buffer_content, { "line 1", "modified 2", "line 3", "line 4" })
end

T["sia.diff"]["rollback_to_turn"]["user edit merging with AI change implicitly accepts it"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "line 2", "line 3" }
  local ai_change = { "line 1", "ai modified", "line 3" }

  setup_diff_state_tagged(buf, original, ai_change, "msg-1")

  -- User edits the buffer adjacent to AI change (adds a line right after it).
  -- The diff system merges this with the AI change into a single baseline_hunk,
  -- which implicitly accepts the AI change.
  vim.api.nvim_buf_set_lines(
    buf,
    0,
    -1,
    false,
    { "line 1", "ai modified", "line 3", "user added" }
  )

  -- A new tool call triggers update_baseline, which absorbs the merged hunk
  diff.update_baseline(buf, { turn_id = "msg-2" })
  diff.update_diff(buf)

  -- Rollback msg-1: the AI change was implicitly accepted via the user edit,
  -- so both the AI change and user edit are preserved in the snapshot
  local success = diff.rollback("msg-1")
  eq(success, true)

  local buffer_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(buffer_content, { "line 1", "ai modified", "line 3", "user added" })
end

T["sia.diff"]["rollback_to_turn"]["only reverts from target round onwards"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "line 2", "line 3" }

  -- Initial baseline
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, original)
  diff.update_baseline(buf)

  -- Round 1: AI modifies line 2
  diff.update_baseline(buf, { turn_id = "msg-1" })
  vim.api.nvim_buf_set_lines(
    buf,
    0,
    -1,
    false,
    { "line 1", "round1 modified", "line 3" }
  )
  diff.update_reference(buf)

  -- Round 2: AI adds a line
  diff.update_baseline(buf, { turn_id = "msg-2" })
  vim.api.nvim_buf_set_lines(
    buf,
    0,
    -1,
    false,
    { "line 1", "round1 modified", "line 3", "round2 added" }
  )
  diff.update_reference(buf)
  diff.update_diff(buf)

  -- Rollback only round 2
  local success = diff.rollback("msg-2")
  eq(success, true)

  local buffer_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  -- Round 1 changes should remain, round 2 reverted
  eq(buffer_content, { "line 1", "round1 modified", "line 3" })

  -- Round 1 hunks should still be tracked
  local hunks = diff.get_hunks(buf)
  eq(#hunks, 1)
  eq(hunks[1].type, "change")
end

T["sia.diff"]["rollback_to_turn"]["rollback first round reverts everything"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "line 2", "line 3" }

  -- Initial baseline
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, original)
  diff.update_baseline(buf)

  -- Round 1
  diff.update_baseline(buf, { turn_id = "msg-1" })
  vim.api.nvim_buf_set_lines(
    buf,
    0,
    -1,
    false,
    { "line 1", "round1 modified", "line 3" }
  )
  diff.update_reference(buf)

  -- Round 2
  diff.update_baseline(buf, { turn_id = "msg-2" })
  vim.api.nvim_buf_set_lines(
    buf,
    0,
    -1,
    false,
    { "line 1", "round1 modified", "line 3", "round2 added" }
  )
  diff.update_reference(buf)
  diff.update_diff(buf)

  -- Rollback from round 1 (reverts everything)
  local success = diff.rollback("msg-1")
  eq(success, true)

  local buffer_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(buffer_content, original)
  eq(diff.get_hunks(buf), nil)
end

T["sia.diff"]["rollback_to_turn"]["no-op after full acceptance"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "line 2", "line 3" }
  local current = { "line 1", "modified 2", "line 3" }

  setup_diff_state_tagged(buf, original, current, "msg-1")

  -- Accept all changes (cleans up diff state entirely)
  diff.accept_diff(buf)
  eq(diff.get_diff_state(buf), nil)

  -- Rollback should fail gracefully
  local success = diff.rollback_buf(buf, "msg-1")
  eq(success, false)

  -- Buffer content unchanged (accepted changes stay)
  local buffer_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(buffer_content, current)
end

T["sia.diff"]["rollback_to_turn"]["returns false for invalid turn_id"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "line 2" }
  local current = { "line 1", "modified 2" }

  setup_diff_state_tagged(buf, original, current, "msg-1")

  local success = diff.rollback_buf(buf, "nonexistent")
  eq(success, false)

  -- Buffer unchanged
  local buffer_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(buffer_content, current)
end

T["sia.diff"]["rollback_to_turn"]["returns false for buffer without diff state"] = function()
  local buf = create_test_buffer()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line 1" })

  local success = diff.rollback_buf(buf, "msg-1")
  eq(success, false)
end

T["sia.diff"]["get_change_snapshots"] = MiniTest.new_set()

T["sia.diff"]["get_change_snapshots"]["tracks snapshots per turn_id"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "line 2" }

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, original)
  diff.update_baseline(buf)

  diff.update_baseline(buf, { turn_id = "msg-1" })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line 1", "modified" })
  diff.update_reference(buf)

  diff.update_baseline(buf, { turn_id = "msg-2" })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line 1", "modified", "added" })
  diff.update_reference(buf)

  local snapshots = diff.get_change_snapshots(buf)
  eq(snapshots["msg-1"], original)
  -- msg-2 snapshot captures state after msg-1's edits were absorbed
  eq(type(snapshots["msg-2"]), "table")

  local order = diff.get_change_order(buf)
  eq(order, { "msg-1", "msg-2" })
end

T["sia.diff"]["get_change_snapshots"]["only records first encounter per turn_id"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "line 2" }

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, original)
  diff.update_baseline(buf)

  -- First tool call for msg-1
  diff.update_baseline(buf, { turn_id = "msg-1" })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line 1", "modified" })
  diff.update_reference(buf)

  -- Second tool call for msg-1 (same turn_id)
  diff.update_baseline(buf, { turn_id = "msg-1" })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line 1", "modified", "added" })
  diff.update_reference(buf)

  -- Only one snapshot, capturing state before first edit
  local snapshots = diff.get_change_snapshots(buf)
  eq(snapshots["msg-1"], original)

  local order = diff.get_change_order(buf)
  eq(order, { "msg-1" })
end

T["sia.diff"]["get_change_snapshots"]["returns nil for buffer without diff state"] = function()
  local buf = create_test_buffer()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line 1" })
  eq(diff.get_change_snapshots(buf), nil)
end

T["sia.diff"]["rollback_to_turn"]["preserves accepted hunks and implicitly accepted edits"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "line 2", "line 3", "line 4" }
  local ai_change = { "line 1", "ai modified 2", "line 3", "ai modified 4" }

  setup_diff_state_tagged(buf, original, ai_change, "msg-1")

  -- Accept first hunk (ai modified 2)
  diff.accept_single_hunk(buf, 1)

  -- User makes their own edit (adds a line at end, adjacent to ai modified 4).
  -- The diff system merges the user edit with the remaining AI change,
  -- implicitly accepting ai modified 4 as well.
  vim.api.nvim_buf_set_lines(
    buf,
    0,
    -1,
    false,
    { "line 1", "ai modified 2", "line 3", "ai modified 4", "user line" }
  )

  -- A new tool call triggers update_baseline, which absorbs the merged hunk
  diff.update_baseline(buf, { turn_id = "msg-2" })
  diff.update_diff(buf)

  -- Rollback msg-1: both the explicitly accepted hunk AND the implicitly
  -- accepted (merged) hunk are preserved in the snapshot
  local success = diff.rollback("msg-1")
  eq(success, true)

  local buffer_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(
    buffer_content,
    { "line 1", "ai modified 2", "line 3", "ai modified 4", "user line" }
  )
end

T["sia.diff"]["rollback_to_turn"]["rollback with list of turn_ids across buffers"] = function()
  local buf1 = create_test_buffer()
  local buf2 = create_test_buffer()
  local original1 = { "file1 line 1", "file1 line 2" }
  local original2 = { "file2 line 1", "file2 line 2" }

  -- buf1: Round 1 edits
  vim.api.nvim_buf_set_lines(buf1, 0, -1, false, original1)
  diff.update_baseline(buf1)
  diff.update_baseline(buf1, { turn_id = "msg-1" })
  vim.api.nvim_buf_set_lines(buf1, 0, -1, false, { "file1 line 1", "msg1 modified" })
  diff.update_reference(buf1)

  -- buf2: Round 2 edits (different buffer, different turn)
  vim.api.nvim_buf_set_lines(buf2, 0, -1, false, original2)
  diff.update_baseline(buf2)
  diff.update_baseline(buf2, { turn_id = "msg-2" })
  vim.api.nvim_buf_set_lines(buf2, 0, -1, false, { "file2 line 1", "msg2 modified" })
  diff.update_reference(buf2)
  diff.update_diff(buf2)

  -- Rollback both turns (as conversation:rollback_to would return)
  local success = diff.rollback({ "msg-1", "msg-2" })
  eq(success, true)

  -- Both buffers should be reverted to their original state
  eq(vim.api.nvim_buf_get_lines(buf1, 0, -1, false), original1)
  eq(vim.api.nvim_buf_get_lines(buf2, 0, -1, false), original2)

  eq(diff.get_hunks(buf1), nil)
  eq(diff.get_hunks(buf2), nil)
end

T["sia.diff"]["rollback_to_turn"]["rollback turn without diffs reverts later turns"] = function()
  local buf = create_test_buffer()
  local original = { "line 1", "line 2", "line 3" }

  -- Initial baseline
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, original)
  diff.update_baseline(buf)

  -- Round 1: AI modifies line 2
  diff.update_baseline(buf, { turn_id = "msg-1" })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line 1", "round1 modified", "line 3" })
  diff.update_reference(buf)

  -- Round 2: conversation-only turn (no file edits, no diff snapshot for msg-2)

  -- Round 3: AI adds a line
  diff.update_baseline(buf, { turn_id = "msg-3" })
  vim.api.nvim_buf_set_lines(
    buf,
    0,
    -1,
    false,
    { "line 1", "round1 modified", "line 3", "round3 added" }
  )
  diff.update_reference(buf)
  diff.update_diff(buf)

  -- Rollback turns msg-2 and msg-3 (msg-2 has no diffs, msg-3 does)
  -- This simulates conversation:rollback_to("msg-2") returning {"msg-2", "msg-3"}
  local success = diff.rollback({ "msg-2", "msg-3" })
  eq(success, true)

  -- Round 3 changes should be reverted; round 1 should remain
  local buffer_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(buffer_content, { "line 1", "round1 modified", "line 3" })

  -- Round 1 hunks should still be tracked
  local hunks = diff.get_hunks(buf)
  eq(#hunks, 1)
  eq(hunks[1].type, "change")
end

T["sia.diff"]["rollback_to_turn"]["rollback turn without diffs on separate buffer"] = function()
  local buf1 = create_test_buffer()
  local buf2 = create_test_buffer()
  local original1 = { "file1 line 1", "file1 line 2" }
  local original2 = { "file2 line 1", "file2 line 2" }

  -- Round 1: edits buf1
  vim.api.nvim_buf_set_lines(buf1, 0, -1, false, original1)
  diff.update_baseline(buf1)
  diff.update_baseline(buf1, { turn_id = "msg-1" })
  vim.api.nvim_buf_set_lines(buf1, 0, -1, false, { "file1 line 1", "msg1 modified" })
  diff.update_reference(buf1)
  diff.update_diff(buf1)

  -- Round 2: conversation-only turn (no diffs at all)

  -- Round 3: edits buf2
  vim.api.nvim_buf_set_lines(buf2, 0, -1, false, original2)
  diff.update_baseline(buf2)
  diff.update_baseline(buf2, { turn_id = "msg-3" })
  vim.api.nvim_buf_set_lines(buf2, 0, -1, false, { "file2 line 1", "msg3 modified" })
  diff.update_reference(buf2)
  diff.update_diff(buf2)

  -- Rollback from conversation turn msg-2 (which has no diffs)
  -- conversation:rollback_to("msg-2") returns {"msg-2", "msg-3"}
  -- The old code with diff.rollback("msg-2") would find NO buffers and do nothing,
  -- leaving msg-3's changes on buf2 intact. This is the bug.
  local success = diff.rollback({ "msg-2", "msg-3" })
  eq(success, true)

  -- buf1 should be UNCHANGED (msg-1 was not rolled back)
  eq(vim.api.nvim_buf_get_lines(buf1, 0, -1, false), { "file1 line 1", "msg1 modified" })
  local hunks1 = diff.get_hunks(buf1)
  eq(#hunks1, 1)

  -- buf2 should be REVERTED (msg-3 was rolled back)
  eq(vim.api.nvim_buf_get_lines(buf2, 0, -1, false), original2)
  eq(diff.get_hunks(buf2), nil)
end



return T
