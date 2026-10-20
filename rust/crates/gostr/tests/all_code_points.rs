// SPDX-License-Identifier: Apache-2.0

//! Every Unicode scalar value through quote, quote_rune, is_print and is_space, and every invalid lead byte
//! through quote_bytes, against Go 1.27.2: the dump's FNV-1a 64 hash equals that of the same dump written by Go's
//! strconv.Quote, strconv.QuoteRune, unicode.IsPrint and unicode.IsSpace (the Go program is in the doc comment of
//! `dump`). Set GOSTR_DUMP=path to write the dump for a line-by-line diff.

use rbfast_gostr::{is_print, is_space, quote, quote_bytes, quote_rune};

/// The hash of the Go program's output (go1.27.2, linux/arm64):
///
/// ```go
/// for r := rune(0); r <= 0x10FFFF; r++ {
///     if r >= 0xD800 && r <= 0xDFFF { continue }
///     fmt.Fprintf(out, "%x %s %s %d %d\n", r, strconv.Quote(string(r)), strconv.QuoteRune(r),
///         b(unicode.IsPrint(r)), b(unicode.IsSpace(r)))
/// }
/// for c := 0x80; c <= 0xFF; c++ {
///     fmt.Fprintf(out, "%x %s %s\n", c, strconv.Quote(string([]byte{byte(c)})),
///         strconv.Quote(string([]byte{byte(c), 'a', 0xe2, 0x82})))
/// }
/// ```
const GO_FNV64A: u64 = 0x06e73bfed3cfa187;

fn dump() -> Vec<u8> {
    use std::fmt::Write;
    let mut s = String::with_capacity(40 << 20);
    for r in 0u32..=0x10FFFF {
        if (0xD800..=0xDFFF).contains(&r) {
            continue;
        }
        let c = char::from_u32(r).unwrap().to_string();
        let _ = writeln!(s, "{:x} {} {} {} {}", r, quote(&c), quote_rune(r), is_print(r) as u8, is_space(r) as u8);
    }
    for c in 0x80u32..=0xFF {
        let _ = writeln!(s, "{:x} {} {}", c, quote_bytes(&[c as u8]), quote_bytes(&[c as u8, b'a', 0xe2, 0x82]));
    }
    s.into_bytes()
}

#[test]
fn same_as_go() {
    let d = dump();
    if let Some(p) = std::env::var_os("GOSTR_DUMP") {
        std::fs::write(p, &d).unwrap();
    }
    let mut h: u64 = 0xcbf29ce484222325;
    for &b in &d {
        h ^= b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    assert_eq!(h, GO_FNV64A, "the dump differs from Go's (write it with GOSTR_DUMP=path and diff)");
}
