"""A synthetic Collector capture of an A/B run: the offline proof's two auth arms (SPEC 0b) mixed into real production
lines of the same window, as the Collector's file exporter would hold them.
usage: python3 -I mkmixed.py ARMS_DIR PROD_SPANS_GZ OUT_DIR [STRIP_EVERY]
ARMS_DIR holds raw-a/traces/spans.jsonl and raw-b/traces/spans.jsonl (one arm span per line, made by mkarms.py).
OUT_DIR/traces/: two gzip files and one plain file ending in a partial line. Arm resourceSpans are merged into
production lines (many per line, a and b interleaved); every STRIP_EVERY-th (default 10; 0: none) arm resource loses
k8s.deployment.name (the pod-name fallback); production lines 60..299 of the capture, every 3rd (its traces have no
arm root: all dropped).
"""
import gzip
import json
import os
import sys


def arm_rs(path, strip_every):
    out = []
    with open(path) as f:
        for i, line in enumerate(f):
            for rs in json.loads(line)["resourceSpans"]:
                if strip_every and i % strip_every == 0:
                    rs["resource"]["attributes"] = [a for a in rs["resource"]["attributes"]
                                                    if a["key"] != "k8s.deployment.name"]
                out.append(rs)
    return out


def main(arms, prod, out, strip_every="10"):
    a = arm_rs(os.path.join(arms, "raw-a", "traces", "spans.jsonl"), int(strip_every))
    b = arm_rs(os.path.join(arms, "raw-b", "traces", "spans.jsonl"), int(strip_every))
    mixed = [x for pair in zip(a, b) for x in pair] + a[len(b):] + b[len(a):]
    prod_lines = []
    with gzip.open(prod, "rt") as f:
        for i, line in enumerate(f):
            if 60 <= i < 300 and i % 3 == 0:
                prod_lines.append(line)
    os.makedirs(os.path.join(out, "traces"), exist_ok=True)
    per = -(-len(mixed) // len(prod_lines))
    files = [gzip.open(os.path.join(out, "traces", "spans-2026-10-22T05-15-00.000.jsonl.gz"), "wt"),
             gzip.open(os.path.join(out, "traces", "spans-2026-10-22T05-17-00.000.jsonl.gz"), "wt"),
             open(os.path.join(out, "traces", "spans.jsonl"), "w")]
    for i, line in enumerate(prod_lines):
        d = json.loads(line)
        chunk = mixed[i * per:(i + 1) * per]
        # half of each chunk rides in the production line, half on a line of its own
        d["resourceSpans"] = chunk[: len(chunk) // 2] + d["resourceSpans"]
        f = files[min(2, i * 3 // len(prod_lines))]
        f.write(json.dumps(d, separators=(",", ":")) + "\n")
        if chunk[len(chunk) // 2:]:
            f.write(json.dumps({"resourceSpans": chunk[len(chunk) // 2:]}, separators=(",", ":")) + "\n")
    files[2].write('{"resourceSpans":[{"resource":{"attributes":[')   # the active file's partial tail
    for f in files:
        f.close()
    print(f"mixed: {len(a)} arm-a and {len(b)} arm-b spans into {len(prod_lines)} production lines", file=sys.stderr)


if __name__ == "__main__":
    if len(sys.argv) not in (4, 5):
        print(__doc__.strip().splitlines()[1], file=sys.stderr)
        sys.exit(2)
    main(*sys.argv[1:])
