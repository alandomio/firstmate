# Synthesis

Firstmate writes the synthesis once, at the close, as the neutral moderator, into `sintesi.md` in the council folder and in the council's output language.
It reports the council; it adds no finding and no vote of firstmate's own.
`fm-pal-council.sh finalize` refuses a synthesis that lacks any of the four level-2 headings for the council's language, listed here one line per language code:

```headings
it: Raccomandazione | Punti d'accordo | Disaccordi | Domande per il capitano
en: Recommendation | Agreements | Disagreements | Questions for the captain
```

For a language not listed, add its line here in the same shape before running `finalize`.

## What each section holds

1. **Recommendation.** The course the council's weight of argument supports, with the strongest reasons and the seats that carried them; when the council did not converge, say so and give the leading options instead of forcing one.
2. **Agreements.** The points every voice that delivered accepted, each with the finding numbers that establish it.
3. **Disagreements.** Each disagreement still open at the close: the positions, who holds each one (seat and model), and what would change the decision if it were settled.
4. **Questions for the captain.** Every question the voices addressed to the captain and every write or decision the council needs, one per line, each ready to become a captain-held task.

Close with one line on how the council ended (all voices done, a round with nothing new, the round limit, the budget, or the captain), the rounds run, and the estimated cost against the budget.
