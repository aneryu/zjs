# EAL-YYYYMMDD-NNN: Short Title

Status: open
Severity: medium
Phase: phase-number-and-name
Classification: quickjs_parity_gap
Created: YYYY-MM-DD
Last updated: YYYY-MM-DD

## Summary

One or two sentences describing the failure and why it matters.

## Symptom

- Command:

```bash
command goes here
```

- Exit status:
- Observed output summary:
- First known bad commit or work slice:
- Affected matrix rows:

## Expected Behavior

Describe local QuickJS behavior or the planned invariant. Include the exact
QuickJS command or source function when applicable.

## Actual Behavior

Describe Zig behavior and how it differs.

## Reproduction

Minimal command or fixture needed to reproduce the failure.

```bash
command goes here
```

## QuickJS Source Owner

- Source files:
- Source functions or tables:
- Notes:

## Zig Owner

- Files:
- Functions or types:
- Related phase:

## Root Cause

Write the actual cause after investigation. Do not guess; mark as unknown while
investigation is still active.

## Fix Plan

- [ ] Implementation change:
- [ ] Regression test:
- [ ] Matrix row update:
- [ ] Tracking update:

## Validation Evidence

| Date | Command | Exit | Result |
|---|---|---|---|
| YYYY-MM-DD | `command` | n/a | not run |

## Learning

Reusable rule or warning that should influence future work.

## Closure Checklist

- [ ] Root cause is documented.
- [ ] QuickJS source comparison is documented, or reason for skipping is recorded.
- [ ] Regression test exists.
- [ ] Relevant matrix rows are updated.
- [ ] `TRACKING.md` validation log is updated.
- [ ] Status is changed to `validated`, `parked`, `duplicate`, or `out_of_scope`.

