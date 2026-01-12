---
name: Prep a branch, commit, and open a draft PR
description: Create a GitHub PR with the repo template using gh CLI.
---

Create a branch named `feat/<feature_name>` for this work. using the gh CLI and the PR template.

Rules:
- Ensure gh is installed and authenticated.
- Use the current branch as the head.
- Stage and commit changes with a clear message.
- Default base branch to main unless the user specifies otherwise.
- Open a draft PR on the same branch.
- Use gh CLI to fetch diffs and decide the PR title and summary.
- Use the template at .github/pull_request_template.md for the body.
- If the user asks for a draft PR, add --draft.

Command:
gh pr create --title
