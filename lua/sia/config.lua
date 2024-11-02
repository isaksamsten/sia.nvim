local M = {}
local utils = require("sia.utils")
local providers = require("sia.provider")

--- @alias sia.config.Role "user"|"system"|"assistant"|"tool"
--- @alias sia.config.Placement ["below"|"above", "start"|"end"|"cursor"]|"start"|"end"|"cursor"
--- @alias sia.config.ActionInput "require"|"ignore"
--- @alias sia.config.ActionMode "split"|"diff"|"insert"|"hidden"

--- @class sia.config.Insert
--- @field placement (fun():sia.config.Placement)|sia.config.Placement
--- @field cursor ("start"|"end")?

--- @class sia.config.Diff
--- @field wo [string]?
--- @field cmd "vsplit"|"split"?

--- @class sia.config.Split
--- @field cmd "vsplit"|"split"?
--- @field block_action (string|sia.BlockAction)?
--- @field automatic_block_action boolean?
--- @field wo table<string, any>?

--- @class sia.config.Hidden
--- @field callback (fun(ctx:sia.Context, content:string[]):nil)?
--- @field messages { on_start: string?, on_progress: string[]? }?

--- @class sia.config.Replace
--- @field highlight string
--- @field timeout number?

--- @class sia.config.Instruction
--- @field id (fun(ctx:sia.Context?):table?)|nil
--- @field role sia.config.Role
--- @field persistent boolean?
--- @field available (fun(ctx:sia.Context?):boolean)?
--- @field hide boolean?
--- @field description ((fun(ctx:sia.Context?):string)|string)?
--- @field content ((fun(ctx: sia.Context?):string)|string|string[])?
--- @field tool_calls sia.ToolCall[]?
--- @field _tool_call_id string?

--- @class sia.config.Tool
--- @field name string
--- @field description string
--- @field parameters table<string, sia.ToolParameter>
--- @field required string[]?
--- @field execute fun(args:table, strategy: sia.Strategy, callback: fun(content: string[]?)):nil

--- @class sia.config.Action
--- @field instructions (string|sia.config.Instruction|(fun():sia.config.Instruction[]))[]
--- @field reminder (string|sia.config.Instruction)?
--- @field tools sia.config.Tool[]?
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
--- @field hidden sia.config.Hidden?

--- @class sia.config.Defaults
--- @field model string
--- @field temperature number
--- @field actions table<"diff"|"split"|"insert", sia.config.Action>
--- @field split sia.config.Split
--- @field replace sia.config.Replace
--- @field diff sia.config.Diff
--- @field insert sia.config.Insert
--- @field hidden sia.config.Hidden

--- @alias sia.config.Models table<string, [string, string]>

--- @class sia.config.Provider
--- @field base_url string
--- @field api_key fun():string?

--- @class sia.config.Options
--- @field models sia.config.Models
--- @field instructions table<string, sia.config.Instruction|sia.config.Instruction[]>
--- @field defaults sia.config.Defaults
--- @field actions table<string, sia.config.Action>
--- @field providers table<string, sia.config.Provider>
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
    ["chatgpt-4o-latest"] = { "openai", "chatgpt-4o-latest" },
    copilot = { "copilot", "gpt-4o" },
  },
  instructions = {
    editblock_reminder = {
      role = "system",
      content = [[# *SEARCH/REPLACE block* Rules:

Every *SEARCH/REPLACE block* must use this format:
1. The opening fence, code language and the *FULL* file path alone on a line prefixed with file:, verbatim. No bold asterisks, no quotes around it, no escaping of characters, etc., eg: ```python file:test.py
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
**Include enough lines to make the SEARCH blocks uniquely match the lines to change.**

Keep *SEARCH/REPLACE* blocks concise.
Break large *SEARCH/REPLACE* blocks into a series of smaller blocks that each change a small portion of the file.
Include just the changing lines, AND a few surrounding lines to ensure UNIQUE MATCHES.
Do not include long runs of unchanging lines in *SEARCH/REPLACE* blocks.

Only create *SEARCH/REPLACE* blocks for files that the user has added to the chat!

To move code within a file, use 2 *SEARCH/REPLACE* blocks: 1 to delete it from its current location, 1 to insert it in the new location.

Pay attention to which filenames the user wants you to edit. If the file is not
listed, do not edit it, instead use the function `add_file` to add it to the conversation.

If you want to put code in a new file, use a *SEARCH/REPLACE block* with:
- A new file path, including dir name if needed
- An empty `SEARCH` section
- The new file's contents in the `REPLACE` section

You are diligent and tireless!
You NEVER leave comments describing code without implementing it!
You always COMPLETELY IMPLEMENT the needed code!

ONLY EVER RETURN CODE IN A *SEARCH/REPLACE BLOCK*!]],
    },
    editblock_system = {
      {
        role = "system",
        content = [[Act as an expert software developer. Always use best practices when coding.
Respect and use existing conventions, libraries, etc that are already present in the code base.

You are diligent and tireless!
You NEVER leave comments describing code without implementing it!
You always COMPLETELY IMPLEMENT the needed code!

Take requests for changes to the supplied code.
If the request is ambiguous, ask questions.

Always reply to the user in the same language they are using.

Once you understand the request you MUST:

1. Think step-by-step and explain the needed changes in a few short sentences.

2. Describe each change with a *SEARCH/REPLACE block* per the examples below.

3. If you are unsure what the user wants, ask for clarification before making changes.

4. You have access to the following functions:
  - `add_file` to add files matching a glob pattern to the conversation.

All changes to files must use this *SEARCH/REPLACE block* format.]],
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
      {
        role = "user",
        hide = true,
        content = "I switched to a new code base. Please don't consider the above files or try to edit them any longer.",
      },
      {
        role = "assistant",
        hide = true,
        content = "Understood. I will no longer consider the above files for editing.",
      },
    },
    git_files = {
      {
        role = "user",
        persistent = true,
        description = "List the files in the current git repository.",
        available = function()
          return utils.is_git_repo()
        end,
        content = function(ctx)
          return string.format(
            "This is the current directory hierarchy:\n:%s",
            vim.fn.system("git ls-tree -r --name-only HEAD")
          )
        end,
      },
      {
        role = "assistant",
        hide = true,
        content = "Thanks for providing the list of files in the current git repository.",
      },
    },
    current_buffer_line_number = require("sia.instructions").current_buffer({ show_line_numbers = true }),
    current_buffer = require("sia.instructions").current_buffer({ show_line_numbers = false }),
    current_context_line_number = require("sia.instructions").current_context({ show_line_numbers = true }),
    current_context = require("sia.instructions").current_context({ show_line_numbers = false }),
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
    -- model = "gpt-4o-mini", -- default model
    model = "copilot", -- default
    temperature = 0.3, -- default temperature
    prefix = 1, -- prefix lines in insert
    suffix = 0, -- suffix lines in insert
    split = {
      cmd = "vsplit",
      wo = { wrap = true },
      block_action = "verbatim",
      automatic_block_action = false,
    },
    hidden = {
      messages = {},
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
        temperature = 0.2,
        instructions = {
          "diff_system",
          require("sia.instructions").current_buffer({ fences = false }),
          require("sia.instructions").current_context({ fences = false }),
        },
      },
      --- @type sia.config.Action
      split = {
        mode = "split",
        temperature = 0.1,
        split = {
          block_action = "search_replace",
          automatic_block_action = true,
        },
        tools = {
          require("sia.tools").add_file,
        },
        model = "gpt-4o",
        instructions = {
          "editblock_system",
          "git_files",
          require("sia.instructions").files,
          "current_context",
        },
        reminder = "editblock_reminder",
      },
    },
  },
  actions = {
    diagnostic = {
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
        return utils.is_git_repo(true)
      end,
      insert = { placement = "cursor" },
    },
    review = {
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
                filname = vim.api.nvim_buf_get_name(ctx.buf),
                lnum = tonumber(start_line),
                end_lnum = tonumber(end_line),
                col = 0,
                end_col = -1,
                text = message,
                type = "I",
              })
            end
          end
          vim.fn.setqflist(list, "r")
          vim.cmd.copen()
        end,
      },
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
  5. Provide context on how the code fits into a larger application if applicable.

If you need additional context to improve the explanation. Ask the user to add
the file to the context using SiaFile.
  ]],
        },
        "git_files",
        require("sia.instructions").files(),
        "current_context_line_number",
      },
      mode = "split",
      temperature = 0.5,
      range = true,
    },
    unittest = {
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
      temperature = 0.5,
    },
    doc = {
      instructions = {
        "insert_system",
        {
          role = "system",
          content = [[You are tasked with writing documentation for functions, methods, and classes. Your documentation must adhere to the language conventions (e.g., JSDoc for JavaScript, docstrings for Python, Javadoc for Java), including appropriate tags and formatting.

Requirements:

1. **Language-Specific Conventions**: Follow the language-specific documentation style strictly (e.g., use /** ... */ for JavaScript, """ ... """ for Python). Ensure all tags are accurate and appropriate for the language.
2. No Code Output: Only output the documentation text; never output the function declaration, implementation, or any code examples, including function signatures or suggested implementations.
3. **Formatting and Sections**:
  *	Provide a clear and concise description of the function’s purpose.
  *	Use appropriate tags (e.g., @param, @return) to describe parameters and return values.
  *	Maintain strict adherence to formatting conventions for each language.
4. **Strict Indentation Rules**:
  *	The documentation must be indented to match the level of the provided context.
  *	Always ensure the indentation aligns with the surrounding code, allowing the documentation to be copied directly into the code without requiring reformatting.
  *	Failure to produce correctly indented output is considered an error.
5. **No Markdown or Fences**:
  *	Do not include markdown code fences or other wrappers surrounding the documentation.
6. **Class/Struct Documentation**:
  *	If the user provides a class or struct, only document the class/struct itself, not its methods or functions. Any deviation is considered incorrect.
7. **Compliance and Double-Check**:
  *	Double-check that your response adheres strictly to the language’s documentation style, contains only the requested documentation text, and maintains proper indentation for easy insertion into code. ]],
        },
        "current_context",
      },
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
}

function M.setup(options)
  M.options = vim.tbl_deep_extend("force", {}, defaults, options or {})
end

return M
