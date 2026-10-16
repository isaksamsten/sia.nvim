local tool_utils = require("sia.tools.utils")
local utils = require("sia.utils")
local diff = require("sia.diff")
local hashline = require("sia.hashline")
local icons = require("sia.ui").icons

return tool_utils.new_tool({
  definition = {
    type = "function",
    name = tool_utils.tool_names.edit,
    description = [[Hashline patches existing files; new files: `write`. Each file: `[PATH#TAG]`, `TAG` required 4-hex snapshot from latest `view` or edit response. Numbers: original `LINE:TEXT`, never hunk-shifted.
Pass `target_file`, `tag`, and `edits` containing operations only (no `[PATH#TAG]` header). One file per call.

<ops>
`PUT N.=M:` replace inclusive N–M with `+` body (`N.=N` for one line).
`PUT <N:`/`PUT >N:` insert before/after N (`<1` head, `>$` tail).
`CUT N.=M` delete and capture, optionally as `@name`.
`PUT <N @name`/`PUT >N @name`/`PUT >$ @name` paste at gap (omit name for anonymous CUT in this call); `PUT N.=M @name` paste over range (name REQUIRED). Register pastes have NO body; named registers persist across calls in this conversation.
</ops>

<rules>
- `:` ops only: body rows `+TEXT` verbatim incl. indent; lone `+` blank. Literal `- item`/`+ item` → `+- item`/`++ item`. NEVER `-`/bare context. Body length independent of range; delete with CUT, not empty PUT.
- Touch displayed changed lines only; `…`, `..`, collapsed `N-M:` and out-of-window lines UNSEEN. Re-read first. Tight ranges: split nonadjacent changes; NEVER include keepers or start/end mid-expression/block. Pure addition uses gap PUT.
- NEVER restyle unrelated code. After EVERY edit tag/numbers change: use edit response or fresh `view`; stale tag/surprise → STOP, re-read.
</rules>

<example>
For `target_file="greet.py"`, `tag="A1B2"`, pass `edits`:
```
PUT 1.=2:
+@cache
+def greet(name):
+    print(name)
```
To insert a comment ABOVE line 7, preserving the existing line, pass `edits`:
```
PUT <7:
+-- Register the hashline edit tool.
```
Cross-file move: `CUT 1.=3 @fn` in source, then `PUT <1 @fn` in a separate destination edit call with its own `view` tag.
</example>]],
    parameters = {
      target_file = { type = "string", description = "File to edit" },
      tag = {
        type = "string",
        description = "Four-hex snapshot tag from the latest view or edit response",
      },
      edits = {
        type = "string",
        description = "PUT/CUT operations using original line numbers",
      },
    },
    required = { "target_file", "tag", "edits" },
  },
  summary = function(args)
    return "Editing " .. (args.target_file or "file") .. " with hashline..."
  end,
  persist_allow = function(args)
    return tool_utils.path_allow_rules("target_file", args.target_file)
  end,
}, function(args, conversation, callback, opts)
  local function fail(message)
    callback({
      content = "Error: " .. message,
      summary = icons.error .. " Failed to edit",
      ephemeral = true,
    })
  end
  if type(args.target_file) ~= "string" or args.target_file == "" then
    return fail("No target_file was provided")
  end
  local path =
    tool_utils.resolve_workspace_path(args.target_file, conversation.workspace)
  if vim.fn.filereadable(path) == 0 then
    return fail("File cannot be found: " .. args.target_file)
  end
  local buf = utils.ensure_file_is_loaded(path, { listed = true })
  if not buf then
    return fail("Cannot load " .. args.target_file)
  end
  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local after, err, commit_clipboard =
    hashline.apply(conversation, path, before, args.tag, args.edits)
  if not after then
    return fail(err)
  end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local disk_before = vim.fn.readfile(path, "b")
  opts.user_input("Edit " .. args.target_file .. " with hashline", {
    preview = function(preview_buf)
      local patch = utils.create_unified_diff(
        table.concat(before, "\n"),
        table.concat(after, "\n"),
        { old_start = 1, new_start = 1 }
      ) or ""
      local preview = vim.split(patch, "\n", { plain = true })
      table.insert(preview, 1, "+++ ai/" .. args.target_file)
      table.insert(preview, 1, "--- orig/" .. args.target_file)
      vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, preview)
      vim.bo[preview_buf].ft = "diff"
      return #preview
    end,
    on_accept = function()
      if
        not vim.api.nvim_buf_is_valid(buf)
        or vim.api.nvim_buf_get_changedtick(buf) ~= tick
      then
        return fail(
          "File changed while awaiting approval. Read it again before editing."
        )
      end
      local disk_ok, disk_now = pcall(vim.fn.readfile, path, "b")
      if not disk_ok or not vim.deep_equal(disk_before, disk_now) then
        return fail(
          "File changed on disk while awaiting approval. Read it again before editing."
        )
      end
      diff.update_baseline(buf, { turn_id = opts.turn_id })
      local ok, write_err = pcall(function()
        conversation.tracker:suppress(buf, function()
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, after)
          vim.api.nvim_buf_call(buf, function()
            vim.cmd("noa silent write!")
          end)
        end)
      end)
      diff.update_reference(buf)
      if not ok then
        return fail(
          "Could not save file (buffer may contain changes): " .. tostring(write_err)
        )
      end
      if commit_clipboard then
        commit_clipboard()
      end
      local current = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local refreshed = hashline.refresh(conversation, path, before, current)
      callback({
        content = "Edited " .. args.target_file .. ":\n" .. table.concat(
          refreshed,
          "\n"
        ),
        summary = icons.edit .. " Edited " .. args.target_file,
        region = {
          buf = buf,
          stale = {
            content = "Previously edited " .. args.target_file,
            input = tool_utils.gen_clear_outdated_tool_input({ "edits" }),
          },
        },
      })
    end,
  })
end)
