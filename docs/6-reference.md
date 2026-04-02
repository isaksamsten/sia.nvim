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

| Group                    | Default Link  | Description                      |
| ------------------------ | ------------- | -------------------------------- |
| `SiaApproveInfo`         | `StatusLine`  | Standard risk level              |
| `SiaApproveSafe`         | `StatusLine`  | Safe/low risk level              |
| `SiaApproveWarn`         | `StatusLine`  | Warning/high risk level          |
| `SiaConfirm`             | `NormalFloat` | Confirm detail window background |
| `SiaConfirmItem`         | `NonText`     | Unselected item in confirm view  |
| `SiaConfirmSelectedItem` | `Normal`      | Selected item in confirm view    |

### Insert and Diff Mode

| Group                  | Default Link | Description                |
| ---------------------- | ------------ | -------------------------- |
| `SiaInsert`            | `DiffAdd`    | Inserted text              |
| `SiaInsertPostProcess` | `DiffChange` | Post-processed text        |
| `SiaReplace`           | `DiffChange` | Replaced text in diff mode |

### Todos

| Group            | Default Link     | Description          |
| ---------------- | ---------------- | -------------------- |
| `SiaTodoActive`  | `DiagnosticWarn` | Active todo items    |
| `SiaTodoPending` | `Comment`        | Pending todo items   |
| `SiaTodoDone`    | `DiagnosticOk`   | Completed todo items |
| `SiaTodoSkipped` | `NonText`        | Skipped todo items   |

### Status Panel

| Group             | Default Link      | Description                    |
| ----------------- | ----------------- | ------------------------------ |
| `SiaStatusActive` | `DiagnosticHint`  | Running agents and processes   |
| `SiaStatusDone`   | `DiagnosticOk`    | Completed agents and processes |
| `SiaStatusFailed` | `DiagnosticError` | Failed agents and processes    |
| `SiaStatusTag`    | `Type`            | Status tags                    |
| `SiaStatusMuted`  | `NonText`         | Muted/secondary text           |
| `SiaStatusLabel`  | `Identifier`      | Detail labels                  |
| `SiaStatusValue`  | `Normal`          | Detail values                  |
| `SiaStatusPath`   | `Directory`       | File path values               |
| `SiaStatusCode`   | `String`          | Code/command values            |

### Other

| Group     | Default Link     | Description    |
| --------- | ---------------- | -------------- |
| `SiaMode` | `DiagnosticInfo` | Mode indicator |
