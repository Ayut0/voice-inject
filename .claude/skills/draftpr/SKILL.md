---
name: draftpr
description: Create a GitHub draft PR with the repo template using gh CLI
argument-hint: "[feature-name]"
disable-model-invocation: true
allowed-tools: Bash(gh *), Bash(git *), Read, Glob, Grep
---

Prep a branch, commit, and open a draft PR for the current changes.

## Context

- Current branch: !`git branch --show-current`
- Diff summary: !`git diff --stat`
- Staged changes: !`git diff --cached --stat`
- PR template: !`cat .claude/skills/draftpr/template.md`

## Steps

1. Verify `gh` is installed and authenticated.
2. If not already on a feature branch, create and switch to `feat/$ARGUMENTS`.
3. Stage all changes and commit with a clear, imperative message.
4. Push the branch to origin.
5. Use the diff against `main` to determine an appropriate PR title and summary.
6. Open a draft PR with `gh pr create --draft --base main`, filling in the Summary and Changes sections of the PR template based on the diff.
7. Return the PR URL when done.
