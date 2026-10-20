// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Derived from Go's src/strconv/quote.go, src/unicode/utf8/utf8.go, src/unicode/graphic.go and src/strings/strings.go
// (TrimSpace), Copyright The Go Authors, under the BSD-3-Clause licence in rust/LICENSE-GO; the rest is Apache-2.0.

//! Go's string semantics, for texts that must read as rhobound-cli's: `strconv.Quote` (the `%q` verb),
//! `strconv.QuoteRune`, `strconv.IsPrint` / `unicode.IsPrint` with Go's own tables (src/isprint.rs, generated
//! from Go 1.27.2's strconv/isprint.go by scripts/gen_isprint.py), `unicode.IsSpace`, `utf8.DecodeRune`, and the
//! replacement of invalid UTF-8 that Go's JSON encoder does (each byte that does not start a valid sequence
//! becomes U+FFFD).
//!
//! A Go string is any sequence of bytes, so these functions take bytes: an argument or a file name that is not
//! UTF-8 is quoted as Go quotes it (`\xff`).
//!
//! The quoting code follows Go's src/strconv/quote.go: Copyright 2009 The Go Authors. All rights reserved. Use
//! of this source code is governed by a BSD-style license (rust/LICENSE-GO).

mod isprint;

use isprint::{IS_GRAPHIC, IS_NOT_PRINT_16, IS_NOT_PRINT_32, IS_PRINT_16, IS_PRINT_32};

/// utf8.RuneError.
pub const RUNE_ERROR: u32 = 0xFFFD;

const LOWERHEX: &[u8; 16] = b"0123456789abcdef";

/// utf8.DecodeRune: the first rune of `b` and its width; (RUNE_ERROR, 1) for a byte that does not start a valid
/// sequence (an invalid, overlong, surrogate or truncated one), (RUNE_ERROR, 0) for no input.
pub fn decode_rune(b: &[u8]) -> (u32, usize) {
    let Some(&c0) = b.first() else {
        return (RUNE_ERROR, 0);
    };
    if c0 < 0x80 {
        return (c0 as u32, 1);
    }
    let need = match c0 {
        0xC2..=0xDF => 2,
        0xE0..=0xEF => 3,
        0xF0..=0xF4 => 4,
        _ => return (RUNE_ERROR, 1),
    };
    if b.len() < need {
        return (RUNE_ERROR, 1);
    }
    // Rust's UTF-8 rules are Go's: no overlong forms, no surrogates, nothing above U+10FFFF
    match std::str::from_utf8(&b[..need]) {
        Ok(s) => (s.chars().next().map_or(RUNE_ERROR, |c| c as u32), need),
        Err(_) => (RUNE_ERROR, 1),
    }
}

/// utf8.ValidRune.
pub fn valid_rune(r: u32) -> bool {
    r < 0xD800 || (0xE000..=0x10FFFF).contains(&r)
}

/// slices.BinarySearch as strconv's bsearch: the first index whose value is >= v, and whether it is v.
fn bsearch<T: PartialOrd + Copy>(s: &[T], v: T) -> (usize, bool) {
    let (mut i, mut j) = (0usize, s.len());
    while i < j {
        let h = i + (j - i) / 2;
        if s[h] < v {
            i = h + 1;
        } else {
            j = h;
        }
    }
    (i, i < s.len() && s[i] == v)
}

/// strconv.IsPrint (the same answers as unicode.IsPrint): letters, marks, numbers, punctuation, symbols and the
/// ASCII space, as Go 1.27's Unicode tables have them.
pub fn is_print(r: u32) -> bool {
    if r <= 0xFF {
        if (0x20..=0x7E).contains(&r) {
            return true;
        }
        if (0xA1..=0xFF).contains(&r) {
            return r != 0xAD;
        }
        return false;
    }
    if r < 1 << 16 {
        let rr = r as u16;
        let (i, _) = bsearch(&IS_PRINT_16, rr);
        if i >= IS_PRINT_16.len() || rr < IS_PRINT_16[i & !1] || IS_PRINT_16[i | 1] < rr {
            return false;
        }
        let (_, found) = bsearch(&IS_NOT_PRINT_16, rr);
        return !found;
    }
    let (i, _) = bsearch(&IS_PRINT_32, r);
    if i >= IS_PRINT_32.len() || r < IS_PRINT_32[i & !1] || IS_PRINT_32[i | 1] < r {
        return false;
    }
    if r >= 0x20000 {
        return true;
    }
    let (_, found) = bsearch(&IS_NOT_PRINT_32, (r - 0x10000) as u16);
    !found
}

/// strconv.IsGraphic: IsPrint, or one of the graphic spaces (category Zs).
pub fn is_graphic(r: u32) -> bool {
    is_print(r) || (r <= 0xFFFF && bsearch(&IS_GRAPHIC, r as u16).1)
}

/// unicode.IsSpace.
pub fn is_space(r: u32) -> bool {
    matches!(
        r,
        0x09..=0x0D | 0x20 | 0x85 | 0xA0 | 0x1680 | 0x2000..=0x200A | 0x2028 | 0x2029 | 0x202F | 0x205F | 0x3000
    )
}

/// strings.TrimSpace on a Go string: leading and trailing runes for which unicode.IsSpace holds (a byte that
/// does not start a valid UTF-8 sequence is not space).
pub fn trim_space(b: &[u8]) -> &[u8] {
    let mut s = b;
    while let Some(&c) = s.first() {
        if c < 0x80 {
            if !is_space(c as u32) {
                break;
            }
            s = &s[1..];
            continue;
        }
        let (r, w) = decode_rune(s);
        if (r == RUNE_ERROR && w == 1) || !is_space(r) {
            break;
        }
        s = &s[w..];
    }
    // from the end: find the start of the last rune (utf8.DecodeLastRune)
    while let Some(&c) = s.last() {
        if c < 0x80 {
            if !is_space(c as u32) {
                break;
            }
            s = &s[..s.len() - 1];
            continue;
        }
        let (r, w) = decode_last_rune(s);
        if (r == RUNE_ERROR && w == 1) || !is_space(r) {
            break;
        }
        s = &s[..s.len() - w];
    }
    s
}

/// utf8.DecodeLastRune: the last rune of `b` and its width; (RUNE_ERROR, 1) for an invalid ending.
pub fn decode_last_rune(b: &[u8]) -> (u32, usize) {
    let n = b.len();
    if n == 0 {
        return (RUNE_ERROR, 0);
    }
    if b[n - 1] < 0x80 {
        return (b[n - 1] as u32, 1);
    }
    // back up over at most 3 continuation bytes to a start byte, then decode forward from there
    let lim = n.saturating_sub(4);
    let mut start = n - 1;
    while start > lim {
        if b[start] & 0xC0 != 0x80 {
            break;
        }
        start -= 1;
    }
    let (r, w) = decode_rune(&b[start..n]);
    if start + w != n {
        return (RUNE_ERROR, 1);
    }
    (r, w)
}

/// strconv's appendEscapedRune (not ASCII-only, not graphic-only).
pub fn push_escaped_rune(out: &mut String, r: u32, quote: u8) {
    if r == quote as u32 || r == '\\' as u32 {
        out.push('\\');
        out.push(r as u8 as char);
        return;
    }
    if is_print(r) {
        if let Some(c) = char::from_u32(r) {
            out.push(c);
            return;
        }
    }
    match r {
        7 => out.push_str("\\a"),
        8 => out.push_str("\\b"),
        12 => out.push_str("\\f"),
        10 => out.push_str("\\n"),
        13 => out.push_str("\\r"),
        9 => out.push_str("\\t"),
        11 => out.push_str("\\v"),
        _ if r < 0x20 || r == 0x7F => {
            out.push_str("\\x");
            out.push(LOWERHEX[(r >> 4) as usize & 15] as char);
            out.push(LOWERHEX[r as usize & 15] as char);
        }
        _ => {
            let r = if valid_rune(r) { r } else { RUNE_ERROR };
            if r < 0x10000 {
                out.push_str("\\u");
                for s in (0..=12).rev().step_by(4) {
                    out.push(LOWERHEX[(r >> s) as usize & 15] as char);
                }
            } else {
                out.push_str("\\U");
                for s in (0..=28).rev().step_by(4) {
                    out.push(LOWERHEX[(r >> s) as usize & 15] as char);
                }
            }
        }
    }
}

/// strconv.Quote of a Go string (any bytes): `"..."` with Go's escapes; a byte that does not start a valid
/// UTF-8 sequence is written `\xNN`.
pub fn quote_bytes(b: &[u8]) -> String {
    let mut out = String::with_capacity(b.len() + 2);
    out.push('"');
    let mut i = 0;
    while i < b.len() {
        let (r, w) = decode_rune(&b[i..]);
        if w == 1 && r == RUNE_ERROR {
            out.push_str("\\x");
            out.push(LOWERHEX[(b[i] >> 4) as usize] as char);
            out.push(LOWERHEX[(b[i] & 15) as usize] as char);
            i += 1;
            continue;
        }
        push_escaped_rune(&mut out, r, b'"');
        i += w;
    }
    out.push('"');
    out
}

/// strconv.Quote (the `%q` verb on a string).
pub fn quote(s: &str) -> String {
    quote_bytes(s.as_bytes())
}

/// strconv.QuoteRune: `'x'` with Go's escapes (an invalid rune as U+FFFD).
pub fn quote_rune(r: u32) -> String {
    let r = if valid_rune(r) { r } else { RUNE_ERROR };
    let mut out = String::from("'");
    push_escaped_rune(&mut out, r, b'\'');
    out.push('\'');
    out
}

/// A Go string as valid UTF-8 the way Go's encoders make it: each byte that does not start a valid UTF-8
/// sequence becomes U+FFFD (Rust's `from_utf8_lossy` replaces a whole invalid or truncated sequence with one).
pub fn lossy(b: &[u8]) -> String {
    match std::str::from_utf8(b) {
        Ok(s) => s.to_string(),
        Err(_) => {
            let mut out = String::with_capacity(b.len() + 8);
            let mut i = 0;
            while i < b.len() {
                let (r, w) = decode_rune(&b[i..]);
                if w == 1 && r == RUNE_ERROR {
                    out.push('\u{FFFD}');
                    i += 1;
                } else {
                    // a valid sequence: copy its bytes
                    out.push_str(std::str::from_utf8(&b[i..i + w]).expect("a valid sequence"));
                    i += w;
                }
            }
            out
        }
    }
}

/// The bytes of an OS string (a path or an argument) as Go sees them.
#[cfg(unix)]
pub fn os_bytes(s: &std::ffi::OsStr) -> &[u8] {
    use std::os::unix::ffi::OsStrExt;
    s.as_bytes()
}

/// The OS string of Go string bytes (a path to open).
#[cfg(unix)]
pub fn bytes_os(b: &[u8]) -> &std::ffi::OsStr {
    use std::os::unix::ffi::OsStrExt;
    std::ffi::OsStr::from_bytes(b)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quotes() {
        assert_eq!(quote("a\"b\\c\n\t\u{7}\u{7f}"), "\"a\\\"b\\\\c\\n\\t\\a\\x7f\"");
        assert_eq!(quote_bytes(b"caf\xe9"), "\"caf\\xe9\"");
        assert_eq!(quote_bytes(b"\xe2\x82"), "\"\\xe2\\x82\"");
        assert_eq!(quote("\u{a0}\u{ad}\u{85}\u{2028}é"), "\"\\u00a0\\u00ad\\u0085\\u2028é\"");
        assert_eq!(quote("\u{e000}\u{10ffff}\u{e0001}\u{600}"), "\"\\ue000\\U0010ffff\\U000e0001\\u0600\"");
        assert_eq!(quote("\u{378}"), "\"\\u0378\""); // unassigned
        assert_eq!(quote("日本\u{1f600}"), "\"日本\u{1f600}\"");
        assert_eq!(quote_rune('\'' as u32), "'\\''");
        assert_eq!(quote_rune(0xD800), "'�'");
        assert_eq!(quote_rune(0x110000), "'�'");
    }

    #[test]
    fn lossy_per_byte() {
        assert_eq!(lossy(b"a\xf0\x9f\x98b"), "a\u{fffd}\u{fffd}\u{fffd}b");
        assert_eq!(lossy(b"caf\xc3\xa9"), "café");
        assert_eq!(lossy(b"\xed\xa0\x80"), "\u{fffd}\u{fffd}\u{fffd}"); // a surrogate
    }

    #[test]
    fn trims() {
        assert_eq!(trim_space(b" \t a b \n"), b"a b");
        assert_eq!(trim_space("\u{a0}\u{3000}x\u{2028}".as_bytes()), b"x");
        assert_eq!(trim_space(b" \xff "), b"\xff");
        assert_eq!(trim_space(b"\xe2\x80 "), b"\xe2\x80"); // a truncated sequence is not space
        assert_eq!(trim_space("\u{200b}x".as_bytes()), "\u{200b}x".as_bytes()); // U+200B is not White_Space
        assert_eq!(decode_last_rune("aé".as_bytes()), (0xe9, 2));
        assert_eq!(decode_last_rune(b"a\xa9"), (RUNE_ERROR, 1));
    }

    #[test]
    fn decode() {
        assert_eq!(decode_rune(b""), (RUNE_ERROR, 0));
        assert_eq!(decode_rune(b"\xc3\xa9x"), (0xe9, 2));
        assert_eq!(decode_rune(b"\xc0\x80"), (RUNE_ERROR, 1));
        assert_eq!(decode_rune(b"\xf4\x90\x80\x80"), (RUNE_ERROR, 1));
        assert_eq!(decode_rune(b"\xf0\x9f\x98\x80"), (0x1f600, 4));
    }
}
