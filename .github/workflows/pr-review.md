---
on:
  pull_request:
    types: [opened, synchronize]

permissions:
  contents: read
  pull-requests: read
  # Grants model inference only; repository writes remain gated by safe-outputs.
  copilot-requests: write

safe-outputs:
  add-comment:
    max: 1
  create-pull-request-review-comment:
    max: 10
  submit-pull-request-review:
    allowed-events: [COMMENT]
---

# Pull Request Review Assistant

Review the pull request diff for correctness, security, maintainability, and test coverage.

Create inline review comments only for specific defects or concrete improvements. Add one concise summary grouped by severity, noting any human follow-up needed. Do not restate unchanged code, make style-only comments, approve or merge pull requests, modify repository contents, access secrets, or perform destructive actions. If there are no actionable findings, submit a comment stating that.
