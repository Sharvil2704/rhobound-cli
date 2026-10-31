# Two synthetic A/B arm captures of a LEAF service (auth) from a real kshop capture: auth SERVER spans made roots, arm b's
# spans EXTRA_MS longer, the same request times in both arms; rc-a/rc-b.json and loadgen.csv as ab.sh writes them.
# Adapted from the 2026-10-30 offline proof (SPEC 0b, leaf/mkarms.py); the only change is the EXTRA_MS argument.
#   python3 -I mkarms.py SPANS.jsonl.gz OUT SECONDS EXTRA_MS
import datetime
import gzip
import json
import os
import random
import sys

src, out, secs, extra_ms = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
spans = []
with gzip.open(src, 'rt') as f:
    for line in f:
        d = json.loads(line)
        for rs in d.get('resourceSpans', []):
            attrs = {a['key']: a['value'].get('stringValue') for a in rs['resource']['attributes']}
            if attrs.get('service.name') != 'auth':
                continue
            for ss in rs['scopeSpans']:
                for sp in ss['spans']:
                    if sp.get('kind') != 2:
                        continue
                    spans.append((int(sp['startTimeUnixNano']), sp, rs['resource'], ss['scope']))
spans.sort(key=lambda x: x[0])
t0 = spans[0][0] + int(60e9)
spans = [s for s in spans if t0 <= s[0] < t0 + int(secs * 1e9)]
print('auth server spans in window:', len(spans))
rnd = random.Random(1)


def arm(name, extra_ns, tag):
    d = os.path.join(out, 'raw-' + tag)
    os.makedirs(os.path.join(d, 'traces'), exist_ok=True)
    rows = []
    with open(os.path.join(d, 'traces', 'spans.jsonl'), 'w') as f:
        for i, (st, sp, res, scope) in enumerate(spans):
            sp = dict(sp)
            sp.pop('parentSpanId', None)
            sp['traceId'] = '%032x' % rnd.getrandbits(128)
            sp['spanId'] = '%016x' % rnd.getrandbits(64)
            sp['endTimeUnixNano'] = str(int(sp['endTimeUnixNano']) + extra_ns)
            r = json.loads(json.dumps(res))
            for a in r['attributes']:
                if a['key'] == 'k8s.deployment.name':
                    a['value'] = {'stringValue': name}
                if a['key'] == 'k8s.pod.name':
                    a['value'] = {'stringValue': name + '-5d9f-abcde'}
            f.write(json.dumps({'resourceSpans': [{'resource': r, 'scopeSpans': [{'scope': scope, 'spans': [sp]}]}]}) + '\n')
            rows.append((i + 1, st - 300000, int(sp['endTimeUnixNano']) + 300000))
    return rows


ra = arm('auth-ab-a', 0, 'a')
rb = arm('auth-ab-b', int(extra_ms * 1e6), 'b')


def iso(ns):
    return datetime.datetime.fromtimestamp(ns / 1e9, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


S, E = t0, t0 + int(secs * 1e9)
for tag, rows in (('a', ra), ('b', rb)):
    with open(os.path.join(out, 'rc-%s.json' % tag), 'w') as f:
        json.dump({'schema': 'rhobound.request-count/v1', 'window': {'start': iso(S), 'end': iso(E)}, 'source': 'loadgen',
                   'entries': [{'entry': 'auth', 'count': len(rows)}]}, f)
with open(os.path.join(out, 'loadgen.csv'), 'w') as f:
    f.write('arm,seq,sent_unix_ns,answered_unix_ns,status\n')
    for (i, s, e) in ra:
        f.write('A,%d,%d,%d,200\n' % (i, s, e))
    for (i, s, e) in rb:
        f.write('B,%d,%d,%d,200\n' % (i, s, e))
with open(os.path.join(out, 'window.txt'), 'w') as f:
    f.write('%s,%s\n' % (iso(S), iso(E)))
print('window', iso(S), iso(E))
