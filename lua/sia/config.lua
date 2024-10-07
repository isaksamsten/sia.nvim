local M = {}
local providers = require("sia.provider")

--- @alias sia.config.Role "user"|"system"|"assistant"
--- @alias sia.config.Placement ["below"|"above", "start"|"end"|"cursor"]|"start"|"end"|"cursor"
--- @alias sia.config.ActionInput "require"|"ignore"
--- @alias sia.config.ActionMode "split"|"diff"|"insert"|"edit"

--- @class sia.config.Insert
--- @field placement (fun():sia.config.Placement)|sia.config.Placement
--- @field cursor ("start"|"end")?

--- @class sia.config.Diff
--- @field wo [string]?
--- @field cmd "vsplit"|"split"?

--- @class sia.config.Split
--- @field cmd "vsplit"|"split"?
--- @field block_action "search_replace"?
--- @field wo table<string, any>?

--- @class sia.config.Replace
--- @field highlight string
--- @field timeout number?

--- @class sia.config.Instruction
--- @field id (fun(ctx:sia.ActionArgument?):table?)|nil
--- @field role sia.config.Role
--- @field persistent boolean?
--- @field available (fun(ctx:sia.ActionArgument?):boolean)?
--- @field hide boolean?
--- @field description ((fun(ctx:sia.Context?):string)|string)?
--- @field content (fun(ctx: sia.Context?):string)|string|string[]

--- @class sia.config.Action
--- @field instructions [string|sia.config.Instruction]
--- @field model string?
--- @field temperature number?
--- @field input sia.config.ActionInput?
--- @field mode sia.config.ActionMode?
--- @field enabled (fun():boolean)|boolean?
--- @field capture nil|(fun(arg: sia.ActionArgument):[number, number])
--- @field range boolean?
--- @field insert sia.config.Insert?
--- @field diff sia.config.Diff?
--- @field split sia.config.Split?

--- @class sia.config.Defaults
--- @field model string
--- @field temperature number
--- @field actions table<"diff"|"split"|"insert", sia.config.Action>
--- @field split sia.config.Split
--- @field replace sia.config.Replace
--- @field diff sia.config.Diff
--- @field insert sia.config.Insert

--- @alias sia.config.Models table<string, [string, string]>

--- @class sia.config.Provider
--- @field base_url string
--- @field api_key fun():string?

--- @class sia.config.Options
--- @field models sia.config.Models
--- @field instructions table<string, sia.config.Instruction>
--- @field defaults sia.config.Defaults
--- @field actions table<string, sia.config.Action>
--- @field providers table<string, sia.config.Provider>
--- @field debug boolean?
--- @field report_usage boolean?
M.options = {}

--- @type sia.config.Options
local defaults = {
  providers = {
    openai = providers.openai,
    copilot = providers.copilot,
  },
  models = {
    ["gpt-4o"] = { "openai", "gpt-4o" },
    ["gpt-4o-mini"] = { "openai", "gpt-4o-mini" },
    copilot = { "copilot", "gpt-4o" },
  },
  instructions = {
    split_system = {
      role = "system",
      persistent = true,
      content = [[You are an AI assistant named "Sia" integrated with Neovim.

If the user provides a code context with line numbers and a buffer number, then provide code snippets with precise annotations in fenced blocks,
following these guidelines:

- Include `[buffer] replace-range:[start-line],[end-line]` right after the language identifier in the code block.
- Always preserve indentation, and avoid outputting numbered lines.
- Replace ranges must accurately reflect the lines being modified, including comments or closing brackets.
- Double-check start-line and end-line accuracy, ensuring the range covers the exact lines of change without overwriting or deleting other content.

Example (user provides buffer 2):

```python 2 replace-range:5,6
   self.b = b
   self.c = None
```]],
    },
    current_buffer_line_number = require("sia.instructions").current_buffer(true),
    current_buffer = require("sia.instructions").current_buffer(false),
    current_context_line_number = require("sia.instructions").current_context(true),
    current_context = require("sia.instructions").current_context(false),
    insert_system = {
      role = "system",
      content = [[Note that the user query is initiated from a text editor and that your changes will be inserted verbatim into the editor. The editor identifies the file as written in {{filetype}}.

1. If possible, make sure that you only output the relevant and requested information.
2. Refrain from explaining your reasoning, unless the user requests it, or adding unrelated text to the output.
3. If the context pertains to code, identify the programming language and do not add any additional text or markdown formatting.
4. If explanations are needed, add them as relevant comments using the correct syntax for the identified language.
5. **Always preserve** indentation for code.
6. Never include the full provided context in your response. Only output the relevant requested information.
7. **Do not include code fences** (e.g., triple backticks ``` or any other code delimiters) or any markdown formatting when outputting code. Output the code directly, without surrounding it with code fences or additional formatting.]],
    },
    diff_system = {
      role = "system",
      content = [[The user query is initiated from a text editor and will automatically be diffed against the input.

Guidelines:

	1.	Only output the requested changes.
	2.	**Never** include code fences (```) or line numbers in your output unless they are required for the specific context (e.g., editing a Markdown file that uses code fences).
	3.	**Never surround your complete answer with code fences, under any circumstances, unless the user explicitly asks for them.**
  4.	Always preserve the original indentation for code.
	5.	Focus on direct, concise responses, and avoid additional explanations unless explicitly asked.]],
    },
  },
  --- @type sia.config.Defaults
  defaults = {
    model = "gpt-4o-mini", -- default model
    temperature = 0.3, -- default temperature
    prefix = 1, -- prefix lines in insert
    suffix = 0, -- suffix lines in insert
    split = {
      cmd = "vsplit",
      wo = { wrap = true },
    },
    diff = {
      cmd = "vsplit",
      wo = { "wrap", "linebreak", "breakindent", "breakindentopt", "showbreak" },
    },
    insert = {
      placement = "cursor",
    },
    replace = {
      highlight = "DiffAdd",
      timeout = 300,
    },
    actions = {
      split = {
        model = "gpt-4o",
        mode = "split",
        temperature = 0.2,
        instructions = { "split_system", "current_context_line_number" },
      },
      insert = {
        mode = "insert",
        temperature = 0.2,
        instructions = {
          "insert_system",
          "current_buffer",
        },
      },
      diff = {
        mode = "diff",
        model = "gpt-4o",
        temperature = 0.2,
        instructions = {
          "diff_system",
          "current_buffer",
          "current_context",
        },
      },
      --- @type sia.config.Action
      edit = {
        model = "gpt-4o",
        mode = "split",
        split = {
          block_action = "search_replace",
        },
        instructions = {
          {
            role = "system",
            content = [[Act as an expert software developer. Always use best practices when coding.
Respect and use existing conventions, libraries, etc that are already present in the code base.
Take requests for changes to the supplied code.
If the request is ambiguous, ask questions.

Always reply to the user in the same language they are using.

Once you understand the request you MUST:

1. Think step-by-step and explain the needed changes in a few short sentences.

2. Describe each change with a *SEARCH/REPLACE block* per the examples below.

3. If you are unsure what the user wants, ask for clarification before making changes.

All changes to files must use this *SEARCH/REPLACE block* format.

# *SEARCH/REPLACE block* Rules:

Every *SEARCH/REPLACE block* must use this format:
1. The opening fence, code language and the *FULL* file path alone on a line, verbatim. No bold asterisks, no quotes around it, no escaping of characters, etc., eg: ```python test.py
2. The start of search block: <<<<<<< SEARCH
3. A contiguous chunk of lines to search for in the existing source code
4. The dividing line: =======
5. The lines to replace into the source code
6. The end of the replace block: >>>>>>> REPLACE
7. The closing fence: ```

Use the *FULL* file path, as shown to you by the user.

Every *SEARCH* section must *EXACTLY MATCH* the existing file content, character for character, including all comments, docstrings, etc.
If the file contains code or other data wrapped/escaped in json/xml/quotes or other containers, you need to propose edits to the literal contents of the file, including the container markup.

*SEARCH/REPLACE* blocks will replace *all* matching occurrences.
Include enough lines to make the SEARCH blocks uniquely match the lines to change.

Keep *SEARCH/REPLACE* blocks concise.
Break large *SEARCH/REPLACE* blocks into a series of smaller blocks that each change a small portion of the file.
Include just the changing lines, and a few surrounding lines if needed for uniqueness.
Do not include long runs of unchanging lines in *SEARCH/REPLACE* blocks.
Reserve empty *SEARCH* blocks for new files.

Only create *SEARCH/REPLACE* blocks for files that the user has added to the chat!

To move code within a file, use 2 *SEARCH/REPLACE* blocks: 1 to delete it from its current location, 1 to insert it in the new location.

Pay attention to which filenames the user wants you to edit, especially if they are asking you to create a new file.

If you want to put code in a new file, use a *SEARCH/REPLACE block* with:
- A new file path, including dir name if needed
- An empty `SEARCH` section
- The new file's contents in the `REPLACE` section

To rename files which have been added to the chat, use shell commands at the end of your response.

ONLY EVER RETURN CODE IN A *SEARCH/REPLACE BLOCK*!]],
          },
          {
            role = "user",
            hide = true,
            content = "Change get_factorial() to use math.factorial",
          },
          {
            role = "assistant",
            hide = true,
            content = [[To make this change we need to modify `mathweb/flask/app.py` to:

1. Import the math package.
2. Remove the existing factorial() function.
3. Update get_factorial() to call math.factorial instead.

Here are the *SEARCH/REPLACE* blocks:


```python file:mathweb/flask/app.py
<<<<<<< SEARCH
from flask import Flask
=======
import math
from flask import Flask
>>>>>>> REPLACE
```

```python file:mathweb/flask/app.py
<<<<<<< SEARCH
def factorial(n):
    "compute factorial"

    if n == 0:
        return 1
    else:
        return n * factorial(n-1)

=======
>>>>>>> REPLACE
```

```python file: mathweb/flask/app.py
<<<<<<< SEARCH
    return str(factorial(n))
=======
    return str(math.factorial(n))
>>>>>>> REPLACE
```]],
          },
          {
            role = "user",
            hide = true,
            content = "Refactor hello() into its own file.",
          },
          {
            role = "assistant",
            hide = true,
            content = [[To make this change we need to modify `main.py` and make a new file `hello.py`:

1. Make a new hello.py file with hello() in it.
2. Remove hello() from main.py and replace it with an import.

Here are the *SEARCH/REPLACE* blocks:

```python file:hello.py
<<<<<<< SEARCH
=======
def hello():
    "print a greeting"

    print("hello")
>>>>>>> REPLACE
```

```python file:main.py
<<<<<<< SEARCH
def hello():
    "print a greeting"

    print("hello")
=======
from hello import hello
>>>>>>> REPLACE
```]],
          },
          require("sia.instructions").current_args(),
        },
      },
    },
  },
  actions = {
    diagnostic = {
      instructions = {
        "split_system",
        {
          role = "user",
          id = function(ctx)
            return { "diagnostics", ctx.buf, ctx.start_line, ctx.end_line }
          end,
          persistent = true,
          description = function(opts)
            return string.format("Diagnostics on line %d to %d", opts.pos[1], opts.pos[2])
          end,
          content = function(opts)
            local start_line, end_line = opts.pos[1], opts.pos[2]
            local diagnostics = require("sia.utils").get_diagnostics(start_line, end_line, { buf = opts.buf })
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
              [[The programming language is %s. The buffer is: %s. This is a list of the diagnostic messages:
%s
]],
              vim.bo[opts.buf].ft,
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
      instructions = {
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
      instructions = {
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
      capture = require("sia.capture").treesitter("@function.outer"),
      mode = "split",
      split = {
        cmd = "vsplit",
      },
      range = true,
      wo = {},
      temperature = 0.5,
    },
    doc = {
      instructions = {
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
      capture = require("sia.capture").treesitter({ "@function.outer", "@class.outer" }),
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

function M.setup(options)
  M.options = vim.tbl_deep_extend("force", {}, defaults, options or {})
end

return M
