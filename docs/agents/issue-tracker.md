# Issue tracker: Local Markdown

Issues and PRDs for this repository live as Markdown files in `.scratch/`.

## Conventions

- One feature per directory: `.scratch/<feature-slug>/`.
- The PRD is `.scratch/<feature-slug>/PRD.md`.
- Implementation issues are
  `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01`.
- Triage state is recorded as a `Status:` line near the top of each issue file.
  See `triage-labels.md` for the allowed role strings.
- Comments and conversation history are appended under a `## Comments`
  heading at the bottom of the file.

## Publishing to the issue tracker

Create a new file under `.scratch/<feature-slug>/`, creating the directory when
needed.

## Fetching a ticket

Read the referenced Markdown file. The user will normally provide its path or
issue number directly.
