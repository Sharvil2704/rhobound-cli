| change | services | verdict | true? | in band | R lead | B lead (no B0) | S lead | R occupancy | B occupancy | saving vs B | vs S |
|---|---|---|---|---|---|---|---|---|---|---|---|
| T6-R | rank | pass | yes | 5/5 | 7.5 | 15.4 (9.2) | 15.4 (computed) | 1 s | 15.4 | 7.9 | 7.9 |
| T8-R | pricing | pass | yes | 5/5 | 7.6 | 15.4 (9.2) | 15.4 (computed) | 1 s | 15.4 | 7.9 | 7.9 |
| T7-R-r3 | fraud | pass | yes | 5/5 | 32.5 | 15.4 (9.2) | 15.4 (computed) | 2 s | 15.4 | -17.1 | -17.1 |
| T9-R | media | pass | yes | 5/5 | 8.0 | 15.5 (9.2) | 15.5 (computed) | 1 s | 15.5 | 7.5 | 7.5 |
| m3 | rank,pricing,media | pass | yes | 5/5 | 23.6 | 15.5 (9.3) | 34.0 | 3 s | 15.5 | -8.1 | 10.4 |
| m3n | rank,pricing,media | block | yes | 4/5 | 23.7 | 15.5 (9.3) | 34.1 | 0 s | 15.5 | -8.2 | 10.3 |
| m4 | rank,pricing,media,fraud | inconclusive | n/a | 5/5 | 46.5 | 15.5 (9.3) | 43.3 (computed) | 930 s | 15.5 |  |  |

Times in minutes unless marked; R occupancy in seconds. Savings only where the verdict came true.

| change | n | R lead | B / S at 5 min | B / S at 15 min | B / S at 30 min | B / S at 60 min |
|---|---|---|---|---|---|---|
| T6-R | 1 | 7.5 | 13 / 13 | 33 / 33 | 63 / 63 | 123 / 123 |
| T8-R | 1 | 7.6 | 13 / 13 | 33 / 33 | 63 / 63 | 123 / 123 |
| T7-R-r3 | 1 | 32.5 | 13 / 13 | 33 / 33 | 63 / 63 | 123 / 123 |
| T9-R | 1 | 8.0 | 13 / 13 | 33 / 33 | 63 / 63 | 123 / 123 |
| m3 | 3 | 23.6 | 13 / 29 | 33 / 69 | 63 / 129 | 123 / 249 |
| m3n | 3 | 23.7 | 13 / 29 | 33 / 69 | 63 / 129 | 123 / 249 |
| m4 | 4 | 46.5 | 13 / 37 | 33 / 87 | 63 / 162 | 123 / 312 |

Minutes. R is as measured (an inconclusive R includes its fallback bake at this protocol's 5-min windows).
