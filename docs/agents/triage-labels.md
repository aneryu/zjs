# Triage labels

Engineering skills use five canonical triage roles. Local issue files record
the corresponding string in their `Status:` line.

| Canonical role | Local status | Meaning |
|---|---|---|
| `needs-triage` | `needs-triage` | A maintainer needs to evaluate the issue |
| `needs-info` | `needs-info` | Waiting for more information from the reporter |
| `ready-for-agent` | `ready-for-agent` | Fully specified and ready for an AFK agent |
| `ready-for-human` | `ready-for-human` | Requires human implementation |
| `wontfix` | `wontfix` | Will not be actioned |

When a skill names a canonical role, use the matching local status from this
table.
