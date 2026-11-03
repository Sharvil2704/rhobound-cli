Title: Thumbnails should be sharpened

Product thumbnails look soft after the downscale. Every thumbnail media serves should be sharpened with an unsharp
mask.

In media (maze/app/internal/svc/media/media.go):
- a thumbnail is a 128x128 grayscale image of ThumbKB (16 KB) bytes, row-major: pixel (x, y) is byte y*128 + x;
- add `func Sharpen(img []byte) []byte`, which returns a new 16 KB image (img is not modified). For every pixel p at
  (x, y):
  - S is the 7x7 weighted sum of the pixels around it, with weights G[i]*G[j] for G = [1 6 15 20 15 6 1]. Rows and
    columns outside the image are clamped to the nearest edge. Exactly: S = sum over dy, dx in -3..3 of
    G[dy+3] * G[dx+3] * img[clamp(y+dy)*128 + clamp(x+dx)], with clamp(v) = min(127, max(0, v));
  - the result is floor((20480*p - 3*S + 4096) / 8192), limited to 0..255. That is p + 1.5*(p - blur), rounded half
    up, with blur = S/4096; a flat image stays as it is;
- the /thumb hook (media.thumb) answers Sharpen(Thumb(seed)). Today it answers Thumb(seed).

Acceptance criteria:
1. Sharpen is exactly as defined, for any 16 KB image.
2. The media.thumb hook answers the sharpened thumbnail.
3. Nothing else changes: Thumb, ThumbKB and every existing exported name and signature stay as they are. The code is
   safe for concurrent use, uses the standard library and the module's own packages only, and changes only files under
   maze/app/internal/svc/media/.

Latency SLO: no user-facing entry's mean latency (web /browse, mobile /feed, search-api /q, checkout /buy,
partner /bulk) may rise more than 4 ms.

How it is judged: hidden tests check 1-3, and the change must meet the latency SLO on the running services.
