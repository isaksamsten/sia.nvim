local M = {}

local MAX_INDENT = 2 ^ 31 - 1

function M.commit()
  return {
    system = {
      {
        role = "system",
        content = [[You are an AI assistant tasked with generating concise,
informative, and context-aware git commit messages based on code
diffs. Your goal is to provide commit messages that clearly describe
the purpose and impact of the changes. Consider the following when
crafting the commit message:

1. **Summarize the change**: Clearly describe what was changed, added, removed,
   or fixed.
2. **Explain why**: If relevant, include the reason or motivation behind the
   change.
3. **Keep it concise**: The commit message should be brief but informative,
   typically under 50 characters for the subject line.
4. If the change requires it, write a longer message two linebreaks after the
   subject line.
4. **Use an imperative tone**: Write the commit message as a command, e.g.,
   "Fix typo in README," "Add unit tests for validation logic." ]],
      },
    },
    instructions = {
      {
        role = "user",
        content = function()
          return "Given the git diff listed below, please generate a commit message for me:"
            .. "\n\n```diff\n"
            .. vim.fn.system("git diff --staged")
            .. "\n```"
        end,
      },
    },
    input = "ignore",
    mode = "insert",
    enabled = function()
      return require("sia.utils").is_git_repo(true) and vim.bo.ft == "gitcommit"
    end,
    insert = { placement = "cursor" },
  }
end

--- @return sia.config.Action
function M.doc()
  return {
    system = {
      {
        role = "system",
        content = [[CRITICAL: You must ONLY output documentation comments.
DO NOT include any function declarations, signatures, or code.

You are tasked with writing documentation for functions, methods, and classes.
Your documentation must adhere to the language conventions (e.g., JSDoc for
JavaScript, docstrings for Python, Javadoc for Java), including appropriate
tags and formatting.

WHAT TO OUTPUT:
- Documentation comments ONLY (/** */ for Java/JS, """ """ for Python, etc.)
- Parameter descriptions, return values, examples as appropriate
- Nothing else

WHAT NOT TO OUTPUT:
- Markdown fences around the output
- Function signatures or declarations (e.g., "function foo()" or "def bar():")
- Implementation code
- Class declarations (e.g., "class MyClass:")
- Any executable code whatsoever

<tool_calling>
Use tool calls if required to document the function or class. NEVER OUTPUT ANYTHING
OTHER WHILE CALLING TOOLS.
</tool_calling>

<tools>
{{tool_instructions}}
</tools>

Requirements:

1. NEVER output the function declaration or implementation. ONLY documentation.
2. Follow the language-specific documentation style strictly. Ensure all tags
   are accurate and appropriate for the language.
3. Never explain your changes. Only output the documentation.
4. **Indentation Rules**:
  1. The documentation must be indented to match the level of the provided context.
  2. Always ensure the indentation aligns with the surrounding code, allowing the documentation to be copied directly into the code without requiring reformatting.
  3. Failure to produce correctly indented output is considered an error.
5. Do not include markdown code fences or other wrappers surrounding the
   documentation.
6. If the user provides a class or struct, only document the class/struct
   itself, not its methods or functions. Any deviation is considered incorrect.
7. Double-check that your response adheres strictly to the language’s
   documentation style, contains only the requested documentation text, and
   maintains proper indentation for easy insertion into code.]],
      },
    },
    instructions = {
      require("sia.instructions").current_context({
        show_line_numbers = false,
      }),
      { role = "user", content = "Please document the provided context" },
    },
    capture = require("sia.capture").treesitter({ "@function.outer", "@class.outer" }),
    mode = "insert",
    tools = {
      "grep",
      "read",
    },
    insert = {
      placement = function()
        local ft = vim.bo.ft
        if ft == "python" then
          return {
            "below",
            function(start_line)
              local capture = require("sia.capture").treesitter({
                "@function.inner",
                "@class.inner",
              })({ buf = 0 })
              if capture then
                return capture[1] - 1
              end
              return start_line
            end,
          }
        else
          return { "above", "start" }
        end
      end,
      message = { "Generating documentation...", "Comment" },
      post_process = function(args)
        local lines = args.lines
        if #lines == 0 then
          return lines
        end

        local start_idx, end_idx = 1, #lines

        local first = lines[start_idx]:match("^%s*```")
        if first then
          start_idx = start_idx + 1
        end

        local last = lines[end_idx]:match("^%s*```%s*$")
        if last then
          end_idx = end_idx - 1
        end

        if not (first and last) then
          start_idx, end_idx = 1, #lines
        end

        while start_idx <= end_idx and lines[start_idx]:match("^%s*$") do
          start_idx = start_idx + 1
        end
        while end_idx >= start_idx and lines[end_idx]:match("^%s*$") do
          end_idx = end_idx - 1
        end

        if start_idx > end_idx then
          return {}
        end

        local target_indent
        local target_line = args.end_line + 1
        if target_line < vim.api.nvim_buf_line_count(args.buf) then
          local target_text =
            vim.api.nvim_buf_get_lines(args.buf, target_line, target_line + 1, false)[1]
          if target_text then
            target_indent = target_text:match("^%s*") or ""
          end
        end

        if target_indent then
          local min_indent = MAX_INDENT
          for i = start_idx, end_idx do
            local line = lines[i]
            if line:match("%S") then
              local indent = #(line:match("^%s*") or "")
              min_indent = math.min(min_indent, indent)
            end
          end

          if min_indent == MAX_INDENT then
            min_indent = 0
          end

          local result = {}
          for i = start_idx, end_idx do
            local line = lines[i]
            if line:match("^%s*$") then
              table.insert(result, "")
            else
              local current_indent = line:match("^%s*") or ""
              local relative_indent = current_indent:sub(min_indent + 1)
              local content = line:match("^%s*(.*)$")
              table.insert(result, target_indent .. relative_indent .. content)
            end
          end
          return result
        end

        local result = {}
        for i = start_idx, end_idx do
          table.insert(result, lines[i])
        end
        return result
      end,
    },
    cursor = "end", -- start or end
  }
end

return M
