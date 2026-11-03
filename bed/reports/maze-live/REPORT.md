# rhobound on rhobound-maze: results of local campaign 1 and AWS run 1 (2026-11-01)

rhobound-maze is a 32-service, 28-image app built to break rhobound's mean-latency model while keeping its stated
assumptions: fan-out batches, routes of different cost behind one service, payloads decoded by callers, asynchronous
calls, and shared images. Nine planted changes and four tickets for the Meta coding model (muse-spark-1.3, with the
rhobound MCP tools) were gated, predicted and then measured. The expected misses were written down before measuring
(rhobound-maze `campaign/DECLARE.md`), and the predictions were committed before any truth window ran
(`campaign/SEALED-local1.md`, `campaign/SEALED-aws1.md`).

## Headline

- **The gate made no wrong pass, but on this app it passed nothing either.** Every change except the large rank
  regression came back `inconclusive: model_misfit`: rhobound noticed that its baseline fit does not explain maze and
  refused to vouch. That held the no-op control and the Meta agent's real improvements (pricing: partner −18.8 ms on AWS).
- **The rank regression was blocked correctly, and its prediction was right.** AWS: mobile +7.85, search-api +7.47 ms
  against a predicted +6.92..+8.20.
- **Every other planted mechanism was missed, in the direction declared beforehand:**
  - batch arrivals: 3–6× too small;
  - per-route blending: 4–5× too small on the route's caller;
  - payload decoded by the callers: about 10× too small;
  - a variance change;
  - a changed call structure.
- **The Meta agent solved all four tickets.** All four patches pass the hidden tests, one after a single
  compile-error retry. It used the MCP tools in every run.

## Local campaign (one machine, four 300-s truth windows per change; noise = max of block SE and half the window disagreement)

| change | entry | truth ms | noise | rhobound change | with model error | naive A/B x visits | inside? |
|---|---|---|---|---|---|---|---|
| c7 noop | all | -0.27..+0.77 | 0.4-1.4 | ~0 | | ~0 | yes |
| c3 rank +2.1 ms | mobile | +5.49 | 0.57 | +5.25..+6.37 | | +2.14 | yes |
| | search-api | +5.22 | 0.60 | +5.25..+6.37 | | +2.14 | yes |
| c1 search typo (catalog /search +2.7 ms) | search-api | **+3.75** | 0.52 | +0.43..+0.69 | -0.63..+1.84 | +0.56 | **no** |
| c8 search index | search-api | -1.14 | 0.94 | -0.50..-0.22 | | -0.36 | yes |
| c2 thumb sharpen (media +1.0 ms) | web | **+6.76** | 0.37 | +1.88..+2.11 | -1.75..+4.02 | +5.43 | **no** |
| | mobile | **+5.99** | 0.59 | +2.00..+2.26 | -2.13..+4.54 | +7.90 | **no** |
| c4 thumbs 48 KiB (media +0.06 ms) | web | **+1.27** | 0.28 | +0.04..+0.14 | | +0.30 | **no** |
| | mobile | **+1.38** | 0.45 | +0.04..+0.15 | | +0.44 | **no** |
| c9 pricing table (pricing -2.5 ms) | partner | **-15.13** | 0.61 | -3.39..-3.24 | -5.22..+1.36 | -19.82 | **no** |
| | checkout | **-8.69** | 1.01 | -3.04..-2.90 | -6.22..-0.10 | -2.48 | **no** |
| c5 fraud deep check (1 in 20 +60 ms) | checkout | **+8.22** | 1.41 | +1.69..+5.30 | -1.88..+9.08 | +2.12 | **no** |
| c6 recs profile cache | web | **-1.73** | 0.52 | -0.15..+0.10 | | -0.03 | **no** |

Gate (policy: 4 ms, block_band model, strict doubts): c3 **block**, all others inconclusive (`model_misfit`, plus
`model.batch_arrivals`). Full rows: rhobound-maze `campaign/scores-local1.json`.

## AWS run (8-machine k3s cluster; one 300-s B0/C bracket per change; the no-op moved entries by -2.2..-0.1 ms, so AWS noise is about +-2 ms)

| PR | change | A/B own_ms | gate | rhobound (entry) | truth |
|---|---|---|---|---|---|
| 1 | c7 noop (pricing) | +0.028 | inconclusive | ~0 | all -2.2..-0.1 (noise) |
| 2 | **Meta** PRC-77 pricing table | -2.360 | inconclusive | partner -3.35..-3.23, checkout -2.94..-2.83 | **partner -18.81, checkout -9.15** |
| 3 | **Meta** SRCH-12 search index | -0.328 | inconclusive | search-api -0.45..-0.20 | (not bracketed) |
| 4 | **Meta** SRCH-19 typo search | +0.039 | inconclusive | search-api -0.11..+0.19 | (not bracketed) |
| 5 | **Meta** MED-31 48 KiB thumbs (parallel) | -0.037 | inconclusive | web/mobile -0.12..-0.01 | web +0.88, mobile +0.87 (within 2x noise) |
| 6 | c3 rank | +2.667 | **block** | mobile/search-api +6.92..+8.20 | **mobile +7.85, search-api +7.47** |
| 7 | c1 search typo | +0.869 | inconclusive | search-api +0.73..+1.02 | **search-api +3.89**, web +0.24 |
| 8 | c8 search index | -0.387 | inconclusive | search-api -0.52..-0.26 | (not bracketed) |
| 9 | c2 thumb sharpen | +1.014 | inconclusive | web +2.04..+2.24, mobile +2.20..+2.42 | **web +8.00, mobile +8.70** |
| 10 | c4 thumbs 48 KiB | +0.210 | inconclusive | | (not bracketed) |
| 11 | c9 pricing table | -2.348 | inconclusive | partner -3.34..-3.20 | (not bracketed; PR 2 is the same fix) |
| 12 | c5 fraud deep check | +2.301 | inconclusive | checkout +1.84..+5.87 | (not bracketed) |
| 13 | c6 recs profile cache | +0.082 | inconclusive | web -0.09..+0.17 | (not bracketed) |

The Meta agent's four patches against the tickets' hidden tests (never shown to it; the unpatched code fails T3 and T4):
PRC-77 pass (Quote 2.40 ms -> 7 ns), SRCH-12 pass (Search 1.33 -> 0.05 ms), SRCH-19 pass (typo matching at no
measurable cost: it precomputes the matching words per query), MED-31 pass (bit-identical downsample, split over 4
goroutines; the first attempt failed to compile and was retried with the compiler's message).

## What the misses have in common

In each case the cost of the change sits somewhere a single-service A/B on a Poisson schedule cannot see:
- **Batch arrivals:** the queueing at a callee fed by fan-out batches.
- **Route blending:** a route-specific cost averaged over all routes.
- **Payload:** work done by the callers.
- **Variance:** a rare slow call that the mean hides.
- **Call structure:** a removed downstream call.

The root-cause analysis and fixes follow in `reports/maze-live/RCA.md`.
