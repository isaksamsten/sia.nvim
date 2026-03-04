# Reviewing Changes

If Sia uses the edit tools (insert, write, or edit), it will maintain a diff
state for the buffer in which the changes are inserted. The diff state
maintains two states: the **baseline** (your edits) and the **reference** (Sia's changes). Once you accept a
change, it will be incorporated into baseline and if the change is rejected
it will be removed from reference. This means that you and Sia can make
concurrent changes while you can always opt to reject changes made by Sia.

**NOTE**: If you edit text that overlaps with a pending Sia change, the diff
system considers the entire change as **accepted** and incorporates it into
baseline automatically.

## Example Workflow

1. **Sia makes changes**: After asking Sia to refactor a function, you'll see
   highlighted changes in your buffer
2. **Navigate changes**: Use `]c` and `[c` to jump between individual changes
3. **Review each change**: Position your cursor on a change and decide whether
   to keep it
4. **Accept or reject**:
   - `SiaAccept` to accept the change under cursor
   - `SiaReject` to reject the change under cursor
   - `SiaAccept!` to accept all changes at once
   - `SiaReject!` to reject all changes at once
5. **Continue editing**: You can make your own edits while Sia's changes are
   still pending

## Live Example

https://github.com/user-attachments/assets/4d115f32-1abb-4cf8-9797-c84d918b65ac

In the following screencast, we see a complete workflow example:

1. **Initial file creation**: We ask Sia to write a small script, and Sia uses
   the `write` tool to create `test.py`
2. **External formatting**: When the file is saved, `ruff format` automatically
   formats it, which modifies the file and moves most changes from **reference**
   into **baseline** (accepting them)
3. **Targeted edits**: We ask Sia to change the dataset from iris to another
   dataset, and Sia uses the `edit` tool to make several targeted changes
4. **Change visualization**: Each change is inserted into **reference** and
   highlighted with both line-level and word-level highlights
5. **Manual review**: We start reviewing changes using `[c` and `]c` to move
   between changes and `ga` (accept) and make our own edits (removing comments)
6. **Concurrent editing behavior**:
   - When removing comments that don't affect Sia's changes, they remain
     highlighted in **reference**
   - When removing a comment that overlaps with a **reference** change, it's
     automatically accepted and moved to **baseline**
7. **Bulk operations**: Finally, we show all remaining changes in a quickfix
   window and use `cdo norm ga` to accept all changes at once

## Rolling Back Changes

If the assistant's changes aren't what you wanted, you can roll back an entire
turn (a user query and the assistant's response) using `SiaRollback`. This
reverts both the conversation history and all file edits made during that turn.

Each user/assistant exchange is assigned a **turn ID**. When you run
`:SiaRollback [turn_id]`, Sia will:

1. Remove all conversation messages from that turn onward
2. Revert all file changes introduced during that turn (restoring buffers to
   their state before the turn)
3. Preserve any changes you have already **accepted** — only pending
   (unreviewed) edits from the rolled-back turns are reverted

The command supports tab-completion, so you can press `<Tab>` after
`:SiaRollback` to see available turn IDs. If no turn ID is provided, it rolls
back the most recent turn.

This is useful when the assistant takes a wrong approach and you want to try a
different prompt without manually rejecting individual changes.

