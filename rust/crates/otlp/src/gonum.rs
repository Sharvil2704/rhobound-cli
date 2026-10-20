// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Derived from Go's src/strconv/atof.go and src/strconv/atoi.go (special, underscoreOK, readFloat, atofHex, ParseUint),
// Copyright The Go Authors, under the BSD-3-Clause licence in rust/LICENSE-GO; the rest is Apache-2.0.

//! The timestamp rule of rhobound-cli's reader (`nanos.UnmarshalJSON`): strip `"` from both ends of the raw JSON
//! value, then `strconv.ParseUint(s, 10, 64)`, else `strconv.ParseFloat(s, 64)` converted with `uint64(f)` (as on
//! linux/arm64: saturating, NaN to 0), else the ParseUint error. These are ports of Go's strconv rules.

/// Result of reading one timestamp value.
pub(crate) enum Nanos {
    /// Nothing left after trimming the quotes: Go leaves the field as it was.
    Keep,
    Set(u64),
    /// The error text Go returns (unwrapped, as the reader reports it).
    Err(String),
}

/// Go's `bytes.Trim(b, "\"")`.
fn trim_quotes(mut b: &[u8]) -> &[u8] {
    while let [b'"', rest @ ..] = b {
        b = rest;
    }
    while let [rest @ .., b'"'] = b {
        b = rest;
    }
    b
}

enum UintErr {
    Syntax,
    Range,
}

/// strconv.ParseUint(s, 10, 64).
fn parse_uint10(s: &[u8]) -> Result<u64, UintErr> {
    if s.is_empty() {
        return Err(UintErr::Syntax);
    }
    const CUTOFF: u64 = u64::MAX / 10 + 1;
    let mut n: u64 = 0;
    for &c in s {
        if !c.is_ascii_digit() {
            return Err(UintErr::Syntax);
        }
        if n >= CUTOFF {
            return Err(UintErr::Range);
        }
        n *= 10;
        let n1 = n.wrapping_add((c - b'0') as u64);
        if n1 < n {
            return Err(UintErr::Range);
        }
        n = n1;
    }
    Ok(n)
}

#[inline]
fn lower(c: u8) -> u8 {
    c | 0x20
}

fn common_prefix_len_ignore_case(s: &[u8], prefix: &[u8]) -> usize {
    let mut n = 0;
    while n < s.len() && n < prefix.len() && lower(s[n]) == prefix[n] {
        n += 1;
    }
    n
}

/// strconv's special(): (value, bytes consumed).
fn special(s: &[u8]) -> Option<(f64, usize)> {
    if s.is_empty() {
        return None;
    }
    let (sign, nsign, rest) = match s[0] {
        b'+' => (1.0, 1, &s[1..]),
        b'-' => (-1.0, 1, &s[1..]),
        b'i' | b'I' => (1.0, 0, s),
        b'n' | b'N' => {
            if common_prefix_len_ignore_case(s, b"nan") == 3 {
                return Some((f64::NAN, 3));
            }
            return None;
        }
        _ => return None,
    };
    let mut n = common_prefix_len_ignore_case(rest, b"infinity");
    if 3 < n && n < 8 {
        n = 3;
    }
    if n == 3 || n == 8 {
        return Some((sign * f64::INFINITY, nsign + n));
    }
    None
}

/// strconv's underscoreOK.
fn underscore_ok(s: &[u8]) -> bool {
    let mut saw = b'^';
    let mut i = 0;
    let s = if !s.is_empty() && (s[0] == b'-' || s[0] == b'+') {
        &s[1..]
    } else {
        s
    };
    let mut hex = false;
    if s.len() >= 2 && s[0] == b'0' && matches!(lower(s[1]), b'b' | b'o' | b'x') {
        i = 2;
        saw = b'0';
        hex = lower(s[1]) == b'x';
    }
    while i < s.len() {
        let c = s[i];
        if c.is_ascii_digit() || (hex && (b'a'..=b'f').contains(&lower(c))) {
            saw = b'0';
        } else if c == b'_' {
            if saw != b'0' {
                return false;
            }
            saw = b'_';
        } else {
            if saw == b'_' {
                return false;
            }
            saw = b'!';
        }
        i += 1;
    }
    saw != b'_'
}

struct ReadFloat {
    mantissa: u64,
    exp: i64,
    neg: bool,
    trunc: bool,
    hex: bool,
    n: usize,
}

/// strconv's readFloat (syntax and, for hex, the mantissa and binary exponent).
fn read_float(s: &[u8]) -> Option<ReadFloat> {
    let mut i = 0;
    let mut underscores = false;
    let mut neg = false;
    if i >= s.len() {
        return None;
    }
    match s[i] {
        b'+' => i += 1,
        b'-' => {
            i += 1;
            neg = true
        }
        _ => {}
    }
    let mut base: u64 = 10;
    let mut max_mant_digits = 19;
    let mut exp_char = b'e';
    let mut hex = false;
    if i + 2 < s.len() && s[i] == b'0' && lower(s[i + 1]) == b'x' {
        base = 16;
        max_mant_digits = 16;
        i += 2;
        exp_char = b'p';
        hex = true;
    }
    let (mut sawdot, mut sawdigits) = (false, false);
    let (mut nd, mut nd_mant, mut dp) = (0i64, 0i64, 0i64);
    let mut mantissa: u64 = 0;
    let mut trunc = false;
    while i < s.len() {
        let c = s[i];
        if c == b'_' {
            underscores = true;
        } else if c == b'.' {
            if sawdot {
                break;
            }
            sawdot = true;
            dp = nd;
        } else if c.is_ascii_digit() {
            sawdigits = true;
            if c == b'0' && nd == 0 {
                dp -= 1;
                i += 1;
                continue;
            }
            nd += 1;
            if nd_mant < max_mant_digits {
                mantissa = mantissa.wrapping_mul(base).wrapping_add((c - b'0') as u64);
                nd_mant += 1;
            } else if c != b'0' {
                trunc = true;
            }
        } else if base == 16 && (b'a'..=b'f').contains(&lower(c)) {
            sawdigits = true;
            nd += 1;
            if nd_mant < max_mant_digits {
                mantissa = mantissa
                    .wrapping_mul(16)
                    .wrapping_add((lower(c) - b'a' + 10) as u64);
                nd_mant += 1;
            } else {
                trunc = true;
            }
        } else {
            break;
        }
        i += 1;
    }
    if !sawdigits {
        return None;
    }
    if !sawdot {
        dp = nd;
    }
    if base == 16 {
        dp *= 4;
        nd_mant *= 4;
    }
    if i < s.len() && lower(s[i]) == exp_char {
        i += 1;
        if i >= s.len() {
            return None;
        }
        let mut esign = 1;
        match s[i] {
            b'+' => i += 1,
            b'-' => {
                i += 1;
                esign = -1
            }
            _ => {}
        }
        if i >= s.len() || !s[i].is_ascii_digit() {
            return None;
        }
        let mut e: i64 = 0;
        while i < s.len() && (s[i].is_ascii_digit() || s[i] == b'_') {
            if s[i] == b'_' {
                underscores = true;
            } else if e < 10000 {
                e = e * 10 + (s[i] - b'0') as i64;
            }
            i += 1;
        }
        dp += e * esign;
    } else if base == 16 {
        return None;
    }
    let mut exp = 0;
    if mantissa != 0 {
        exp = dp - nd_mant;
    }
    if underscores && !underscore_ok(&s[..i]) {
        return None;
    }
    Some(ReadFloat {
        mantissa,
        exp,
        neg,
        trunc,
        hex,
        n: i,
    })
}

/// strconv's atofHex for float64: Some(value) or None on overflow (ErrRange).
fn atof_hex(mut mantissa: u64, mut exp: i64, neg: bool, trunc: bool) -> Option<f64> {
    const MANTBITS: i64 = 52;
    const EXPBITS: i64 = 11;
    const BIAS: i64 = -1023;
    let max_exp = (1 << EXPBITS) + BIAS - 2;
    let min_exp = BIAS + 1;
    exp += MANTBITS;
    while mantissa != 0 && mantissa >> (MANTBITS + 2) == 0 {
        mantissa <<= 1;
        exp -= 1;
    }
    if trunc {
        mantissa |= 1;
    }
    while mantissa >> (1 + MANTBITS + 2) != 0 {
        mantissa = mantissa >> 1 | mantissa & 1;
        exp += 1;
    }
    while mantissa > 1 && exp < min_exp - 2 {
        mantissa = mantissa >> 1 | mantissa & 1;
        exp += 1;
    }
    let mut round = mantissa & 3;
    mantissa >>= 2;
    round |= mantissa & 1;
    exp += 2;
    if round == 3 {
        mantissa += 1;
        if mantissa == 1 << (1 + MANTBITS) {
            mantissa >>= 1;
            exp += 1;
        }
    }
    if mantissa >> MANTBITS == 0 {
        exp = BIAS;
    }
    if exp > max_exp {
        return None;
    }
    let mut bits = mantissa & ((1 << MANTBITS) - 1);
    bits |= (((exp - BIAS) & ((1 << EXPBITS) - 1)) as u64) << MANTBITS;
    if neg {
        bits |= 1 << 63;
    }
    Some(f64::from_bits(bits))
}

/// strconv.ParseFloat(s, 64): Some(value), or None for a syntax or range error.
pub(crate) fn go_parse_float(s: &[u8]) -> Option<f64> {
    if let Some((v, n)) = special(s) {
        return if n == s.len() { Some(v) } else { None };
    }
    let rf = read_float(s)?;
    if rf.n != s.len() {
        return None;
    }
    if rf.hex {
        return atof_hex(rf.mantissa, rf.exp, rf.neg, rf.trunc);
    }
    // Decimal: Go's result is correctly rounded, and so is Rust's parser; the syntax was checked above (Rust
    // accepts every such string once the underscores are gone).
    let clean: String = s
        .iter()
        .filter(|&&c| c != b'_')
        .map(|&c| c as char)
        .collect();
    let v: f64 = clean.parse().ok()?;
    if v.is_infinite() {
        return None; // ErrRange
    }
    Some(v)
}

/// The reader's timestamp rule on a raw JSON value (any type: Go hands the raw bytes to UnmarshalJSON).
pub(crate) fn nanos(raw: &[u8]) -> Nanos {
    let t = trim_quotes(raw);
    if t.is_empty() {
        return Nanos::Keep;
    }
    match parse_uint10(t) {
        Ok(v) => Nanos::Set(v),
        Err(e) => match go_parse_float(t) {
            // uint64(f) on arm64 (FCVTZU): saturating, NaN to 0; Rust's `as` does the same.
            Some(f) => Nanos::Set(f as u64),
            None => Nanos::Err(format!(
                "strconv.ParseUint: parsing {}: {}",
                crate::json::go_quote(t),
                match e {
                    UintErr::Syntax => "invalid syntax",
                    UintErr::Range => "value out of range",
                }
            )),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(s: &str) -> Option<u64> {
        match nanos(s.as_bytes()) {
            Nanos::Set(v) => Some(v),
            Nanos::Keep => Some(u64::MAX - 1),
            Nanos::Err(_) => None,
        }
    }

    #[test]
    fn go_probe_values() {
        // values Go 1.27.2 gave on linux/arm64 (probed with a Go program made for the comparison)
        assert_eq!(v("\"1.7e18\""), Some(1_700_000_000_000_000_000));
        assert_eq!(v("\"+5\""), Some(5));
        assert_eq!(v("\"1_000\""), Some(1000));
        assert_eq!(v("\"0x1p4\""), Some(16));
        assert_eq!(v("\"0x10\""), None);
        assert_eq!(v("\"Inf\""), Some(u64::MAX));
        assert_eq!(v("\"infinity\""), Some(u64::MAX));
        assert_eq!(v("\"-inf\""), Some(0));
        assert_eq!(v("\"NaN\""), Some(0));
        assert_eq!(v("\"+nan\""), None);
        assert_eq!(v("\"-5\""), Some(0));
        assert_eq!(v("\"\""), Some(u64::MAX - 1));
        assert_eq!(v("\" 5\""), None);
        assert_eq!(v("true"), None);
        assert_eq!(v("{}"), None);
        assert_eq!(v("\"18446744073709551616\""), Some(u64::MAX));
        assert_eq!(v("\"1e400\""), None);
        assert_eq!(v("\"1e-400\""), Some(0));
        assert_eq!(v("1700000000000000000.7"), Some(1_700_000_000_000_000_000));
        assert_eq!(v("\"5.5e2\""), Some(550));
        assert_eq!(v("\".5\""), Some(0));
        assert_eq!(v("\"5.\""), Some(5));
        assert_eq!(v("\"1e\""), None);
        assert_eq!(v("-0"), Some(0));
        assert_eq!(v("\"00012\""), Some(12));
        assert_eq!(v("\"1__0\""), None);
        assert_eq!(v("\"_10\""), None);
        assert_eq!(v("\"0x_1p4\""), Some(16));
        assert_eq!(v("\"0b101\""), None);
        assert_eq!(v("\"1E2\""), Some(100));
        assert_eq!(v("\"inFINity\""), Some(u64::MAX));
        assert_eq!(v("\"infin\""), None);
        assert_eq!(v("null"), None);
    }

    #[test]
    fn error_text() {
        match nanos(b"null") {
            Nanos::Err(e) => assert_eq!(e, "strconv.ParseUint: parsing \"null\": invalid syntax"),
            _ => panic!(),
        }
        let big = format!("\"1{}\"", "0".repeat(400));
        match nanos(big.as_bytes()) {
            Nanos::Err(e) => assert!(e.ends_with("\": value out of range"), "{e}"),
            _ => panic!(),
        }
    }
}
