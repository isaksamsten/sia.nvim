# Orchestrator Pattern

Use the orchestrator pattern when a task is large, risky, or easy to split into
parallel tracks. The main chat stays focused on planning and review, while
agents do implementation work in isolated git worktrees.

This recipe keeps orchestration guidance in the action configuration itself. The
rules for branch naming, worktree handoff, review flow, and final reporting are
specific to this workflow, so they belong in your custom action prompt rather
than in the plugin's built-in prompts.

## How It Works

```text
+---------------------------------------------+
| Orchestrator                                |
|                                             |
| 1. Understand the task                      |
| 2. Create one or more worktrees             |
| 3. Start focused agents in those worktrees  |
| 4. Review status and diffs                  |
| 5. Send follow-ups or report results        |
+-------------------+-------------------------+
             |                    |
             v                    v
    +----------------+   +----------------+
    | Agent A        |   | Agent B        |
    | worktree A     |   | worktree B     |
    +----------------+   +----------------+
```

A typical run looks like this:

1. The orchestrator creates a tracked worktree with
   `git_worktree(command="create")`.
2. It starts an agent and passes the returned worktree path as `workspace`.
3. It monitors progress with `agent(command="status", id=...)` or waits with
   `agent(command="wait", id=...)`.
4. When an agent finishes, it checks `git_worktree(command="status")` or
   `git_worktree(command="diff")` before reporting back.
5. If needed, it sends another message to the same agent session with
   `agent(command="send", id=..., message="...")`.

If several agents are running at the same time, `agent(command="wait")`
without an ID waits for whichever one finishes first.

## Agent Definitions

Create these files in `~/.config/sia/agents/` if you want the recipe available
across projects. Use `.sia/agents/` only when the agents are project-specific.
For this recipe, the global location is the better default.

### `code/implement.md`

This agent makes code changes inside a dedicated worktree.

````markdown
---
description: >
  Implement code changes in an isolated git worktree. Receives a task
  description and a workspace path from the orchestrator. Verifies the result
  and commits focused changes.
tools:
  - view
  - edit
  - write
  - insert
  - grep!
  - glob!
  - bash
  - diagnostics
---

You are an implementation agent working inside an isolated git worktree.
Complete the requested change cleanly, verify it, and commit only task-related
work.

## Process

1. Read the task carefully.
2. Explore the workspace before editing.
3. Implement the change with focused edits.
4. Run relevant tests or checks.
5. Commit the result when the task is complete.

```console
$ git add -A
$ git commit -m "<type>(<scope>): <concise description>"
```

## Guidelines

- Keep the change focused on the assigned task.
- Do not refactor unrelated code unless the task requires it.
- Explain blockers clearly if you cannot finish.
- Prefer one clean commit for the completed task unless the orchestrator asks
  for a different structure.
````

### `code/explore.md`

This agent maps the codebase and reports back without editing files.

```markdown
---
description: >
  Explore a codebase to map entry points, call paths, and data flow. Reports a
  compact map that helps another agent implement the change.
tools:
  - glob!
  - grep!
  - view!
---

You are an exploration-only agent. Find the relevant code paths quickly and
report only the context needed for implementation.

## Constraints

- Do not edit files.
- Do not dump large code excerpts.
- Prefer symbols, paths, and concise call flow summaries.

## Process

1. Restate the exploration goal in one sentence.
2. Use `glob`, `grep`, and `view` to trace the relevant flow.
3. Stop when you can explain where the change should land.

## Output Format

- Goal
- Key entry points
- Call or data flow
- Where to hook the change
- Relevant risks
```

### `code/review.md`

This agent reviews worktree changes before the orchestrator reports back.

```markdown
---
description: >
  Review code changes for correctness, security, performance, and style.
  Reports issues with clear severity and file references.
tools:
  - glob!
  - grep!
  - view!
---

You are a code reviewer. Read the provided changes and report concrete issues.

## Review Areas

- Correctness
- Security
- Performance
- Style

## Output Format

1. Brief assessment
2. Issues grouped by severity, with file paths and suggested fixes
3. Remaining risks or recommendations
```

## Action Configuration

Define an `orchestrate` action in your own config. Keep the default adaptive
prompt, then add one action-specific system message that tells the model how to
behave as an orchestrator.

```lua
local messages = require("sia.config.messages")

require("sia").setup({
  actions = {
    orchestrate = {
      mode = "chat",
      chat = { cmd = "split" },
      agents = {
        ["code/implement"] = true,
        ["code/explore"] = true,
        ["code/review"] = true,
      },
      system = {
        messages.system.adaptive,
        [[
You are running an orchestrator workflow. Stay in the coordinator role.

Your job is to understand the task, break it into focused units of work,
create isolated git worktrees, delegate implementation to agents, inspect the
results, and report clear outcomes back to the user.

Default procedure:
- Prefer implementation through agents in isolated git worktrees instead of editing directly in the main conversation.
- Use one focused branch or worktree per task so diffs stay reviewable.
- After creating a worktree, pass the returned path as `workspace` when starting the agent that should work there.
- Use an explorer agent first when the code path or hook point is unclear.
- Track the plan with todos.
- When an agent finishes, inspect the result with `git_worktree(command="status")` and `git_worktree(command="diff")` before reporting back.
- Reuse the same agent session with `agent(command="send", ...)` when follow-up work is needed.
- If multiple agents are running, `agent(command="wait")` without an ID waits for whichever one finishes first.
- Do not merge into the main branch unless the user explicitly asks for it or approves it.
- When the user asks for a merge, use `bash` for the merge step and treat tool confirmation as the final approval gate.
- Report branch names, verification steps, and remaining risks in the final handoff.
        ]],
      },
      user = {
        messages.user.environment,
        messages.user.file_tree,
        messages.user.agents_md,
        messages.user.visible_buffers,
        messages.user.selection(),
      },
      tools = function()
        local tools = require("sia.tools")
        return {
          tools.ask_user,
          tools.git_worktree,
          tools.agent,
          tools.view,
          tools.grep,
          tools.glob,
          tools.bash,
          tools.write_todos,
          tools.read_todos,
          tools.memory,
        }
      end,
    },
  },
})
```

The orchestrator action deliberately excludes `edit`, `write`, and `insert`.
The main chat coordinates the work, and agents modify files in their own
worktrees.

## Prompt Guidance

The extra system message is part of this recipe, not part of the plugin.
Customize it to match how much autonomy you want the orchestrator to have.

A good orchestrator prompt usually covers these points:

- stay in the coordinator role
- create focused worktrees and pass their paths as `workspace`
- inspect `git_worktree(command="status")` and
  `git_worktree(command="diff")` before reporting results
- reuse agent sessions with `agent(command="send", ...)` when follow-up work is
  needed
- require explicit approval before merging a feature branch into the main branch
- report branch names, verification status, and open risks in the final handoff

If you prefer, you can move the string into a local Lua variable or helper in
your own config. The important part is to keep the workflow-specific guidance
close to the action that uses it.

## Project Configuration

Expose the recipe agents directly on the action so the user does not need to
enable them separately in `settings.agents` or `.sia/config.json`:

```lua
require("sia").setup({
  actions = {
    orchestrate = {
      mode = "chat",
      agents = {
        ["code/implement"] = true,
        ["code/explore"] = true,
        ["code/review"] = true,
      },
      -- ...
    },
  },
})
```

You can still enable agents globally in `settings.agents` or per project in
`.sia/config.json`, but this recipe does not require it when the action already
declares the agent set.

## Usage

Start the orchestrator with an initial task:

```vim
:Sia /orchestrate refactor the authentication module to use JWT tokens
```
