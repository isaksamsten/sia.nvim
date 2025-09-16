local diff = require("sia.diff")
local utils = require("sia.utils")
local tracker = require("sia.tracker")
local tool_utils = require("sia.tools.utils")

local CHOICES = {
  "Apply changes immediately",
  "Apply changes immediately and remember this choice",
  "Apply changes and preview them in diff view",
}

return tool_utils.new_tool({
  name = "edit",
  message = "Making code changes...",
  description = [[Edit an existing file by specifying precise changes.

KEY PRINCIPLES:
- Make ALL edits to a file in a single tool call (use multiple edit blocks if needed)
- Only specify lines you`re changing - represent unchanged code with comments

EDIT SYNTAX:
Use "// ... existing code ..." comments to represent unchanged sections:

// ... existing code ...
NEW_OR_MODIFIED_CODE_HERE
// ... existing code ...
ANOTHER_EDIT_HERE
// ... existing code ...

EXAMPLES:

Adding a new function:
```
// ... existing code ...
function newFunction() {
  return "hello";
}
// ... existing code ...
```

Modifying existing code:
```
// ... existing code ...
const updated = "new value";
// ... existing code ...
```

Deleting code (provide context before and after):
```
// ... existing code ...
function keepThis() {}
function alsoKeepThis() {}
// ... existing code ...
```

Multiple changes in one call:
```
// ... existing code ...
FIRST_EDIT
// ... existing code ...
SECOND_EDIT
// ... existing code ...
THIRD_EDIT
// ... existing code ...
```

The apply model will handle multiple distinct edits efficiently in a single operation.]],
  parameters = {
    target_file = {
      type = "string",
      description = "The target file to modify.",
    },
    instructions = {
      type = "string",
      description = [[A single sentence instruction describing what you are
going to do for the sketched edit. This is used to assist the less
intelligent model in applying the edit. Use the first person to describe
what you are going to do. Use it to disambiguate uncertainty in the edit.
      ]],
    },
    code_edit = {
      type = "string",
      description = [[Specify ONLY the precise lines of code that you wish to
edit. NEVER specify or write out unchanged code. Instead, represent all
unchanged code using the comment of the language you`re editing in -
example: // ... existing code ...  ]],
    },
  },
  required = { "target_file", "instructions", "code_edit" },
  auto_apply = function(args, conversation)
    local file = vim.fs.basename(args.target_file)
    if file == "AGENTS.md" then
      return 1
    end
    return conversation.auto_confirm_tools["edit"]
  end,
}, function(args, conversation, callback, opts)
  if not args.target_file then
    callback({ content = { "No target_file was provided" } })
    return
  end

  local buf = utils.ensure_file_is_loaded(args.target_file)
  if not buf then
    callback({ content = { "Cannot load " .. args.target_file } })
    return
  end
  local initial_code = utils.get_code(1, -1, { buf = buf, show_line_numbers = false })

  local assistant = require("sia.assistant")
  assistant.execute_query({
    model = {
      name = "morph/morph-v3-fast",
      function_calling = false,
      provider = require("sia.provider").openrouter,
    },
    prompt = {
      {
        role = "user",
        content = string.format(
          "<instruction>%s</instruction>\n<code>%s</code>\n<update>%s</update>",
          args.instructions,
          initial_code,
          args.code_edit
        ),
      },
    },
  }, function(result)
    if result then
      local split = vim.split(result, "\n", { plain = true, trimempty = true })

      tracker.non_tracked_edit(buf, function()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, split)
        vim.api.nvim_buf_call(buf, function()
          pcall(vim.cmd, "noa silent write!")
        end)
      end)

      opts.user_choice(string.format("Edit %s", args.target_file), {
        choices = CHOICES,
        on_accept = function(choice)
          if choice == 1 or choice == 2 then
            diff.highlight_diff_changes(buf, initial_code)
            if choice == 2 then
              conversation.auto_confirm_tools["edit"] = 1
            end
          elseif choice == 3 then
            diff.show_diff_preview(buf, vim.split(initial_code, "\n", { plain = true, trimempty = true }))
          end

          local file = vim.fs.basename(args.target_file)
          if file == "AGENTS.md" then
            vim.api.nvim_buf_call(buf, function()
              pcall(vim.cmd, "noa silent write!")
            end)
          end

          local diff_output = vim.diff(initial_code, result, {
            result_type = "indices",
            algorithm = "patience",
            linematch = true,
          })

          local all_snippet_lines = {}
          local edit_start, edit_end

          if #diff_output > 0 then
            edit_start = math.huge
            edit_end = 0

            for i, change in ipairs(diff_output) do
              local start_line = change[3]
              local line_count = change[4]
              local range_end = start_line + line_count - 1

              edit_start = math.min(edit_start, start_line)
              edit_end = math.max(edit_end, range_end)

              local new_content_lines = vim.api.nvim_buf_line_count(buf)
              local context_lines = 4
              local start_context = math.max(1, start_line - context_lines)
              local end_context = math.min(new_content_lines, range_end + context_lines)

              local range_snippet = utils.get_content(buf, start_context - 1, end_context)

              if i > 1 then
                table.insert(all_snippet_lines, "")
              end
              table.insert(all_snippet_lines, string.format("Lines %d-%d:", start_context, end_context))

              for _, line in ipairs(range_snippet) do
                table.insert(all_snippet_lines, line)
              end
            end
          else
            callback({
              content = {
                string.format("Agent edit failed for %s - no changes were detected.", args.target_file),
              },
              display_content = {
                string.format("❌ Failed to edit %s", vim.fn.fnamemodify(args.target_file, ":.")),
              },
            })
            return
          end

          local success_msg = string.format(
            "Successfully edited %s. Here are the edited snippets as returned by cat -n:",
            args.target_file
          )
          table.insert(all_snippet_lines, 1, success_msg)

          callback({
            content = all_snippet_lines,
            context = {
              buf = buf,
              pos = { edit_start, edit_end },
              tick = tracker.ensure_tracked(buf),
              outdated_message = string.format(
                "Edited %s on lines %d-%d",
                vim.fn.fnamemodify(args.target_file, ":."),
                edit_start,
                edit_end
              ),
            },
            kind = "edit",
            display_content = {
              string.format(
                "✏️ Edited lines %d-%d in %s",
                edit_start,
                edit_end,
                vim.fn.fnamemodify(args.target_file, ":.")
              ),
            },
          })
        end,
      })
    else
      callback({
        content = { string.format("Failed to edit %s", args.target_file) },
        display_content = {
          string.format("❌ Failed to edit %s", vim.fn.fnamemodify(args.target_file, ":.")),
        },
      })
    end
  end)
end)
