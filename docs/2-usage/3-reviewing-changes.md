# Reviewing Changes

When Sia uses edit tools (insert, write, or edit), it maintains inline diff
state for the affected buffers. The diff system tracks two states: the
**baseline** (your edits) and the **reference** (Sia's changes). When you
accept a change, it moves into the baseline. When you reject a change, it is
removed from the reference. You and Sia can make concurrent edits while you
retain full control over what to keep.

If you edit text that overlaps with a pending Sia change, the diff system
considers that change **accepted** and incorporates it into the baseline
automatically.

## Workflow

1. **Sia makes changes**: After asking Sia to refactor a function, highlighted
   changes appear in your buffer.
2. **Navigate changes**: Use `]c` and `[c` to jump between changes.
3. **Review each change**: Position your cursor on a change.
4. **Accept or reject**:
   - `:SiaAccept` (or `ga`) to accept the change under the cursor
   - `:SiaReject` (or `gx`) to reject the change under the cursor
   - `:SiaAccept!` to accept all changes at once
   - `:SiaReject!` to reject all changes at once
5. **Continue editing**: You can make your own edits while Sia's changes are
   still pending.

## Example

https://github.com/user-attachments/assets/4d115f32-1abb-4cf8-9797-c84d918b65ac

In this screencast:

1. We ask Sia to write a small script. Sia uses the `write` tool to create
   `test.py`.
2. When the file is saved, `ruff format` automatically formats it, which moves
   most changes from reference into baseline (accepting them).
3. We ask Sia to change the dataset, and Sia uses the `edit` tool for targeted
   changes.
4. Each change is highlighted with line-level and character-level markers.
5. We review changes using `[c`/`]c` to navigate and `ga` to accept.
6. When removing comments that don't overlap with Sia's changes, those changes
   remain highlighted. When a removal overlaps with a reference change, it is
   automatically accepted.
7. We show remaining changes in a quickfix window and use `cdo norm ga` to
   accept them all.

## Rolling Back Changes

If the assistant's changes are not what you wanted, you can roll back an entire
turn using `:SiaRollback`. This reverts both the conversation history and all
file edits made during that turn.

Each user/assistant exchange has a **turn ID**. When you run
`:SiaRollback [turn_id]`, Sia:

1. Removes all conversation messages from that turn onward
2. Reverts all file changes introduced during that turn
3. Preserves any changes you have already accepted

The command supports tab-completion. Press `<Tab>` after `:SiaRollback` to see
available turn IDs. If you omit the turn ID, it rolls back the most recent
turn.

