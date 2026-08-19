# Issue tracker: Local Markdown

Issues and PRDs for this repository live as Markdown files in `.scratch/`.
`.scratch/` is a gitignored local mechanism (by design); it is not a
cross-machine collaboration surface.

## Conventions

- One feature per directory: `.scratch/<feature-slug>/`.
- The PRD is `.scratch/<feature-slug>/PRD.md`.
- Implementation issues are
  `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01`.
- Triage state is recorded as a `Status:` line near the top of each issue file,
  using the labels below.
- Comments and conversation history are appended under a `## Comments`
  heading at the bottom of the file.

## Publishing to the issue tracker

Create a new file under `.scratch/<feature-slug>/`, creating the directory when
needed.

## Fetching a ticket

Read the referenced Markdown file. The user will normally provide its path or
issue number directly.

## Triage labels

Engineering skills use five canonical triage roles. Local issue files record
the corresponding string in their `Status:` line. When a skill names a
canonical role, use the matching local status from this table.

| Canonical role | Local status | Meaning |
|---|---|---|
| `needs-triage` | `needs-triage` | A maintainer needs to evaluate the issue |
| `needs-info` | `needs-info` | Waiting for more information from the reporter |
| `ready-for-agent` | `ready-for-agent` | Fully specified and ready for an AFK agent |
| `ready-for-human` | `ready-for-human` | Requires human implementation |
| `wontfix` | `wontfix` | Will not be actioned |
