--- Builtin instructions.
--- We can use these as string-names for instructions when building actions.
--- Users can provide their own in `instructions` in the config.
local M = {
  watch_user_assist = {
    hide = true,
    role = "user",
    content = [[
I've written your instructions in comments in the code and marked them with "Sia"
You can see the "Sia" comments shown below (marked with █).
Find them in the code files I've shared with you, and follow their instructions.

Instructions:
 - Marked lines ending with Sia! corresponds to instructions
 - Marked lines ending with only Sia corresponds to additional context that can
 be used complete the instruction.
 - **IMPORTANT** After completing those instructions, also be sure to remove all the "Sia"
 comments from the code too.
]],
  },
  watch_user_question = {
    hide = true,
    role = "user",
    content = [[Act as an expert code analyst.
Answer questions about the supplied code.

Describe code changes however you like. Don't use SEARCH/REPLACE blocks!

Find the "Sia" comments below (marked with █) in the code files I've shared with you.
They contain my questions that I need you to answer and other instructions for you.


Instructions:
 - Marked lines ending with Sia? corresponds to questions
 - Marked lines ending with only Sia corresponds to additional context that can
 be used to answer the questions.

]],
  },

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
listed, do not edit it.

If you want to put code in a new file, use a *SEARCH/REPLACE block* with:
- A new file path, including dir name if needed
- An empty `SEARCH` section
- The new file's contents in the `REPLACE` section

You are diligent and tireless!
You NEVER leave comments describing code without implementing it!
You always COMPLETELY IMPLEMENT the needed code! ]],
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

4. If the user DO NOT ASK FOR CHANGES just output the answer and do not use SEARCH/REPLACE blocks.

All (BUT *ONLY*) changes to files must use this *SEARCH/REPLACE block* format.]],
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
        return require("sia.utils").is_git_repo()
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

1. Make sure that you only output the relevant and requested information.
2. Refrain from explaining your reasoning, unless the user requests it. Never add unrelated text to the output.
3. If the context pertains to code, identify the programming language and do not add any additional text or markdown formatting.
4. If explanations are needed, add them as relevant comments using the correct syntax for the identified language.
5. Do not include markdown code fences or other wrappers surrounding the
   code!
5. **Always preserve** indentation for code.
6. Never include the full provided context in your response. Only output the relevant requested information.]],
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
  diagnostics = {
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
          require("sia.utils").get_filename(opts.buf)
        )
      end,
      content = function(opts)
        local utils = require("sia.utils")
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
    {
      role = "assistant",
      content = "Ok",
      persistent = true,
      id = function(ctx)
        return { "diagnostics_assistant", ctx.buf, ctx.pos[1], ctx.pos[2] }
      end,
    },
  },
}

return M
