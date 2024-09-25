local M = {}
local defaults = {
  named_prompts = {
    chat_system = {
      role = "system",
      content = "You are an helpful assistant",
    },
    split_system = {
      role = "system",
      content = [[You are an AI programming assistant named "Sia". You are currently plugged in to the Neovim text editor on a user's machine.

You are an expert coder and writer and helpful assistant. When providing solutions, ensure that code snippets are presented in fenced code blocks with the appropriate language identifier and follow the exact annotation format below:

1. Guidelines for formatting the answer
  - After the filetype marker in the fenced code block (e.g., ` ```python `), include the annotation `[buffer] replace-range:[start-line],[end]`, where `[start-line]` and `[end-line]` represent the starting and ending line numbers, and `[buffer]` corresponds to the user-supplied buffer number.
  - Ensure that the annotation appears **immediately after** the filetype marker on the same line, with no line breaks or new lines following the language identifier.
  - The annotation should never appear on the line **after** the filetype marker.
  - **Always preserve** indentation in the code.
  - **Never output numbered lines**

  For example, if `[buffer]=2`, and the following context is provided:

  ```lua
  1: a = 10
  2: b = 11
  ```

  add attribute c with value 12

  the response should appear as follows:

  ```lua 2 replace-range:1,2
  a = 10
  b = 11
  c = 12
  ```

  Double-check the format to ensure it is followed exactly in all code responses. The annotation must always be included on the same line as the filetype marker to comply with the formatting requirements.

3. Crucial guidelines for line numbers:
  - Always ensure that the replace range is correct and encompasses all code that needs to be replaced
  - Double check that the replace range is correct
  - The range [start-line],[end-line] is INCLUSIVE. Both [start-line] and [end-line] are included in the replacement.
  - Count EVERY line, including empty lines and comments lines, comments. Do not be lazy!
  - Use the same number for start and end lines for single-line changes.
  - For multi-line changes, ensure the range covers ALL affected lines, from first to last.
  - Double-check that your line numbers align perfectly with the original code structure.

4. Final check:
  - Review all suggestions, ensuring each line number is correct, especially the [start-line] and [end-line].
  - Confirm that no unrelated code is accidentally modified or deleted.
  - Verify that the [start-line] and [end-line] correctly include all intended lines for replacement.
  - Perform a final alignment check to ensure your line numbers haven't shifted, especially the [start-line].
  - Double-check that your line numbers align perfectly with the original code structure.
  - DO NOT return the complete modified code with applied changes!

Remember that ACCURATE line numbers are CRITICAL. The range [start-line] to [end-line] must include ALL LINES to be replaced.
Double-check ALL RANGES before finalizing your response, and MAKE SURE THAT [start-line] hasn't been shifted down.
ENSURE line numbers MATCH the original code structure and indentation ARE PRESERVED.
REMEMBER to correctly account for indentation
]],
    },
    current_buffer_line_number = {
      role = "user",
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
      content = function(opts)
        return string.format(
          "This is the complete buffer written in %s:\n%s",
          opts.ft,
          require("sia.context").get_code(1, -1, { bufnr = opts.buf, show_line_numbers = false })
        )
      end,
    },
    current_context_line_number = {
      role = "user",
      content = function(opts)
        if opts.mode == "v" then
          local code = require("sia.context").get_code(
            opts.start_line,
            opts.end_line,
            { bufnr = opts.buf, show_line_numbers = true }
          )
          return string.format(
            [[This is the context provided in buffer %s:
```%s
%s
```
  ]],
            opts.buf,
            opts.ft,
            code
          )
        else
          return "" -- filtered
        end
      end,
    },
    current_context = {
      role = "user",
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
      content = [[Note that the user query is initiated from a
text editor and your changes will be diffed against an optional context
provided by the user. The editor identifies the file as written in
{{filetype}}.

1. If possible, make sure that you only output the relevant and requested changes.
2. Refrain from explaining your reasoning or adding additional unrelated text to the output.
3. If the context pertains to code, identify the the programming
language and DO NOT ADD ANY ADDITIONAL TEXT OR MARKDOWN FORMATTING!
4. Adding code fences or markdown code blocks is an error.
5. **Always preserve** indentation for code.
6. Never include line numbers.

Double-check your response and never include code-fances or line numbers!
Remember to never include line numbers. Don't be lazy!
Remember to never include code fences. Dont't be lazy!
]],
    },
  },
  default = {
    model = "gpt-4o-mini", -- default model
    temperature = 0.5, -- default temperature
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
      split = { "split_system", "current_context_line_number" },
      chat = { -- it will automatically include the system buffer from the conversation initiating the request.
        {
          role = "system",
          content = function()
            return "This is the ongoing conversation: \n"
              .. table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, true), "\n")
          end,
        },
      },
      insert = {
        "insert_system",
        "current_buffer",
        "current_context",
      },
      diff = {
        "diff_system",
        "current_context",
      },
    },
  },
  prompts = {
    codify = {
      prompt = {
        {
          role = "system",
          content = [[You are an AI code assistant tasked with converting natural language instructions into working code. The user will provide:

1. **Filetype:** The programming language or file format they want to use.
2. **Context:** A function signature, partial code, or a short natural language instruction or pseudocode specifying the desired behavior.

Your job is to:
- **Infer the user's intent** based on the context.
- **Generate only code** — no explanations, comments, or code fences.
- **Guess the appropriate indentation** and code structure based on the provided context.
- Ensure the output is syntactically correct and aligned with the specified filetype.
- Never generate

### Example Input:
**Filetype:** Python
**Context:**
```python
def range_inclusive(start, end):
    return range(start, end + 1)

my_range = range from 1 to 10
```

### Example Output:
my_range = range_inclusive(1, 10)

### Example Input:
**Filetype:** JavaScript
**Context:**
```javascript
function sum(a, b) {
    return a + b;

let result = add 3 and 5
```

### Example Output:
let result = sum(3, 5);]],
        },
        {
          role = "user",
          content = function(opts)
            return string.format(
              "This is the current buffer, written in %s\n\n%s",
              opts.ft,
              table.concat(vim.api.nvim_buf_get_lines(opts.buf, 0, -1, false), "\n")
            )
          end,
        },
        {
          role = "user",
          content = "{{context}}",
        },
      },
      mode = "replace",
      prefix = 1,
      suffix = 0,
    },
    diagnostic = {
      prompt = {
        "split_system",
        {
          role = "user",
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
        {
          role = "user",
          content = function(opts)
            return string.format(
              "This is the complete buffer (%d):\n```%s\n%s\n```",
              opts.buf,
              opts.ft,
              require("sia.context").get_code(1, -1, { bufnr = opts.buf, show_line_numbers = true })
            )
          end,
        },
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
        {
          role = "user",
          content = [[Explain the following code:
```{{filetype}}
{{context}}
```]],
        },
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
        {
          role = "user",
          content = function(opts)
            local code = require("sia.context").get_code(
              opts.start_line,
              opts.end_line,
              { bufnr = opts.buf, show_line_numbers = false }
            )
            return string.format(
              [[This is the context provided in buffer %s:
  ```%s
  %s
  ```
  ]],
              opts.buf,
              opts.ft,
              code
            )
          end,
        },
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
  openai_api_key = "OPENAI_API_KEY",
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
  if prompt.enabled ~= nil and (prompt.enabled == false or (type(prompt.enabled) and not prompt.enabled())) then
    return true
  else
    return false
  end
end

return M
