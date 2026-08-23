---
name: aws-goplanner-skills
description: Pointer inventory of project-specific skills that exist in the aws-goplanner repo (projects/aws-goplanner). Load before starting work on aws-goplanner to check whether an existing project skill already covers the task instead of re-deriving domain knowledge from scratch.
---

# aws-goplanner project skills

This is a thin pointer, not a copy of the listed skill's own instructions.

On the `main` branch (this repo's git default), the only project-specific skill is:

- `.claude/skills/implement-ticket` - implements an infrastructure Jira ticket (GOP project, `infra` label) end-to-end using Jira as source of truth and state storage; on a leaf task it implements that task, on an epic it loops sequentially over ready child tasks respecting the dependency graph and human checkpoints.
