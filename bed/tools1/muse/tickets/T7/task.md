Title: Fraud scoring should catch card velocity

fraud scores each charge from fixed rules only. A card that is tried many times within a minute, or charged far above
its usual amount, should score higher.

In fraud (maze/app/internal/svc/fraud/fraud.go):
- each /score request is a charge. Its card is `Card(seed)` = int(seed % 997) and its amount is `Amount(seed)` =
  500 + int(seed*7919 % 20000) cents, where seed is the hook's request counter (the value Score gets today). Add these
  two functions.
- add `type Velocity`, the recent charges, with `func NewVelocity() *Velocity` and
  `func (v *Velocity) Check(card, amountCents int, at time.Time) (extra int, reasons []string)`. Check records the
  charge and returns its extra risk:
  - +30 with the reason "velocity" when the card has at least 4 charges, this one included, at times in (at-60s, at];
  - +25 with the reason "amount" when the card has at least 3 earlier charges at times in (at-10min, at) and this
    amount is more than 3 times their mean;
  - the reasons come in that order; there are none when the extra is 0.
- memory stays bounded: a charge at or before at-10min is dropped by the time Check(..., at) returns, whatever its card.
  Add `func (v *Velocity) Len() int`, the number of charges kept.
- the /score hook (fraud.score) keeps one Velocity for the process and answers
  {"risk":R,"reasons":[...]} with R = min(99, Score(seed) + extra) for the charge (Card(seed), Amount(seed)) at the
  current time. Today it answers {"risk":N}.

Acceptance criteria:
1. Card, Amount, NewVelocity, Check and Len are as defined.
2. The fraud.score hook answers as defined.
3. Nothing else changes: Score and every existing exported name and signature stay as they are. The code is safe for
   concurrent use, uses the standard library and the module's own packages only, and changes only files under
   maze/app/internal/svc/fraud/.

Latency SLO: no user-facing entry's mean latency (web /browse, mobile /feed, search-api /q, checkout /buy,
partner /bulk) may rise more than 4 ms.

How it is judged: hidden tests check 1-3, and the change must meet the latency SLO on the running services.
