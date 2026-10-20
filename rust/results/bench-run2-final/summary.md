| capture | threads | Go wall (s) | rbfast wall (s) | speedup | Go user+sys (s) | rbfast user+sys (s) | Go / rbfast peak RSS (MiB) | others' busy cores (Go / rbfast run) | same output |
|---|---|---|---|---|---|---|---|---|---|
| RUN3 (579 MB) | 1 | 5.161 | 0.894 | 5.77x | 5.16 | 0.90 | 213 / 99 | 0.15 / 0.21 | yes |
| RUN3 (579 MB) | 2 | 2.773 | 0.466 | 5.95x | 5.26 | 0.91 | 216 / 101 | 0.13 / 0.07 | yes |
| RUN3 (579 MB) | 4 | 1.541 | 0.253 | 6.09x | 5.30 | 0.93 | 213 / 105 | 0.14 / 0.14 | yes |
| RUN3 (579 MB) | 8 | 0.992 | 0.151 | 6.57x | 5.49 | 0.96 | 243 / 116 | 0.10 / 0.17 | yes |

Each cell: median of 3 timed runs after one warm-up, warm page cache, in a memory-capped scope (4 GB, nice 10).

rbfast at 8 threads, inside the process (median of 3; RBFAST_TIMES=1):

| capture | read (s) | inference (s) | model (s) | report (s) |
|---|---|---|---|---|
| RUN3 | 0.1171 | 0.0297 | 0.0008 | 0.0002 |
