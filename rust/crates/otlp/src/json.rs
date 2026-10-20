// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Derived from Go's src/encoding/json/jsontext (the syntax rules and error texts), Copyright The Go Authors, under the
// BSD-3-Clause licence in rust/LICENSE-GO; the rest is Apache-2.0.

//! JSON scanning with the syntax rules and error texts of Go's `encoding/json` as rhobound-cli's reader sees it
//! (Go 1.27: the v1 API implemented over `encoding/json/v2` with the v1 options: invalid UTF-8 allowed and
//! replaced, duplicate names allowed, case-insensitive names, a nesting limit of 10000).
//!
//! Every function here works on one in-memory document `b` and a byte position. Errors are [`SynErr`]: either an
//! unexpected end of input (whose text depends on the caller: `unexpected end of JSON input` for `json.Unmarshal`,
//! `unexpected EOF` for a `json.Decoder` stream) or a message as Go writes it.

/// Go's maximum nesting depth (jsontext `maxNestingDepth`).
pub(crate) const MAX_DEPTH: usize = 10000;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum SynErr {
    Eof,
    Msg(String),
}

pub(crate) type SR<T> = Result<T, SynErr>;

#[inline(always)]
pub(crate) fn is_ws(c: u8) -> bool {
    c == b' ' || c == b'\t' || c == b'\n' || c == b'\r'
}

/// Skips JSON whitespace from `i`.
#[inline(always)]
pub(crate) fn skip_ws(b: &[u8], mut i: usize) -> usize {
    while i < b.len() && is_ws(b[i]) {
        i += 1;
    }
    i
}

/// `invalid character 'x' <where>` (Go's InvalidTextError for one character, after the v1 rewording).
pub(crate) fn invalid_char(b: &[u8], at: usize, where_: &str) -> SynErr {
    SynErr::Msg(format!(
        "invalid character {} {}",
        quote_rune_at(&b[at..]),
        where_
    ))
}

pub(crate) const W_VALUE: &str = "looking for beginning of value";
pub(crate) const W_KEY: &str = "looking for beginning of object key string";
pub(crate) const W_COLON: &str = "after object key";
pub(crate) const W_OBJ_NEXT: &str = "after object key:value pair";
pub(crate) const W_ARR_NEXT: &str = "after array element";
pub(crate) const W_NUMBER: &str = "in numeric literal";
pub(crate) const W_STRING: &str = "in string";
pub(crate) const W_TOP: &str = "after top-level value";

fn depth_err() -> SynErr {
    SynErr::Msg("exceeded max depth".to_string())
}

#[inline(always)]
pub(crate) fn check_depth(d: usize) -> SR<()> {
    if d > MAX_DEPTH {
        Err(depth_err())
    } else {
        Ok(())
    }
}

// ------------------------------------------------------------------ strings

const ONES: u64 = 0x0101_0101_0101_0101;
const HIGH: u64 = 0x8080_8080_8080_8080;

/// Bytes that end a fast run inside a string: `"`, `\`, a control character, and (when `stop_high`) any byte
/// >= 0x80. The lowest set bit of the mask marks the first such byte exactly (borrows only propagate upward).
#[inline(always)]
fn special_mask(w: u64, stop_high: bool) -> u64 {
    let q = w ^ (ONES * b'"' as u64);
    let s = w ^ (ONES * b'\\' as u64);
    let has_q = q.wrapping_sub(ONES) & !q & HIGH;
    let has_s = s.wrapping_sub(ONES) & !s & HIGH;
    let has_ctl = w.wrapping_sub(ONES * 0x20) & !w & HIGH;
    let mut m = has_q | has_s | has_ctl;
    if stop_high {
        m |= w & HIGH;
    }
    m
}

/// Advances `i` over bytes that need no attention inside a string; stops at the first `"`, `\`, control
/// character, or (when `stop_high`) non-ASCII byte, or at the end of `b`.
#[inline(always)]
pub(crate) fn scan_plain(b: &[u8], mut i: usize, stop_high: bool) -> usize {
    while i + 8 <= b.len() {
        let w = u64::from_le_bytes(b[i..i + 8].try_into().unwrap());
        let m = special_mask(w, stop_high);
        if m != 0 {
            return i + (m.trailing_zeros() / 8) as usize;
        }
        i += 8;
    }
    while i < b.len() {
        let c = b[i];
        if c == b'"' || c == b'\\' || c < 0x20 || (stop_high && c >= 0x80) {
            return i;
        }
        i += 1;
    }
    i
}

#[inline(always)]
fn hexval(c: u8) -> Option<u16> {
    match c {
        b'0'..=b'9' => Some((c - b'0') as u16),
        b'a'..=b'f' => Some((c - b'a' + 10) as u16),
        b'A'..=b'F' => Some((c - b'A' + 10) as u16),
        _ => None,
    }
}

fn parse_hex4(b: &[u8]) -> Option<u16> {
    let mut v = 0u16;
    for &c in &b[..4] {
        v = v << 4 | hexval(c)?;
    }
    Some(v)
}

/// jsonwire.hasEscapedUTF16Prefix: whether `b` may be the truncated prefix of a `\uXXXX` escape.
fn has_escaped_utf16_prefix(b: &[u8], lower_half: bool) -> bool {
    for (i, &c) in b.iter().enumerate() {
        if i == 0 && c != b'\\' {
            return false;
        }
        if i == 1 && c != b'u' {
            return false;
        }
        if i == 2 && lower_half && c != b'd' && c != b'D' {
            return false;
        }
        if i == 3 && lower_half && !(b'c'..=b'f').contains(&c) && !(b'C'..=b'F').contains(&c) {
            return false;
        }
        if (2..6).contains(&i) && hexval(c).is_none() {
            return false;
        }
    }
    true
}

fn invalid_escape(what: &[u8]) -> SynErr {
    SynErr::Msg(format!(
        "invalid escape sequence {} in string",
        quote_text(what)
    ))
}

/// Validates the escape sequence at `b[i] == '\\'` as Go's ConsumeString does (surrogates are not paired here:
/// with invalid UTF-8 allowed, Go does not check them). Returns the position after it.
#[inline]
fn check_escape(b: &[u8], i: usize) -> SR<usize> {
    if i + 2 > b.len() {
        return Err(SynErr::Eof);
    }
    match b[i + 1] {
        b'"' | b'\\' | b'/' | b'b' | b'f' | b'n' | b'r' | b't' => Ok(i + 2),
        b'u' => {
            if i + 6 > b.len() {
                if has_escaped_utf16_prefix(&b[i..], false) {
                    return Err(SynErr::Eof);
                }
                return Err(invalid_escape(&b[i..]));
            }
            if parse_hex4(&b[i + 2..i + 6]).is_none() {
                return Err(invalid_escape(&b[i..i + 6]));
            }
            Ok(i + 6)
        }
        _ => Err(invalid_escape(&b[i..i + 2])),
    }
}

/// Skips (and validates) the string starting at `b[i] == '"'`; returns the position after its closing quote.
pub(crate) fn skip_string(b: &[u8], i: usize) -> SR<usize> {
    let mut j = i + 1;
    loop {
        j = scan_plain(b, j, false);
        if j >= b.len() {
            return Err(SynErr::Eof);
        }
        match b[j] {
            b'"' => return Ok(j + 1),
            b'\\' => j = check_escape(b, j)?,
            _ => return Err(invalid_char(b, j, W_STRING)),
        }
    }
}

/// A decoded string: a range of the document, or (when `esc`) of the decoder's side buffer. Its bytes are what
/// Go's string would hold: escapes resolved, invalid UTF-8 replaced by U+FFFD byte by byte, lone surrogates by
/// U+FFFD.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct S {
    pub start: u32,
    pub len: u32,
    pub esc: bool,
}

impl S {
    #[inline(always)]
    pub fn get<'x>(&self, doc: &'x [u8], esc: &'x [u8]) -> &'x [u8] {
        let src = if self.esc { esc } else { doc };
        &src[self.start as usize..(self.start + self.len) as usize]
    }
    #[inline(always)]
    pub fn is_empty(&self) -> bool {
        self.len == 0
    }
}

/// Appends `src` to `dst` with every invalid UTF-8 byte replaced by U+FFFD, one per byte, as Go's
/// utf8.DecodeRune walk does.
pub(crate) fn push_go_utf8(dst: &mut Vec<u8>, mut src: &[u8]) {
    loop {
        match std::str::from_utf8(src) {
            Ok(_) => {
                dst.extend_from_slice(src);
                return;
            }
            Err(e) => {
                let ok = e.valid_up_to();
                dst.extend_from_slice(&src[..ok]);
                dst.extend_from_slice("\u{FFFD}".as_bytes());
                src = &src[ok + 1..];
            }
        }
    }
}

fn push_rune(dst: &mut Vec<u8>, r: u32) {
    let c = char::from_u32(r).unwrap_or('\u{FFFD}');
    let mut buf = [0u8; 4];
    dst.extend_from_slice(c.encode_utf8(&mut buf).as_bytes());
}

/// Reads the string at `b[i] == '"'` with Go's semantics. Returns the decoded string and the position after the
/// closing quote. Strings that need no change are borrowed from the document; the others go to `esc`.
#[inline]
pub(crate) fn read_string(b: &[u8], i: usize, esc: &mut Vec<u8>) -> SR<(S, usize)> {
    let start = i + 1;
    let j = scan_plain(b, start, true);
    if j < b.len() && b[j] == b'"' {
        return Ok((
            S {
                start: start as u32,
                len: (j - start) as u32,
                esc: false,
            },
            j + 1,
        ));
    }
    read_string_slow(b, start, j, esc)
}

#[cold]
fn read_string_slow(b: &[u8], start: usize, mut j: usize, esc: &mut Vec<u8>) -> SR<(S, usize)> {
    // First pass: find the end and whether anything but non-ASCII bytes needs work.
    let mut has_escape = false;
    loop {
        j = scan_plain(b, j, false);
        if j >= b.len() {
            return Err(SynErr::Eof);
        }
        match b[j] {
            b'"' => break,
            b'\\' => {
                has_escape = true;
                j = check_escape(b, j)?;
            }
            _ => return Err(invalid_char(b, j, W_STRING)),
        }
    }
    let end = j; // the closing quote
    let raw = &b[start..end];
    if !has_escape && std::str::from_utf8(raw).is_ok() {
        return Ok((
            S {
                start: start as u32,
                len: (end - start) as u32,
                esc: false,
            },
            end + 1,
        ));
    }
    // Second pass: unescape (the string is known to be well formed up to `end`).
    let s0 = esc.len();
    let mut k = 0;
    let mut run = 0;
    while k < raw.len() {
        if raw[k] != b'\\' {
            k += 1;
            continue;
        }
        push_go_utf8(esc, &raw[run..k]);
        match raw[k + 1] {
            b'"' => esc.push(b'"'),
            b'\\' => esc.push(b'\\'),
            b'/' => esc.push(b'/'),
            b'b' => esc.push(8),
            b'f' => esc.push(12),
            b'n' => esc.push(b'\n'),
            b'r' => esc.push(b'\r'),
            b't' => esc.push(b'\t'),
            _ => {
                // \uXXXX (validated)
                let v1 = parse_hex4(&raw[k + 2..k + 6]).unwrap() as u32;
                k += 6;
                if (0xD800..0xE000).contains(&v1) {
                    let mut r = 0xFFFD;
                    // a following \uYYYY inside the string (the closing quote counts as inside, as in Go)
                    if k + 6 <= raw.len() + 1
                        && k + 1 < raw.len()
                        && raw[k] == b'\\'
                        && raw[k + 1] == b'u'
                    {
                        if let Some(v2) = raw.get(k + 2..k + 6).and_then(parse_hex4) {
                            let v2 = v2 as u32;
                            if (0xD800..0xDC00).contains(&v1) && (0xDC00..0xE000).contains(&v2) {
                                r = 0x10000 + ((v1 - 0xD800) << 10) + (v2 - 0xDC00);
                                k += 6;
                            }
                        }
                    }
                    push_rune(esc, r);
                } else {
                    push_rune(esc, v1);
                }
                run = k;
                continue;
            }
        }
        k += 2;
        run = k;
    }
    push_go_utf8(esc, &raw[run..]);
    Ok((
        S {
            start: s0 as u32,
            len: (esc.len() - s0) as u32,
            esc: true,
        },
        end + 1,
    ))
}

// ------------------------------------------------------------------ numbers and literals

/// Validates the number at `b[i]` (a '-' or a digit); returns its end.
#[inline]
pub(crate) fn skip_number(b: &[u8], mut i: usize) -> SR<usize> {
    if b[i] == b'-' {
        i += 1;
    }
    if i >= b.len() {
        return Err(SynErr::Eof);
    }
    match b[i] {
        b'0' => i += 1,
        b'1'..=b'9' => {
            i += 1;
            while i < b.len() && b[i].is_ascii_digit() {
                i += 1;
            }
        }
        _ => return Err(invalid_char(b, i, W_NUMBER)),
    }
    if i < b.len() && b[i] == b'.' {
        i += 1;
        if i >= b.len() {
            return Err(SynErr::Eof);
        }
        if !b[i].is_ascii_digit() {
            return Err(invalid_char(b, i, W_NUMBER));
        }
        while i < b.len() && b[i].is_ascii_digit() {
            i += 1;
        }
    }
    if i < b.len() && (b[i] == b'e' || b[i] == b'E') {
        i += 1;
        if i < b.len() && (b[i] == b'+' || b[i] == b'-') {
            i += 1;
        }
        if i >= b.len() {
            return Err(SynErr::Eof);
        }
        if !b[i].is_ascii_digit() {
            return Err(invalid_char(b, i, W_NUMBER));
        }
        while i < b.len() && b[i].is_ascii_digit() {
            i += 1;
        }
    }
    Ok(i)
}

/// Validates the literal `lit` (true, false, null) at `b[i]`; returns its end.
#[inline]
pub(crate) fn skip_literal(b: &[u8], i: usize, lit: &'static [u8]) -> SR<usize> {
    if b.len() >= i + lit.len() && &b[i..i + lit.len()] == lit {
        return Ok(i + lit.len());
    }
    for (k, &c) in lit.iter().enumerate() {
        if i + k >= b.len() {
            return Err(SynErr::Eof);
        }
        if b[i + k] != c {
            let name = std::str::from_utf8(lit).unwrap();
            return Err(invalid_char(
                b,
                i + k,
                &format!("in literal {} (expecting {})", name, quote_rune(c as u32)),
            ));
        }
    }
    unreachable!()
}

/// What a JSON value starting with `c` is, in Go's UnmarshalTypeError words.
pub(crate) fn kind_word(c: u8) -> &'static str {
    match c {
        b'"' => "string",
        b'{' => "object",
        b'[' => "array",
        b't' | b'f' => "bool",
        b'n' => "null",
        _ => "number",
    }
}

/// Skips (and validates) one value starting at or after `i` (whitespace first). `depth` is the nesting depth of
/// the container that holds the value (0 at the top level). `stack` is scratch space.
pub(crate) fn skip_value(b: &[u8], i: usize, depth: usize, stack: &mut Vec<bool>) -> SR<usize> {
    stack.clear();
    let mut i = skip_ws(b, i);
    'value: loop {
        if i >= b.len() {
            return Err(SynErr::Eof);
        }
        match b[i] {
            b'{' => {
                check_depth(depth + stack.len() + 1)?;
                i = skip_ws(b, i + 1);
                if i >= b.len() {
                    return Err(SynErr::Eof);
                }
                if b[i] == b'}' {
                    i += 1;
                } else {
                    if b[i] != b'"' {
                        return Err(invalid_char(b, i, W_KEY));
                    }
                    stack.push(true);
                    i = skip_string(b, i)?;
                    i = skip_ws(b, i);
                    if i >= b.len() {
                        return Err(SynErr::Eof);
                    }
                    if b[i] != b':' {
                        return Err(invalid_char(b, i, W_COLON));
                    }
                    i = skip_ws(b, i + 1);
                    continue 'value;
                }
            }
            b'[' => {
                check_depth(depth + stack.len() + 1)?;
                i = skip_ws(b, i + 1);
                if i >= b.len() {
                    return Err(SynErr::Eof);
                }
                if b[i] == b']' {
                    i += 1;
                } else {
                    stack.push(false);
                    continue 'value;
                }
            }
            b'"' => i = skip_string(b, i)?,
            b't' => i = skip_literal(b, i, b"true")?,
            b'f' => i = skip_literal(b, i, b"false")?,
            b'n' => i = skip_literal(b, i, b"null")?,
            b'-' | b'0'..=b'9' => i = skip_number(b, i)?,
            _ => return Err(invalid_char(b, i, W_VALUE)),
        }
        // after a complete value
        loop {
            let Some(&in_obj) = stack.last() else {
                return Ok(i);
            };
            i = skip_ws(b, i);
            if i >= b.len() {
                return Err(SynErr::Eof);
            }
            let c = b[i];
            if in_obj {
                if c == b',' {
                    i = skip_ws(b, i + 1);
                    if i >= b.len() {
                        return Err(SynErr::Eof);
                    }
                    if b[i] != b'"' {
                        return Err(invalid_char(b, i, W_KEY));
                    }
                    i = skip_string(b, i)?;
                    i = skip_ws(b, i);
                    if i >= b.len() {
                        return Err(SynErr::Eof);
                    }
                    if b[i] != b':' {
                        return Err(invalid_char(b, i, W_COLON));
                    }
                    i = skip_ws(b, i + 1);
                    continue 'value;
                } else if c == b'}' {
                    stack.pop();
                    i += 1;
                } else {
                    return Err(invalid_char(b, i, W_OBJ_NEXT));
                }
            } else if c == b',' {
                i = skip_ws(b, i + 1);
                continue 'value;
            } else if c == b']' {
                stack.pop();
                i += 1;
            } else {
                return Err(invalid_char(b, i, W_ARR_NEXT));
            }
        }
    }
}

// ------------------------------------------------------------------ Go's text quoting (for error messages)

use rbfast_gostr::{decode_rune, is_print, is_space as is_go_space};

/// strconv.QuoteRune.
pub(crate) fn quote_rune(r: u32) -> String {
    rbfast_gostr::quote_rune(r)
}

/// jsonwire.QuoteRune: the first rune of `b` quoted, or `'\xNN'` for an invalid byte.
pub(crate) fn quote_rune_at(b: &[u8]) -> String {
    let (r, w) = decode_rune(b);
    if r == 0xFFFD && w == 1 {
        return format!("'\\x{:x}'", b[0]);
    }
    quote_rune(r)
}

/// strconv.Quote of a byte string (invalid UTF-8 bytes as `\xNN`).
pub(crate) fn go_quote(b: &[u8]) -> String {
    rbfast_gostr::quote_bytes(b)
}

/// jsonwire.InvalidTextError's rendering of the offending text: one rune quoted as a rune, text that needs
/// escaping Go-quoted, anything else in backquotes.
fn quote_text(b: &[u8]) -> String {
    let mut runes = 0;
    let mut need_escape = false;
    let mut i = 0;
    while i < b.len() {
        let (r, w) = decode_rune(&b[i..]);
        runes += 1;
        if r == '`' as u32 || r == 0xFFFD || is_go_space(r) || !is_print(r) {
            need_escape = true;
        }
        i += w.max(1);
    }
    if runes == 1 {
        quote_rune_at(b)
    } else if need_escape {
        go_quote(b)
    } else {
        format!("`{}`", String::from_utf8_lossy(b))
    }
}

/// bytes.TrimSpace's notion of a blank line: only Unicode white space (invalid UTF-8 is not space).
pub(crate) fn is_blank(b: &[u8]) -> bool {
    let mut i = 0;
    while i < b.len() {
        let c = b[i];
        if c < 0x80 {
            if !matches!(c, b'\t' | b'\n' | 0x0B | 0x0C | b'\r' | b' ') {
                return false;
            }
            i += 1;
            continue;
        }
        let (r, w) = decode_rune(&b[i..]);
        if (r == 0xFFFD && w == 1) || !is_go_space(r) {
            return false;
        }
        i += w;
    }
    true
}

/// strings.TrimSpace (Unicode white space) on valid UTF-8.
pub(crate) fn trim_space(s: &str) -> &str {
    s.trim_matches(|c: char| is_go_space(c as u32))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mask_finds_first() {
        let b = b"abcdefgh\"ijk";
        assert_eq!(scan_plain(b, 0, true), 8);
        let b = b"ab\x01cd\"";
        assert_eq!(scan_plain(b, 0, true), 2);
        let b = "abcdeé\"".as_bytes();
        assert_eq!(scan_plain(b, 0, true), 5);
        assert_eq!(scan_plain(b, 0, false), 7);
        let b = b"\\aaaaaaaaaaaaaaa";
        assert_eq!(scan_plain(b, 0, false), 0);
        for n in 0..40 {
            let mut v = vec![b'a'; n];
            v.push(b'"');
            v.extend_from_slice(b"zzzzzzzzzz");
            assert_eq!(scan_plain(&v, 0, true), n);
        }
    }

    #[test]
    fn go_replacement_per_byte() {
        let mut out = Vec::new();
        push_go_utf8(&mut out, b"a\xe2\x82b");
        assert_eq!(out, "a\u{FFFD}\u{FFFD}b".as_bytes());
        out.clear();
        push_go_utf8(&mut out, b"a\xf0\x9f\x98");
        assert_eq!(out, "a\u{FFFD}\u{FFFD}\u{FFFD}".as_bytes());
    }

    #[test]
    fn quoting() {
        assert_eq!(quote_rune_at(b"\t"), "'\\t'");
        assert_eq!(quote_rune_at(b"\xff"), "'\\xff'");
        assert_eq!(quote_rune_at("\u{a0}".as_bytes()), "'\\u00a0'");
        assert_eq!(quote_rune_at("é".as_bytes()), "'é'");
        assert_eq!(quote_rune_at(b"'"), "'\\''");
        assert_eq!(go_quote("a\\tbé\u{0}".as_bytes()), "\"a\\\\tbé\\x00\"");
        assert_eq!(go_quote(b"\xff"), "\"\\xff\"");
    }
}
