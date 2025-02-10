local M = {}

--- @return sia.config.Action
function M.edit()
  return {
    mode = "hidden",
    hidden = {
      callback = function(ctx, content)
        return require("sia.blocks").replace_blocks_callback(ctx, content)
      end,
    },
    tools = {
      require("sia.tools").add_file,
    },
    instructions = {
      "editblock_system",
      "git_files",
      require("sia.instructions").files,
      "current_context",
    },
    reminder = "editblock_reminder",
  }
end

--- @return sia.config.Action
function M.diagnostic()
  local utils = require("sia.utils")
  return {
    instructions = {
      "editblock_system",
      {
        role = "user",
        id = function(ctx)
          return { "diagnostics", ctx.buf, ctx.pos[1], ctx.pos[2] }
        end,
        persistent = true,
        description = function(opts)
          return string.format(
            "Diagnostics on line %d to %d in %s",
            opts.pos[1],
            opts.pos[2],
            utils.get_filename(opts.buf)
          )
        end,
        content = function(opts)
          local start_line, end_line = opts.pos[1], opts.pos[2]
          local diagnostics = utils.get_diagnostics(start_line, end_line, { buf = opts.buf })
          local concatenated_diagnostics = ""
          for i, diagnostic in ipairs(diagnostics) do
            concatenated_diagnostics = concatenated_diagnostics
              .. i
              .. ". Issue "
              .. i
              .. "\n  - Location: Line "
              .. diagnostic.line_number
              .. "\n  - Severity: "
              .. diagnostic.severity
              .. "\n  - Message: "
              .. diagnostic.message
              .. "\n"
          end
          if concatenated_diagnostics == "" then
            return "No diagnostics found."
          end

          return string.format(
            [[This is a list of the diagnostic messages in %s:
                      %s
                      ]],
            utils.get_filename(opts.buf, ":p"),
            concatenated_diagnostics
          )
        end,
      },
      require("sia.instructions").files,
      "current_context",
    },
    mode = "split",
    split = {
      block_action = "search_replace",
    },
    reminder = "editblock_reminder",
    range = true,
  }
end

function M.commit()
  return {
    instructions = {
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
4. **Use an imperative tone**: Write the commit message as a command, e.g.,
   "Fix typo in README," "Add unit tests for validation logic." ]],
      },
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
    instructions = {
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
      "current_context_line_number",
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
function M.explain()
  return {
    instructions = {
      {
        role = "system",
        content = [[When asked to explain code, follow these steps:

1. Identify the programming language.
2. Describe the purpose of the code and reference core concepts from the programming language.
3. Explain each function or significant block of code, including parameters and return values.
4. Highlight any specific functions or methods used and their roles.
5. Provide context on how the code fits into a larger application if applicable.

If you need additional context to improve the explanation. Ask the user to add
the file to the context using SiaFile.]],
      },
      "git_files",
      require("sia.instructions").files(),
      "current_context_line_number",
    },
    mode = "split",
    range = true,
  }
end

--- @return sia.config.Action
function M.unittest()
  return {
    instructions = {
      "editblock_system",
      "git_files",
      require("sia.instructions").files,
      "current_context",
      {
        role = "user",
        hide = true,
        content = [[Generate unit tests for the provided function or module flowing these steps:

  1. Use the provided file list to idenfify a suitable file to place the test in.
    - If the files' contents have not been added to the conversation, ASK the USER to ADD it!
  2. Identify the purpose of the function or module to be tested.
  3. List the edge cases and typical use cases that should be covered in the tests and share the plan with the user.
  4. Generate unit tests using an appropriate testing framework for the identified programming language.
  5. Ensure the tests cover:
        - Normal cases
        - Edge cases
        - Error handling (if applicable)
  6. Provide the generated unit tests in a clear and organized manner without additional explanations or chat.
  7. Based on the provided list of files, place the test in an appropriate file.
  ]],
      },
    },
    capture = require("sia.capture").treesitter("@function.outer"),
    mode = "split",
    split = {
      block_action = "search_replace",
      cmd = "vsplit",
    },
    reminder = "editblock_reminder",
    tools = {
      require("sia.tools").add_file,
    },
    range = true,
    wo = {},
  }
end

--- @return sia.config.Action
function M.doc()
  return {
    instructions = {
      "insert_system",
      {
        role = "system",
        content = [[You are tasked with writing documentation for functions,
methods, and classes. Your documentation must adhere to the language
conventions (e.g., JSDoc for JavaScript, docstrings for Python,
Javadoc for Java), including appropriate tags and formatting.

Requirements:

1. **Never output the function declaration or implementation**
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

--- @param config { split: boolean? }?
--- @return sia.config.Action
function M.fix(config)
  config = config or {}
  --- @type sia.config.Action
  local action = {
    instructions = {
      "editblock_system",
      {
        role = "user",
        enabled = function(ctx)
          return vim.bo.ft == "qf"
        end,
        content = function(ctx)
          local function get_qf_item()
            local list = vim.fn.getqflist()
            local cursor_line = ctx.cursor[1]
            return list[cursor_line]
          end
          local item = get_qf_item()
          return string.format("At line %d: %s", item.lnum, item.text)
        end,
      },
    },
    reminder = "editblock_reminder",
    enabled = function()
      return vim.bo.ft == "qf" and #vim.fn.getqflist() > 0
    end,
    modify_instructions = function(instructions, ctx)
      local function get_qf_item()
        local list = vim.fn.getqflist()
        local cursor_line = ctx.cursor[1]
        return list[cursor_line]
      end

      local item = get_qf_item()
      if item and item.bufnr then
        table.insert(instructions, 2, require("sia.instructions").buffer(item.bufnr))
      end
    end,
  }

  if not config.split then
    action.mode = "hidden"
    action.hidden = {
      callback = function(ctx, content)
        return require("sia.blocks").replace_blocks_callback(ctx, content)
      end,
    }
  else
    action.mode = "split"
    action.split = {
      cmd = "wincmd p | vsplit",
      block_action = "search_replace",
    }
  end
  return action
end

return M
