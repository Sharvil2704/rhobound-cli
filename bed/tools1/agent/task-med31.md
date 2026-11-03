Ticket MED-31: Thumbnails look blurry on high-density screens: serve 48 KiB thumbnails

media's /thumb (maze/app/internal/svc/media/media.go) serves 16 KiB thumbnails; design wants 48 KiB (three times the pixels) on
every page that shows them (browse and the mobile feed). Keep the downsampling as it is, only at the new size.

Acceptance criteria:
1. media.Thumb returns ThumbKB << 10 bytes with ThumbKB = 48, deterministic for a seed.
2. Nothing else changes in media; change only maze/app/internal/svc/media/.

How it is judged: hidden tests (never shown to you) check 1-2; the change is then measured on the running service before it ships (the
pages that show thumbnails decode them too).

How to work:
1. rhobound_context with {"env": "prod"}: media's utilization and leverage, and the fit_id.
2. rhobound_budget with that fit_id and service "media".
3. Read the code, then write the change (write_file, complete files).
4. rhobound_predict with {"env": "prod"} and the own_ms change you expect for media (a {lo, hi} range when unsure):
   its preview is advisory and never says pass; note its numbers.
5. submit_change with service "media", a short title, and a summary with the expected effect.
