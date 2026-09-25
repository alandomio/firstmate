# Writing a voice persona

Each voice gets a persona written for this council's question, on the model of a role card: a mandate, what to examine, what to leave to others, and how to support a claim.
Firstmate writes one file per seat at `persone/<seat>.md` in the council folder, in English, before `launch`.

## Rules

- Derive the personas from the question, not from a fixed cast: pick the three to five perspectives whose disagreement would most improve the decision.
- Give every seat a different persona; two seats never share a mandate, and an economy seat is a real perspective, not a lesser copy.
- Keep one seat adversarial toward the most likely answer, so the council cannot converge by politeness.
- Never state a conclusion, a preferred option, or the captain's leaning in a persona; a persona frames how to look, not what to find.
- Keep private names, customers, and identifying data out of personas, because they reach voices outside Anthropic.
- A participant the captain listed explicitly with its own persona keeps that text; add only what the rules above require.

## Perspectives that often fit

| Question | Perspectives |
|---|---|
| A technical design or architecture choice | the architect who owns the long-term shape, the operator who runs it at 3 a.m., the security reviewer, the skeptic of the favoured option |
| A product or workflow change | the end user, the maintainer who carries the cost, the person who measures the outcome, the skeptic |
| A vendor, tool, or build-versus-buy choice | the engineer who integrates it, the one who pays for it, the one who has to leave it later, the skeptic |
| A process, policy, or legal-adjacent question | the person bound by it, the person who enforces it, the one who audits it, the skeptic |

## Shape of one persona

```markdown
# Persona: <short title>

## Mandate
<one or two sentences: what this voice is responsible for judging>

## What to examine
- <the questions this voice asks of every option>

## What to leave to others
- <the perspectives other seats own, so this voice does not dilute its own>

## Evidence rule
<what counts as support for a claim from this perspective: code and file references, measurements, sources, precedent>
```
