local M = {}
local messages = require("sia.config.messages")

local MAX_INDENT = 2 ^ 31 - 1

--- @param model string?
--- @return sia.config.Action
function M.commit(model)
  --- @type sia.config.Action
  return {
    model = model,
    system = {
      [[You generate git commit messages from staged diffs.
Output ONLY the raw commit message text — no markdown fences, no
commentary, no explanations.

## Style matching

You will receive the repository's recent commit log. This is your
primary style guide. Mirror the format exactly:
- If the project uses Conventional Commits (feat/fix/refactor/docs/…),
  use them. Preserve scope conventions and capitalisation.
- If commits are plain imperative sentences, do the same.
- Never mix styles within a single message.

## Subject line

- Imperative mood ("Add", "Fix", "Refactor", not "Added", "Fixes").
- Max 50 characters. No trailing period.
- Describe *what* the commit does at a high level, not implementation
  details.

## Body (only when needed)

- Separate from the subject with one blank line.
- Wrap lines at 72 characters.
- Explain *what* changed and *why*, not *how* (the diff shows how).
- Use bullet points for multiple logical changes.
- Omit the body for trivial or self-explanatory changes.

## Analysing the diff

- Identify the primary intent: is this a bug fix, feature, refactor,
  documentation change, test addition, or chore?
- Group related hunks mentally; don't describe each hunk individually.
- If the diff touches multiple concerns, note that in the body but
  keep the subject focused on the dominant change.]],
    },
    user = {
      function()
        local recent_commits = vim.fn.system("git log --oneline -10 2>/dev/null")
        local commits_section = ""
        if recent_commits and recent_commits ~= "" then
          commits_section = "\n\nRecent commits (follow this style):\n\n"
            .. "```\n"
            .. recent_commits
            .. "```\n"
        end

        local stat = vim.fn.system("git diff --staged --stat")
        local stat_section = ""
        if stat and stat ~= "" then
          stat_section = "\n\nDiff stat:\n```\n" .. stat .. "```\n"
        end

        return "Generate a commit message for the following staged changes:"
          .. commits_section
          .. stat_section
          .. "\n\n```diff\n"
          .. vim.fn.system("git diff --staged")
          .. "\n```"
      end,
    },
    mode = "insert",
    enabled = function()
      return require("sia.utils").is_git_repo(true) and vim.bo.ft == "gitcommit"
    end,
    insert = { placement = "cursor" },
  }
end

--- @return sia.config.Action
function M.doc()
  --- @type sia.config.Action
  return {
    system = {
      [[CRITICAL: You must ONLY output documentation comments.
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

Use tool calls if required to document the function or class.

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
    user = {
      messages.user.selection({
        show_line_numbers = false,
      }),
      "Please document the provided context",
    },
    capture = function(ctx)
      return require("sia.capture").treesitter(
        { "function.outer", "class.outer" },
        ctx.buf,
        ctx.cursor
      )
    end,
    mode = "insert",
    tools = function()
      local tools = require("sia.tools")
      return {
        tools.grep,
        tools.view,
      }
    end,

    insert = {
      placement = function()
        local ft = vim.bo.ft
        if ft == "python" then
          return {
            "below",
            function(start_line)
              local capture = require("sia.capture").treesitter({
                "function.inner",
                "class.inner",
              })
              if capture then
                return capture.start_row - 1
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
