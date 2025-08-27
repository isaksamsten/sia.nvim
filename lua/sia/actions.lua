local M = {}

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
function M.review()
  return {
    system = {
      {
        role = "system",
        content = [[Your task is to review the provided code snippet, focusing specifically on its readability, maintainability and efficiency.
Identify any issues related to:
- Naming conventions that are unclear, misleading or doesn't follow conventions for the language being used.
- The presence of unnecessary comments, or the lack of necessary ones.
- Overly complex expressions that could benefit from simplification.
- High nesting levels that make the code difficult to follow.
- The use of excessively long names for variables or functions.
- Any inconsistencies in naming, formatting, or overall coding style.
- Repetitive code patterns that could be more efficiently handled through abstraction or optimization.
- Inefficient or redundant code that could be improved or removed.

Your feedback must be concise, directly addressing each identified issue with:
- The specific line number(s) where the issue is found.
- A clear description of the problem. Never use linebreaks!
- A concrete suggestion for how to improve or correct the issue.

Format your feedback as follows:
line=<line_number>: <issue_description>

If the issue is related to a range of lines, use the following format:
line=<start_line>-<end_line>: <issue_description>

If you find multiple issues on the same line, list each issue separately within the same feedback statement, using a semicolon to separate them.

Example feedback:
line=3: The variable name 'x' is unclear. Comment next to variable declaration is unnecessary.
line=8: Expression is overly complex. Break down the expression into simpler components.
line=10: Using camel case here is unconventional for lua. Use snake case instead.
line=11-15: Excessive nesting makes the code hard to follow. Consider refactoring to reduce nesting levels.

If the code snippet has no readability issues, simply confirm that the code is clear and well-written]],
      },
    },
    instructions = {
      "current_context_line_number",
      { role = "user", content = "Please review the provided context" },
    },
    mode = "hidden",
    hidden = {
      callback = function(ctx, content)
        local list = {}
        for _, line in ipairs(content) do
          local start_line, message = line:match("^line=(%d+): (.+)")
          local end_line = start_line
          if not start_line then
            start_line, end_line, message = line:match("^line=(%d+)-(%d+): (.+)")
          end
          if start_line and end_line and message then
            table.insert(list, {
              bufnr = ctx.buf,
              filename = vim.api.nvim_buf_get_name(ctx.buf),
              lnum = tonumber(start_line),
              end_lnum = tonumber(end_line),
              col = 0,
              end_col = -1,
              text = message,
              type = "I",
            })
          end
        end
        if #list > 0 then
          vim.fn.setqflist(list, "r")
          vim.cmd.copen()
        else
          vim.notify("Sia: No review feedback")
        end
      end,
    },
  }
end

--- @return sia.config.Action
function M.doc()
  return {
    system = {
      "insert_system",
    },
    instructions = {
      {
        role = "system",
        content = [[You are tasked with writing documentation for functions,
methods, and classes. Your documentation must adhere to the language
conventions (e.g., JSDoc for JavaScript, docstrings for Python,
Javadoc for Java), including appropriate tags and formatting.

Requirements:

1. Never output the function declaration or implementation. ONLY documentation.
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
      "current_context",
      { role = "user", content = "Please document the provided context" },
    },
    capture = require("sia.capture").treesitter({ "@function.outer", "@class.outer" }),
    mode = "insert",
    insert = {
      placement = function()
        local ft = vim.bo.ft
        if ft == "python" then
          return {
            "below",
            function(start_line)
              local capture = require("sia.capture").treesitter({ "@function.inner", "@class.inner" })({ buf = 0 })
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
    },
    cursor = "end", -- start or end
  }
end

return M
