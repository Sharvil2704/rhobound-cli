"""The production load setting (SPEC3 F6a): RBD_LOAD_RPS (the total rate) and RBD_LOAD_MIX (the weights of spec.json's load
URLs by name: browse=W,card=W,wallet=W), kept in ONE file, $RBD_HOME/load.env, read by capture.sh (its window) and by
bgload.sh (the background load, also when capture.sh's trap starts it again after a window). No file: spec.json's load
(100 rps; browse 0.70, card 0.18, wallet 0.12), exactly as before.

    python3 -I loadmix.py show FILE | --default     the effective setting, one JSON line (rbd.load/v1, below)
    python3 -I loadmix.py envfile (--rps R [--mix M] | --mix M | --rates M) [--by WHO]   a load.env for it on stdout

FILE (load.sh set writes it; it is parsed, never sourced): '#' comments, blank lines and exactly the two lines
RBD_LOAD_RPS=R (10..400 rps, at most one decimal: kshop-load logs its rate with one) and RBD_LOAD_MIX=M (render.py's
--mix-weights: every URL named once, W a plain decimal >= 0 (never 1e-05: that is refused) summing > 0, relative, so
per-URL rates work as weights; a 0 leaves the URL out of the Job, and verify's load_ok then refuses the window: 3 result
lines). It must be a regular file (not a symlink) owned by root, by the reader or by its folder's owner (rbd), and not
group/other-writable.
envfile: a part not given is spec.json's (not an older file's); --rates browse=91,card=18,wallet=12 gives per-URL rates,
R = their sum (a multiple of 0.1). It writes every weight as a plain decimal (0.00001, 10000000000000000; the shortest
that reads back as the same float) and reads its own output back through the parser show uses before printing it: a
setting it accepts is one every reader accepts (else refused, exit 1).
The environment never overrides the file: RBD_LOAD_RPS / RBD_LOAD_MIX set there (rbd.env.local) must equal the setting
(the rate exactly, the mix by shares) or are refused, so no step runs at a load the file does not hold.
Output (no "url" key: verify's load_ok counts '"url"' lines in load.json, where capture.sh appends this object):
  {"schema": "rbd.load/v1", "source": "default"|"load.env", "file", "sha256" (both null by default), "rps",
   "mix" (M, canonical), "shares" {name: w/sum}, "rates" {name: rps}, "entries" {entry service: rps}, "summary"}
Exit 0; 1 refused (the reason on stderr, nothing on stdout); 2 usage.
"""
import argparse
import datetime
import decimal
import hashlib
import json
import os
import re
import stat
import sys
import urllib.parse

sys.dont_write_bytecode = True   # no __pycache__ in the kit (/opt/rbd is root's)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # render.py, beside this file: spec.json's mix and its parser
import render  # noqa: E402

RPS = re.compile(r"^[0-9]+(\.[0-9])?$")
RPS_MIN, RPS_MAX = 10.0, 400.0
KEYS = ("RBD_LOAD_RPS", "RBD_LOAD_MIX")
LINE = re.compile(r"^([A-Z_][A-Z0-9_]*)=(.*)$")
SCHEMA = "rbd.load/v1"


class Refused(Exception):
    pass


def rps_of(text: str, label: str = "RBD_LOAD_RPS") -> float:
    if not RPS.match(text or ""):
        raise Refused(f"{label}={text!r}: the rate is a plain decimal with at most one decimal place (e.g. 130, 121.5)")
    r = float(text)
    if not RPS_MIN <= r <= RPS_MAX:
        raise Refused(f"{label}={text}: the rate must be {RPS_MIN:g}..{RPS_MAX:g} rps")
    return r


def weights_of(text: str, label: str = "RBD_LOAD_MIX") -> list:
    try:
        return render.parse_weights(text)
    except ValueError as e:
        raise Refused(f"{label}={text!r}: {e}") from None


def default() -> tuple:
    names = list(render.mix_targets().items())
    return float(render.SPEC["load"]["rps"]), [(n, u, float(m["w"])) for (n, u), m in zip(names, render.SPEC["load"]["mix"])]


def wtext(w: float) -> str:
    """w as the plain decimal render.WEIGHT accepts: repr's shortest round-trip digits, never its exponent form
    (1e-05 -> 0.00001, 1e+16 -> 10000000000000000; 0.7, 1.0, 91.0 as repr writes them)."""
    return format(decimal.Decimal(repr(w)), "f")


def canon(weights) -> str:
    return ",".join(f"{n}={wtext(w)}" for n, _, w in weights)


def shares_of(weights) -> dict:
    total = sum(w for _, _, w in weights)
    return {n: w / total for n, _, w in weights}


def setting(rps: float, weights, source: str, path=None, sha=None) -> dict:
    shares = shares_of(weights)
    rates = {n: rps * s for n, s in shares.items()}
    entries: dict[str, float] = {}
    for n, u, _ in weights:
        e = (urllib.parse.urlsplit(u).hostname or "").split(".")[0]
        entries[e] = entries.get(e, 0.0) + rates[n]
    r6 = lambda d: {k: round(v, 6) for k, v in d.items()}  # noqa: E731
    return {"schema": SCHEMA, "source": source, "file": path, "sha256": sha, "rps": rps, "mix": canon(weights),
            "shares": r6(shares), "rates": r6(rates), "entries": r6(entries),
            "summary": f"{rps:g} rps ({source}): " + ", ".join(f"{n} {r:.4g}" for n, r in rates.items())}


def read_file(path: str):
    """(rps, weights, sha256) of a load.env; None when there is none."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return None
    except OSError as e:
        raise Refused(f"{path}: {e.strerror} (a symlink is refused)") from None
    with os.fdopen(fd, "rb") as f:
        st = os.fstat(f.fileno())
        data = f.read(65536)
    if not stat.S_ISREG(st.st_mode):
        raise Refused(f"{path} is not a regular file: refused")
    try:
        folder = os.stat(os.path.dirname(os.path.abspath(path))).st_uid
    except OSError:
        folder = 0
    uids = sorted({0, os.getuid(), folder})
    if st.st_uid not in uids or st.st_mode & 0o022:
        raise Refused(f"{path} must be owned by root or rbd (uid {', '.join(map(str, uids))}) and not group/other-writable "
                      f"(uid {st.st_uid}, mode {st.st_mode & 0o777:o}): refused")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        raise Refused(f"{path}: not UTF-8 text") from None
    return parse_text(text, path) + ("sha256:" + hashlib.sha256(data).hexdigest(),)


def parse_text(text: str, path: str) -> tuple:
    """(rps, weights) of a load.env's text (read_file's parser; envfile reads its own output back with it)."""
    vals: dict[str, str] = {}
    for i, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        m = LINE.match(s)
        if not m or m.group(1) not in KEYS:
            raise Refused(f"{path}: line {i} is not RBD_LOAD_RPS=... or RBD_LOAD_MIX=... ({s[:60]!r})")
        if m.group(1) in vals:
            raise Refused(f"{path}: line {i}: {m.group(1)} a second time")
        vals[m.group(1)] = m.group(2)
    missing = [k for k in KEYS if k not in vals]
    if missing:
        raise Refused(f"{path}: no {' and no '.join(missing)} (load.sh set writes both)")
    return rps_of(vals["RBD_LOAD_RPS"], f"{path}: RBD_LOAD_RPS"), weights_of(vals["RBD_LOAD_MIX"], f"{path}: RBD_LOAD_MIX")


def env_check(rps: float, weights, what: str) -> None:
    """RBD_LOAD_RPS / RBD_LOAD_MIX in the environment must say what the setting says."""
    how = ("the load is set with load.sh set (one file, read by capture.sh and bgload.sh), never by the environment: "
           "remove it (rbd.env.local?) or set the same")
    er, em = os.environ.get("RBD_LOAD_RPS", ""), os.environ.get("RBD_LOAD_MIX", "")
    if er and rps_of(er, "RBD_LOAD_RPS in the environment") != rps:
        raise Refused(f"RBD_LOAD_RPS={er} in the environment, but {what} is {rps:g} rps: {how}")
    if em:
        want, got = shares_of(weights), shares_of(weights_of(em, "RBD_LOAD_MIX in the environment"))
        if any(abs(want[n] - got[n]) > 1e-9 for n in want):
            raise Refused(f"RBD_LOAD_MIX={em} in the environment, but {what} is {canon(weights)}: {how}")


def show(path, use_default: bool) -> dict:
    got = None if use_default else read_file(path)
    if got is None:
        rps, weights = default()
        s = setting(rps, weights, "default")
    else:
        s = setting(got[0], got[1], "load.env", os.path.abspath(path), got[2])
    env_check(s["rps"], weights_of(s["mix"]), f"the setting ({s['source']})")
    return s


def envfile(a) -> str:
    d_rps, d_w = default()
    if a.rates:
        weights = weights_of(a.rates, "--rates")
        total = sum(w for _, _, w in weights)
        if abs(total * 10 - round(total * 10)) > 1e-6:
            raise Refused(f"--rates sum to {total:g} rps: kshop-load logs its rate with one decimal; make the sum a multiple of 0.1")
        rps = rps_of(repr(round(total, 1)), f"--rates (their sum, {total:g})")
    else:
        rps = rps_of(a.rps, "--rps") if a.rps else d_rps
        weights = weights_of(a.mix, "--mix") if a.mix else d_w
    env_check(rps, weights, "the new setting")
    when = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    body = (f"# {SCHEMA} (SPEC3 F6a): the production load, read by capture.sh and bgload.sh. Written by load.sh set"
            f" ({a.by or 'unknown'}, {when}); load.sh reset removes it. Never edit by hand: load.sh set validates.\n"
            f"RBD_LOAD_RPS={rps!r}\nRBD_LOAD_MIX={canon(weights)}\n")
    back = parse_text(body, "the load.env envfile would write")   # the readers' parser: what it accepts, they accept
    if back != (rps, weights):
        raise Refused(f"the load.env envfile would write reads back as {back[0]:g} rps, {canon(back[1])}, not {rps:g} rps, "
                      f"{canon(weights)}: refused")
    return body


def main() -> int:
    p = argparse.ArgumentParser(prog="loadmix.py", description="the production load setting (SPEC3 F6a)")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("show", help="the effective setting, one JSON line")
    s.add_argument("file", nargs="?")
    s.add_argument("--default", action="store_true", help="spec.json's load (what load.sh reset makes), env-checked")
    e = sub.add_parser("envfile", help="a load.env for the setting, on stdout")
    e.add_argument("--rps")
    e.add_argument("--mix")
    e.add_argument("--rates")
    e.add_argument("--by", default="")
    a = p.parse_args()
    if a.cmd == "show":
        if bool(a.file) == a.default:
            p.error("show FILE or show --default")
        print(json.dumps(show(a.file, a.default), separators=(",", ":")))
        return 0
    if not (a.rps or a.mix or a.rates) or (a.rates and (a.rps or a.mix)):
        p.error("envfile --rps R [--mix M] | --mix M | --rates M (spec.json's load again: load.sh reset)")
    sys.stdout.write(envfile(a))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Refused as e:
        print(f"loadmix: {e}", file=sys.stderr)
        sys.exit(1)
