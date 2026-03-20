# Permission Rules

The permission system gives you fine-grained control over which tool operations
are allowed, denied, or require confirmation. Configure permissions in your
[project config](../3-configuration/3-project.md) under the `permission` key.

## Rule Precedence

Rules are evaluated in this order:

1. **Deny** — blocks the operation immediately
2. **Ask** — requires user confirmation
3. **Allow** — auto-approves the operation

## Rule Structure

Each rule targets a specific tool and matches against its arguments using
patterns:

```json
{
  "permission": {
    "allow": {
      "tool_name": {
        "arguments": {
          "parameter_name": ["pattern1", "pattern2"]
        }
      }
    }
  }
}
```

- **arguments** (required) — maps parameter names to arrays of patterns
- **choice** (allow rules only) — auto-selection index for multi-choice
  prompts (default: 1)
- Allow rules can be a single object or an array of rule objects

## Pattern Format

Patterns use Vim regex syntax with very magic mode (`\v`):

- Multiple patterns in an array are OR'd: if any pattern matches, the
  argument matches
- All configured argument patterns must match for the rule to apply
- Non-configured argument patterns always match
- `nil` argument values are treated as empty strings
- Non-string arguments are converted with `tostring()`

See `:help vim.regex()` for full syntax.

## Examples

Auto-approve safe git commands:

```json
{
  "permission": {
    "allow": {
      "bash": {
        "arguments": {
          "command": ["^git status$", "^git diff", "^git log"]
        }
      }
    }
  }
}
```

Restrict file edits to source code:

```json
{
  "permission": {
    "allow": {
      "edit": {
        "arguments": {
          "target_file": ["src/.*\\.(js|ts|py)$"]
        }
      }
    },
    "deny": {
      "remove_file": {
        "arguments": {
          "path": [".*\\.(config|env)"]
        }
      }
    }
  }
}
```

Multiple allow rules for the same tool (using array syntax):

```json
{
  "permission": {
    "allow": {
      "view": [
        {
          "arguments": {
            "path": ["^lua/sia/[^/]+\\.lua$"]
          }
        },
        {
          "arguments": {
            "path": ["^tests/[^/]+\\.lua$"]
          }
        }
      ]
    }
  }
}
```

Block dangerous commands while allowing safe ones:

```json
{
  "permission": {
    "allow": {
      "bash": {
        "arguments": {
          "command": ["^git status$", "^git diff", "^ls"]
        }
      }
    },
    "deny": {
      "bash": {
        "arguments": {
          "command": ["rm -rf", "sudo"]
        }
      }
    }
  }
}
```

## Risk Levels

The risk level system provides visual feedback on tool operations in the async
confirmation UI. Unlike permissions (which control whether operations need
confirmation), risk levels mark operations as safe, informational, or risky for
display purposes.

### Levels

| Level  | Description                   | Highlight group  |
| ------ | ----------------------------- | ---------------- |
| `safe` | Low-risk operations           | `SiaApproveSafe` |
| `info` | Standard operations (default) | `SiaApproveInfo` |
| `warn` | High-risk operations          | `SiaApproveWarn` |

### How It Works

- Each tool has a default risk level (usually `info`)
- Your config can escalate or de-escalate operations based on patterns
- When multiple patterns match, the highest risk level wins

### Configuration

```json
{
  "risk": {
    "tool_name": {
      "arguments": {
        "parameter_name": [
          { "pattern": "vim_regex_pattern", "level": "safe|info|warn" }
        ]
      }
    }
  }
}
```

### Examples

Mark safe shell commands:

```json
{
  "risk": {
    "bash": {
      "arguments": {
        "command": [
          { "pattern": "^ls", "level": "safe" },
          { "pattern": "^cat", "level": "safe" },
          { "pattern": "^echo", "level": "safe" },
          { "pattern": "^git status", "level": "safe" },
          { "pattern": "^git diff", "level": "safe" }
        ]
      }
    }
  }
}
```

Highlight dangerous operations:

```json
{
  "risk": {
    "bash": {
      "arguments": {
        "command": [{ "pattern": "\\brm\\b", "level": "warn" }]
      }
    },
    "remove_file": {
      "arguments": {
        "path": [{ "pattern": "\\.(env|config)$", "level": "warn" }]
      }
    }
  }
}
```
