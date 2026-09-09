# Generated ship-brief Definition-of-done excerpts (bin/fm-brief.sh @ d181869)

Fixtures: gh-proj -> origin github.com; gl-proj -> origin gitlab.com. Line numbers are from the generated brief.md.

## directpr-gh
```
73-The task is complete only when committed on your branch.
74:Write the pull request description with the mr-description skill (`~/.claude/skills/mr-description`), never by hand.
75-That skill ends by offering the text to a human; you are that human here, so create the pull request yourself and never wait for confirmation on a step this brief already authorizes.
76:Do not include a "Generated with Claude Code" trailer or other orchestration vocabulary in the description.
77-When it is implemented and committed, push your branch and open a pull request with gh-axi, then append `done: PR {url}` to the status file and stop.
```

## directpr-gl
```
73-The task is complete only when committed on your branch.
74:Write the merge request description with the mr-description skill (`~/.claude/skills/mr-description`), never by hand.
75-That skill ends by offering the text to a human; you are that human here, so create the merge request yourself and never wait for confirmation on a step this brief already authorizes.
76:Do not include a "Generated with Claude Code" trailer or other orchestration vocabulary in the description.
77-When it is implemented and committed, push your branch and open a merge request with glab, then append `done: MR {url}` to the status file and stop.
```

## nomistakes-gh
```
87-
88:Write the pull request description with the mr-description skill (`~/.claude/skills/mr-description`), never by hand.
89-That skill ends by offering the text to a human; you are that human here, so create or update the pull request yourself and never wait for confirmation on a step this brief already authorizes.
90:Do not include a "Generated with Claude Code" trailer or other orchestration vocabulary in the description.
91-
```

## nomistakes-gl
```
87-
88:Write the merge request description with the mr-description skill (`~/.claude/skills/mr-description`), never by hand.
89-That skill ends by offering the text to a human; you are that human here, so create or update the merge request yourself and never wait for confirmation on a step this brief already authorizes.
90:Do not include a "Generated with Claude Code" trailer or other orchestration vocabulary in the description.
91-
```

## local-only and scout (must NOT reference the skill)
```
localonly: mr-description occurrences = 0
scout: mr-description occurrences = 0
```
