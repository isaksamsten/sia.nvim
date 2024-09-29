local M = {}
local defaults = {
  models = {
    ["gpt-4o"] = { "openai", "gpt-4o-2024-08-06" },
    ["gpt-4o-mini"] = { "openai", "gpt-4o-mini" },
    copilot = { "copilot", "gpt-4o-2024-05-13" },
  },
  named_prompts = {
    chat_system = {
      role = "system",
      content = "You are an helpful assistant",
    },
    split_system = {
      role = "system",
      reuse = true,
      content = [[You are an AI assistant named "Sia" integrated with Neovim.

Provide code snippets with precise annotations in fenced blocks, following these guidelines:

- Include `[buffer] replace-range:[start-line],[end-line]` right after the language identifier in the code block.
- Always preserve indentation, and avoid outputting numbered lines.
- Replace ranges must accurately reflect the lines being modified, including comments or closing brackets.
- Double-check start-line and end-line accuracy, ensuring the range covers the exact lines of change without overwriting or deleting other content.

Example (user provides buffer 2):

```python 2 replace-range:5,5
   self.b = b
   self.c = None
```

Ensure all responses adhere to this format.]],
    },
    current_buffer_line_number = {
      role = "user",
      hidden = function(opts)
        return string.format("Buffer %s", require("sia.utils").get_filename(opts.buf))
      end,
      reuse = true,
      content = function(opts)
        return string.format(
          "This is the complete buffer (%d):\n```%s\n%s\n```",
          opts.buf,
          opts.ft,
          require("sia.context").get_code(1, -1, { bufnr = opts.buf, show_line_numbers = true })
        )
      end,
    },
    current_buffer = {
      role = "user",
      hidden = function(opts)
        return string.format("Buffer %s", opts.buf)
      end,
      reuse = true,
      content = function(opts)
        return string.format(
          "This is the complete buffer written in %s:\n%s",
          opts.ft,
          require("sia.context").get_code(1, -1, { bufnr = opts.buf, show_line_numbers = false })
        )
      end,
    },
    current_context_line_number = require("sia.context").current_context_line_number(),
    current_context = {
      role = "user",
      hidden = function(opts)
        local end_line = opts.end_line
        if opts.context_is_buffer then
          end_line = vim.api.nvim_buf_line_count(opts.buf)
        end
        return string.format(
          "Lines %d to %d in %s",
          opts.start_line,
          end_line,
          require("sia.utils").get_filename(opts.buf)
        )
      end,
      reuse = true,
      content = function(opts)
        if opts.mode == "v" then
          local code = require("sia.context").get_code(
            opts.start_line,
            opts.end_line,
            { bufnr = opts.buf, show_line_numbers = false }
          )
          return string.format(
            [[This is the provided context written in %s:
%s]],
            opts.ft,
            code
          )
        else
          return ""
        end
      end,
    },
    insert_system = {
      role = "system",
      content = [[Note that the user query is initiated from
a text editor and that your changes will be inserted verbatim into the editor.
The editor identifies the file as written in {{filetype}}.

1. If possible, make sure that you only output the relevant and requested information.
2. Refrain from explaining your reasoning, unless the user requests it, or adding unrelated text to the output.
3. If the context pertains to code, identify the programming language and do not add any additional text or markdown formatting.
4. Adding code fences or markdown code blocks is an error.
5. If explanations are needed add them as relevant comments using correct syntax for the identified language.
6. **Always preserve** indentation for code.
7. Never include the full provided context in your response. Only output the relevant requested information.
8. Never include code fences when outputting code.

]],
    },
    diff_system = {
      role = "system",
      content = [[The user query is initiated from a text editor, and the response should never include code fences or line numbers.

Guidelines:

	1.	Only output the requested changes.
	2.	Never include code fences (```) or line numbers in the output.
	3.	Always preserve the original indentation for code.
	4.	Focus on direct, concise responses, and avoid additional explanations unless explicitly asked.]],
    },
  },
  default = {
    -- model = "gpt-4o-mini", -- default model
    model = "copilot",
    temperature = 0.3, -- default temperature
    prefix = 1, -- prefix lines in insert
    suffix = 0, -- suffix lines in insert
    split = {
      cmd = "vsplit",
      wo = { wrap = true },
    },
    diff = {
      wo = { "wrap", "linebreak", "breakindent", "breakindentopt", "showbreak" },
    },
    insert = {
      placement = "cursor",
    },
    replace = {
      highlight = "DiffAdd",
      timeout = 300,
      map = { replace = "gr", insert_above = "ga", insert_below = "gb" },
    },
    mode_prompt = {
      split = {
        model = "gpt-4o",
        temperature = 0.0,
        prompt = { "split_system", "current_context_line_number" },
      },
      chat = {
        -- reuse model and temperature from the initiating prompt
        prompt = { -- it will automatically include the system buffer from the conversation initiating the request.
          {
            role = "system",
            content = function()
              return "This is the ongoing conversation: \n"
                .. table.concat(require("sia.utils").filter_hidden(vim.api.nvim_buf_get_lines(0, 0, -1, true)), "\n")
            end,
          },
        },
      },
      insert = {
        prompt = {
          "insert_system",
          "current_buffer",
          "current_context",
        },
      },
      diff = {
        model = "gpt-4o",
        prompt = {
          "diff_system",
          "current_context",
        },
      },
    },
  },
  prompts = {
    diagnostic = {
      prompt = {
        "split_system",
        {
          role = "user",
          reuse = true,
          hidden = function(opts)
            return string.format(
              "Diagnostics on line %d to %d in %s",
              opts.start_line,
              opts.end_line,
              require("sia.utils").get_filename(opts.buf)
            )
          end,
          content = function(opts)
            local diagnostics = require("sia.context").get_diagnostics(opts.start_line, opts.end_line, opts.buf)
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
            return string.format(
              [[The programming language is %s. The buffer is: %s. This is a list of the diagnostic messages:
%s
]],
              opts.ft,
              opts.buf,
              concatenated_diagnostics
            )
          end,
        },
        "current_context_line_number",
      },
      mode = "split",
      range = true,
      model = "gpt-4o",
    },
    commit = {
      prompt = {
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
        local function is_git_repo()
          local handle = io.popen("git rev-parse --is-inside-work-tree 2>/dev/null")
          if handle == nil then
            return false
          end
          local result = handle:read("*a")
          handle:close()
          if result:match("true") then
            local exit_code = os.execute("git diff --cached --quiet")
            return exit_code ~= nil and exit_code ~= 0
          end
          return false
        end
        return is_git_repo()
      end,
      insert = { placement = "cursor" },
    },
    explain = {
      prompt = {
        {
          role = "system",
          content = [[When asked to explain code, follow these steps:

  1. Identify the programming language.
  2. Describe the purpose of the code and reference core concepts from the programming language.
  3. Explain each function or significant block of code, including parameters and return values.
  4. Highlight any specific functions or methods used and their roles.
  5. Provide context on how the code fits into a larger application if applicable.]],
        },
        "current_context_line_number",
      },
      mode = "split",
      temperature = 0.5,
      range = true,
    },
    unittest = {
      prompt = {
        {
          role = "system",
          content = [[When generating unit tests, follow these steps:

  1. Identify the programming language.
  2. Identify the purpose of the function or module to be tested.
  3. List the edge cases and typical use cases that should be covered in the tests and share the plan with the user.
  4. Generate unit tests using an appropriate testing framework for the identified programming language.
  5. Ensure the tests cover:
        - Normal cases
        - Edge cases
        - Error handling (if applicable)
  6. Provide the generated unit tests in a clear and organized manner without additional explanations or chat.]],
        },
        "current_context",
      },
      context = require("sia.context").treesitter("@function.outer"),
      use_mode_prompt = false,
      mode = "split",
      split = {
        cmd = "vsplit",
      },
      range = true,
      wo = {},
      temperature = 0.5,
    },
    doc = {
      prompt = {
        "insert_system",
        {
          role = "system",
          content = [[You are tasked with writing documentation for functions, methods, and classes written in {{filetype}}. Your documentation must adhere to the {{language}} conventions (e.g., JSDoc for JavaScript, docstrings for Python, Javadoc for Java), including appropriate tags and formatting.

**Requirements:**
1. Follow the language-specific documentation style strictly (e.g., use `/** ... */` for JavaScript, `""" ... """` for Python).
2. Only output the documentation text; never output the function declaration, implementation, or any code examples.
3. Include all relevant sections, such as:
   - A clear description of the function's purpose.
   - Detailed parameter explanations using the appropriate tags (e.g., `@param` for JSDoc).
   - Return value descriptions using language-specific tags (e.g., `@return`).
4. Avoid including any code snippets, including function signatures or suggested implementations.
5. Never under any circumstance include markdown code fences surrounding the documentation. Failure to adhere strictly to this format will result in an incorrect response.
6. If the user request a specific format, follow that format but remember to strictly adhere to the rules! Non compliance is an error!
7. If the user gives you a class, struct etc, only provide documentation for the class, struct and NOT for the functions/methods. Non compliance is an error!

**Important**: Double-check that your response strictly follows the language's
documentation style and contains only the requested documentation text. If any
code is included, the response is incorrect.]],
        },
        {
          role = "user",
          content = "Here is the function/class/method/struct:\n```{{filetype}}\n{{context}}\n```",
        },
      },
      prefix = 2,
      suffix = 0,
      context = require("sia.context").treesitter({ "@function.outer", "@class.outer" }),
      mode = "insert",
      insert = {
        placement = function()
          local ft = vim.bo.ft
          if ft == "python" then
            return { "below", "start" }
          else
            return { "above", "start" }
          end
        end,
      },
      cursor = "end", -- start or end
    },
  },
  report_usage = true,
  debug = false,
}

M.options = {}

function M.setup(options)
  M.options = vim.tbl_deep_extend("force", {}, defaults, options or {})
  if M.options.report_usage == true then
    vim.api.nvim_create_autocmd("User", {
      pattern = "SiaUsageReport",
      callback = function(args)
        local data = args.data
        if data then
          vim.notify("Total tokens: " .. data.total_tokens)
        end
      end,
    })
  end
end

function M._is_disabled(prompt)
  if prompt.enabled == false or (type(prompt.enabled) == "function" and not prompt.enabled()) then
    return true
  end
  return false
end

return M
