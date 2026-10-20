// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Derived from Go's src/strconv/ftoa.go (the %e and %f layouts) and src/encoding/json/encode.go (the float64 form),
// Copyright The Go Authors, under the BSD-3-Clause licence in rust/LICENSE-GO; the rest is Apache-2.0.

//! Go's text forms of numbers and strings, so messages and JSON read as the Go binary writes them:
//! `%v` of a float64 (strconv 'g', shortest), `%q` of a string (strconv.Quote), and encoding/json's float and
//! string encodings. The shortest digits come from Rust's float formatting, which, like Go's, is the shortest
//! string that reads back to the same float64 (closest to the value when there are several).

/// The shortest round-trip decimal digits of a finite, non-zero |x| and its decimal exponent: x = 0.d1d2... x 10^dp.
fn shortest_digits(x: f64) -> (String, i32) {
    let s = format!("{:e}", x.abs()); // e.g. "1.2345e-7", "5e0"
    let (mant, exp) = s.split_once('e').expect("exponent form");
    let exp: i32 = exp.parse().expect("exponent");
    let digits: String = mant.chars().filter(|c| *c != '.').collect();
    let digits = digits.trim_end_matches('0').to_string();
    let digits = if digits.is_empty() {
        "0".to_string()
    } else {
        digits
    };
    (digits, exp + 1)
}

fn fmt_e(neg: bool, digits: &str, dp: i32) -> String {
    let mut out = String::new();
    if neg {
        out.push('-');
    }
    out.push_str(&digits[..1]);
    if digits.len() > 1 {
        out.push('.');
        out.push_str(&digits[1..]);
    }
    let e = dp - 1;
    out.push('e');
    out.push(if e < 0 { '-' } else { '+' });
    let ea = e.unsigned_abs();
    if ea < 10 {
        out.push('0');
    }
    out.push_str(&ea.to_string());
    out
}

fn fmt_f(neg: bool, digits: &str, dp: i32) -> String {
    let mut out = String::new();
    if neg {
        out.push('-');
    }
    let nd = digits.len() as i32;
    if dp <= 0 {
        out.push('0');
        out.push('.');
        for _ in 0..(-dp) {
            out.push('0');
        }
        out.push_str(digits);
    } else if dp >= nd {
        out.push_str(digits);
        for _ in 0..(dp - nd) {
            out.push('0');
        }
    } else {
        out.push_str(&digits[..dp as usize]);
        out.push('.');
        out.push_str(&digits[dp as usize..]);
    }
    out
}

/// Go's `%v` (and `%g`) of a float64: strconv.FormatFloat(x, 'g', -1, 64), with fmt's `+Inf`.
pub fn fmt_v(x: f64) -> String {
    if x.is_nan() {
        return "NaN".into();
    }
    if x.is_infinite() {
        return if x > 0.0 {
            "+Inf".into()
        } else {
            "-Inf".into()
        };
    }
    let neg = x.is_sign_negative();
    if x == 0.0 {
        return if neg { "-0".into() } else { "0".into() };
    }
    let (digits, dp) = shortest_digits(x);
    let exp = dp - 1;
    // strconv's 'g' with the shortest precision decides by eprec = 6: %e when the exponent is < -4 or >= 6
    if !(-4..6).contains(&exp) {
        fmt_e(neg, &digits, dp)
    } else {
        fmt_f(neg, &digits, dp)
    }
}

/// encoding/json's form of a float64 (finite only): 'f' unless |x| < 1e-6 or >= 1e21, then 'e' with the
/// exponent's leading zero dropped (`1e-07` -> `1e-7`).
pub fn json_float(x: f64) -> String {
    let neg = x.is_sign_negative();
    if x == 0.0 {
        return if neg { "-0".into() } else { "0".into() };
    }
    let (digits, dp) = shortest_digits(x);
    let a = x.abs();
    if a < 1e-6 || a >= 1e21 {
        let s = fmt_e(neg, &digits, dp);
        // clean up e-09 to e-9 (encoding/json only shortens a negative exponent)
        let b = s.as_bytes();
        let n = b.len();
        if n >= 4 && b[n - 4] == b'e' && b[n - 3] == b'-' && b[n - 2] == b'0' {
            let mut t = s[..n - 2].to_string();
            t.push(b[n - 1] as char);
            return t;
        }
        s
    } else {
        fmt_f(neg, &digits, dp)
    }
}

/// Go's `%q` of a string (strconv.Quote, with Go's IsPrint tables: rbfast-gostr).
pub fn quote(s: &str) -> String {
    rbfast_gostr::quote(s)
}

/// encoding/json's string encoding with HTML escaping (json.Marshal's default).
pub fn json_string(s: &str, out: &mut String) {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    out.push('"');
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '<' | '>' | '&' => {
                let b = c as u8;
                out.push_str("\\u00");
                out.push(HEX[(b >> 4) as usize] as char);
                out.push(HEX[(b & 15) as usize] as char);
            }
            c if (c as u32) < 0x20 => {
                let b = c as u8;
                out.push_str("\\u00");
                out.push(HEX[(b >> 4) as usize] as char);
                out.push(HEX[(b & 15) as usize] as char);
            }
            '\u{2028}' => out.push_str("\\u2028"),
            '\u{2029}' => out.push_str("\\u2029"),
            c => out.push(c),
        }
    }
    out.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn go_g_forms() {
        for (x, want) in [
            (1.0, "1"),
            (0.5, "0.5"),
            (1e6, "1e+06"),
            (123456.0, "123456"),
            (1234567.0, "1.234567e+06"),
            (1e-4, "0.0001"),
            (1e-5, "1e-05"),
            (-2.5e-7, "-2.5e-07"),
            (1e21, "1e+21"),
            (0.1 + 0.2, "0.30000000000000004"),
            (f64::INFINITY, "+Inf"),
            (f64::NEG_INFINITY, "-Inf"),
            (f64::NAN, "NaN"),
            (1e100, "1e+100"),
            (5e-324, "5e-324"),
        ] {
            assert_eq!(fmt_v(x), want, "{x:e}");
        }
    }

    #[test]
    fn go_json_floats() {
        for (x, want) in [
            (1.0, "1"),
            (1e20, "100000000000000000000"),
            (1e21, "1e+21"),
            (1e-6, "0.000001"),
            (1e-7, "1e-7"),
            (1.5e-10, "1.5e-10"),
            (0.03409090909090909, "0.03409090909090909"),
            (-0.0, "-0"),
        ] {
            assert_eq!(json_float(x), want, "{x:e}");
        }
    }

    #[test]
    fn go_quote() {
        assert_eq!(quote("a\"b\\c\n\u{1}é"), "\"a\\\"b\\\\c\\n\\x01é\"");
    }
}
