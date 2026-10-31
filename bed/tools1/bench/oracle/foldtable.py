"""foldtable.py: the T3-fold accent table from Python's unicodedata (independent of any Go code).

    python3 -I tools1/bench/oracle/foldtable.py          prints the Go string constant
    python3 -I tools1/bench/oracle/foldtable.py --check  exit 0 when oracle_test.go carries exactly that constant

The rule (T3-fold's prompt): a letter in U+00C0..U+017F whose canonical decomposition (NFD) is an ASCII letter followed
only by combining marks folds to that ASCII letter; every other code point of the range (Æ Ð × Ø Þ ß ... ŉ Ŋ Œ Ŧ ſ) has
'.' in the table and is left as it is. The constant has one byte per code point from U+00C0 to U+017F (192 bytes).
"""
import pathlib
import sys
import unicodedata

LO, HI = 0xC0, 0x180


def table() -> str:
    out = []
    for cp in range(LO, HI):
        d = unicodedata.normalize("NFD", chr(cp))
        ok = len(d) > 1 and d[0].isascii() and d[0].isalpha() and all(unicodedata.combining(x) for x in d[1:])
        out.append(d[0] if ok else ".")
    return "".join(out)


def go_const() -> str:
    t = table()
    lines = [f'\t"{t[i:i + 64]}"' for i in range(0, len(t), 64)]
    return "const oracleLatinBase = \"\" +\n" + " +\n".join(lines) + "\n"


if __name__ == "__main__":
    if sys.argv[1:] == ["--check"]:
        src = (pathlib.Path(__file__).parent / "oracle_test.go").read_text("utf-8")
        sys.exit(0 if go_const() in src else 1)
    sys.stdout.write(go_const())
