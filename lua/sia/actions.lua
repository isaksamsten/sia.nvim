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
