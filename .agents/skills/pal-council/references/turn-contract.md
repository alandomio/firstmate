# Turn contract

Every intervention a council voice writes is one Markdown file, `turni/<round>-<seat>.md` in the council folder, and it ends with the closing block below.
`bin/fm-pal-council.sh` reads the bracketed markers mechanically, so copy them exactly, in English, whatever language the rest of the turn is written in.
Write the headings and the prose in the council's output language.

## Body

- **Findings.** Number each finding `<seat>-<round>-<n>` and give the claim, the evidence behind it (file and line, command and output, source URL), and what it would change in the decision.
- **Positions, from round 2.** For every other voice's finding that touches your view, write `agree`, `object` with the reason, or a `counter-proposal`, citing the finding's number.
  For each of your own earlier findings, say whether you keep, modify, or withdraw it, and why.
- A round with nothing new and no changed position is one line saying so, followed by the closing block.

## Closing block

These are the last lines of the file, in this order:

    ## <Blockers heading>
    [BLOCKER] <what stops you, including any write the council's work would need>
    ## <Questions heading>
    [QUESTION] <a question for the captain>
    [QUESTION] @<seat> <a question for another voice>
    ## <Research requests heading>
    [RESEARCH] <one self-contained question for the researcher, with no private names or data>
    [STATUS] CONTINUE new=<findings new this round> changed=<your positions changed this round>

- Write the word for "none" under a heading that has nothing, rather than dropping the heading.
- `[STATUS]` is the very last non-empty line, and the file counts as delivered only once that line is there.
- Its value is `CONTINUE` while you think the debate should go on, and `DONE` when you have nothing more to add unless something new arrives.
- Round 1 is blind, so it always reports `changed=0`.
- One `[RESEARCH]` line per question; the researcher answers each one separately and every voice reads the same answers.
