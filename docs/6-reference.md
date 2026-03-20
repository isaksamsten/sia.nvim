# Reference

## Highlight Groups

Sia defines highlight groups that you can customize. They are only set if they
don't already exist, so defining them in your colorscheme or config takes
precedence.

### Change Review

| Group                 | Default Link           | Description               |
| --------------------- | ---------------------- | ------------------------- |
| `SiaDiffAdd`          | `DiffAdd`              | Added lines               |
| `SiaDiffChange`       | `DiffChange`           | Changed lines             |
| `SiaDiffDelete`       | `DiffDelete`           | Deleted lines             |
| `SiaDiffInlineAdd`    | `GitSignsAddInline`    | Character-level additions |
| `SiaDiffInlineChange` | `GitSignsChangeInline` | Character-level changes   |
| `SiaDiffAddSign`      | `GitSignsAdd`          | Sign column for additions |
| `SiaDiffChangeSign`   | `GitSignsChange`       | Sign column for changes   |

### Chat UI

| Group           | Default Link | Description               |
| --------------- | ------------ | ------------------------- |
| `SiaAssistant`  | `DiffAdd`    | Assistant message markers |
| `SiaUser`       | `DiffChange` | User message markers      |
| `SiaToolResult` | `DiffChange` | Tool result markers       |
| `SiaProgress`   | `NonText`    | Progress indicators       |
| `SiaModel`      | —            | Model name display        |
| `SiaUsage`      | —            | Token usage display       |
| `SiaStatus`     | —            | Status display            |

### Tool Approval

| Group            | Default Link | Description             |
| ---------------- | ------------ | ----------------------- |
| `SiaApproveInfo` | `StatusLine` | Standard risk level     |
| `SiaApproveSafe` | `StatusLine` | Safe/low risk level     |
| `SiaApproveWarn` | `StatusLine` | Warning/high risk level |

### Insert and Diff Mode

| Group                  | Default Link | Description                |
| ---------------------- | ------------ | -------------------------- |
| `SiaInsert`            | `DiffAdd`    | Inserted text              |
| `SiaInsertPostProcess` | `DiffChange` | Post-processed text        |
| `SiaReplace`           | `DiffChange` | Replaced text in diff mode |

### Todos and Status

| Group               | Default Link      | Description           |
| ------------------- | ----------------- | --------------------- |
| `SiaTodoActive`     | `DiagnosticWarn`  | Active todo items     |
| `SiaTodoPending`    | `Comment`         | Pending todo items    |
| `SiaTodoDone`       | `DiagnosticOk`    | Completed todo items  |
| `SiaTodoSkipped`    | `NonText`         | Skipped todo items    |
| `SiaStatusActive`   | `DiagnosticHint`  | Running agent tasks   |
| `SiaAgentCompleted` | `DiagnosticOk`    | Completed agent tasks |
| `SiaAgentFailed`    | `DiagnosticError` | Failed agent tasks    |

### Other

| Group     | Default Link     | Description    |
| --------- | ---------------- | -------------- |
| `SiaMode` | `DiagnosticInfo` | Mode indicator |
