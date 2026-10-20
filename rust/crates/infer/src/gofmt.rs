// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Derived from Go's src/strconv/ftoa.go (the %e, %f and %g layouts), Copyright The Go Authors, under the BSD-3-Clause
// licence in rust/LICENSE-GO; the rest is Apache-2.0.

//! Go's float layouts, so that warnings, errors and JSON read as rhobound-cli's do: the `fmt` verbs the
//! inference uses (`%.Nf`, `%.Ng`, `%v`, `%q`) and `encoding/json`'s float64 form.
//!
//! Rust's `{:.N}` and `{:.Ne}` round the exact binary value to nearest, ties to even, as Go's strconv does; the
//! digit layout (when `%g` switches to the exponent form, the two-digit exponent, the trimmed zeros) is Go's
//! `fmtEFG`, ported here.

/// NaN and the infinities as Go's fmt prints them (`%f`, `%g`, `%v` alike).
fn special(x: f64) -> Option<String> {
    if x.is_nan() {
        Some("NaN".to_string())
    } else if x == f64::INFINITY {
        Some("+Inf".to_string())
    } else if x == f64::NEG_INFINITY {
        Some("-Inf".to_string())
    } else {
        None
    }
}

/// `%.{prec}f`.
pub fn f(x: f64, prec: usize) -> String {
    if let Some(s) = special(x) {
        return s;
    }
    format!("{:.*}", prec, x)
}

/// Splits Rust's `{:e}` form ("1.2345e-7") into the decimal digits without trailing zeros and the decimal
/// point position (Go's digs.d, digs.dp): the value is 0.d1d2... x 10^dp.
fn sci_digits(s: &str) -> (Vec<u8>, i32) {
    let (m, e) = s.split_once('e').expect("exponent form");
    let e: i32 = e.parse().expect("exponent");
    let mut d: Vec<u8> = m.bytes().filter(|c| c.is_ascii_digit()).collect();
    while d.last() == Some(&b'0') {
        d.pop();
    }
    if d.is_empty() {
        return (d, 0);
    }
    (d, e + 1)
}

/// `%.{prec}g`.
pub fn g(x: f64, prec: usize) -> String {
    if let Some(s) = special(x) {
        return s;
    }
    let prec = prec.max(1);
    let neg = x.is_sign_negative();
    let a = x.abs();
    let (digs, dp) = if a == 0.0 { (Vec::new(), 0) } else { sci_digits(&format!("{:.*e}", prec - 1, a)) };
    efg(neg, &digs, dp, prec as i32, false)
}

/// `%v` (and `%g`) of a float64: the shortest digits that read back as the same value.
pub fn v(x: f64) -> String {
    if let Some(s) = special(x) {
        return s;
    }
    let neg = x.is_sign_negative();
    let a = x.abs();
    let (digs, dp) = if a == 0.0 { (Vec::new(), 0) } else { shortest(a) };
    let nd = digs.len() as i32;
    efg(neg, &digs, dp, nd, true)
}

/// The shortest decimal digits that read back as a (finite, > 0), and the decimal point position. Rust's
/// shortest form and Go's agree except when a lies exactly halfway between the two closest candidates of that
/// length: Go takes the even one, Rust the upper one (seen on values near 1e15 with 17 digits), so a tie is
/// detected on the exact expansion and settled as Go does.
fn shortest(a: f64) -> (Vec<u8>, i32) {
    let (d, dp) = sci_digits(&format!("{:e}", a));
    let n = d.len();
    // a tie needs an exact expansion of n + 1 digits ending in 5: first a cheap look at the (n+1)th digit
    let next = format!("{:.*e}", n, a);
    let (m, _) = next.split_once('e').expect("exponent form");
    if !m.ends_with('5') {
        return (d, dp);
    }
    let (exact, edp) = sci_digits(&format!("{:.1100e}", a));
    if exact.len() != n + 1 || exact[n] != b'5' || edp != dp && edp != dp - 1 {
        return (d, dp);
    }
    let mut base: Vec<u8> = exact[..n].to_vec();
    let mut bdp = edp;
    if (base[n - 1] - b'0') % 2 == 1 {
        // round up to the even neighbour
        let mut i = n;
        loop {
            if i == 0 {
                base.insert(0, b'1');
                bdp += 1;
                break;
            }
            i -= 1;
            if base[i] == b'9' {
                base[i] = b'0';
            } else {
                base[i] += 1;
                break;
            }
        }
    }
    while base.last() == Some(&b'0') {
        base.pop();
    }
    (base, bdp)
}

/// Go's fmtEFG for the 'g' verb: the 'e' form when the exponent is below -4 or at least the precision (6 for
/// the shortest form), else the 'f' form; trailing zeros are not printed.
fn efg(neg: bool, s: &[u8], dp: i32, prec: i32, shortest: bool) -> String {
    let nd = s.len() as i32;
    let mut eprec = prec;
    if eprec > nd && nd >= dp {
        eprec = nd;
    }
    if shortest {
        eprec = 6;
    }
    let exp = dp - 1;
    if exp < -4 || exp >= eprec {
        let mut p = prec;
        if p > nd {
            p = nd;
        }
        fmt_e(neg, s, dp, p - 1)
    } else {
        let mut p = prec;
        if p > dp {
            p = nd;
        }
        fmt_f(neg, s, dp, (p - dp).max(0))
    }
}

/// Go's %e layout of the digits s (0.s x 10^dp) with prec digits after the point.
fn fmt_e(neg: bool, s: &[u8], dp: i32, prec: i32) -> String {
    let nd = s.len() as i32;
    let mut out = String::new();
    if neg {
        out.push('-');
    }
    out.push(if nd != 0 { s[0] as char } else { '0' });
    if prec > 0 {
        out.push('.');
        let mut i = 1;
        let m = nd.min(prec + 1);
        if i < m {
            for &c in &s[i as usize..m as usize] {
                out.push(c as char);
            }
            i = m;
        }
        for _ in 0..(prec + 1 - i) {
            out.push('0');
        }
    }
    out.push('e');
    let mut exp = dp - 1;
    if nd == 0 {
        exp = 0;
    }
    if exp < 0 {
        out.push('-');
        exp = -exp;
    } else {
        out.push('+');
    }
    if exp < 10 {
        out.push('0');
        out.push((b'0' + exp as u8) as char);
    } else if exp < 100 {
        out.push((b'0' + (exp / 10) as u8) as char);
        out.push((b'0' + (exp % 10) as u8) as char);
    } else {
        out.push((b'0' + (exp / 100) as u8) as char);
        out.push((b'0' + ((exp / 10) % 10) as u8) as char);
        out.push((b'0' + (exp % 10) as u8) as char);
    }
    out
}

/// Go's %f layout of the digits s (0.s x 10^dp) with prec digits after the point.
fn fmt_f(neg: bool, s: &[u8], dp: i32, prec: i32) -> String {
    let nd = s.len() as i32;
    let mut out = String::new();
    if neg {
        out.push('-');
    }
    if dp > 0 {
        let m = nd.min(dp);
        for &c in &s[..m as usize] {
            out.push(c as char);
        }
        for _ in m..dp {
            out.push('0');
        }
    } else {
        out.push('0');
    }
    if prec > 0 {
        out.push('.');
        for i in 1..=prec {
            let j = dp + i - 1;
            out.push(if 0 <= j && j < nd { s[j as usize] as char } else { '0' });
        }
    }
    out
}

/// encoding/json's float64: the shortest digits, in the 'e' form below 1e-6 and from 1e21 (exponent without a
/// leading zero), else the 'f' form. None for NaN and the infinities, which Go's encoder refuses.
pub fn json_num(x: f64) -> Option<String> {
    if !x.is_finite() {
        return None;
    }
    let mut out = String::new();
    if x.is_sign_negative() {
        out.push('-');
    }
    let a = x.abs();
    if a == 0.0 {
        out.push('0');
        return Some(out);
    }
    let (d, dp) = shortest(a);
    let nd = d.len() as i32;
    if a < 1e-6 || a >= 1e21 {
        out.push(d[0] as char);
        if nd > 1 {
            out.push('.');
            for &c in &d[1..] {
                out.push(c as char);
            }
        }
        let e = dp - 1;
        out.push('e');
        out.push(if e < 0 { '-' } else { '+' });
        out.push_str(&e.abs().to_string());
    } else if dp <= 0 {
        out.push_str("0.");
        for _ in 0..-dp {
            out.push('0');
        }
        for &c in &d {
            out.push(c as char);
        }
    } else if dp >= nd {
        for &c in &d {
            out.push(c as char);
        }
        for _ in nd..dp {
            out.push('0');
        }
    } else {
        for (i, &c) in d.iter().enumerate() {
            if i as i32 == dp {
                out.push('.');
            }
            out.push(c as char);
        }
    }
    Some(out)
}

/// `%q` of a string: Go's strconv.Quote (with Go's IsPrint tables: rbfast-gostr).
pub fn quote(s: &str) -> String {
    rbfast_gostr::quote(s)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layouts() {
        assert_eq!(g(1.0, 3), "1");
        assert_eq!(g(1234.0, 3), "1.23e+03");
        assert_eq!(g(100.0, 3), "100");
        assert_eq!(g(0.5, 3), "0.5");
        assert_eq!(g(0.000123456, 3), "0.000123");
        assert_eq!(g(1e-5, 3), "1e-05");
        assert_eq!(g(0.0, 3), "0");
        assert_eq!(g(3e-7, 1), "3e-07");
        assert_eq!(v(1234567.0), "1.234567e+06");
        assert_eq!(v(123456.0), "123456");
        assert_eq!(v(0.5), "0.5");
        assert_eq!(v(1e-5), "1e-05");
        assert_eq!(v(f64::NAN), "NaN");
        assert_eq!(f(0.125, 2), "0.12");
        assert_eq!(f(2.5, 0), "2");
        assert_eq!(json_num(1e21).unwrap(), "1e+21");
        assert_eq!(json_num(1.4566126083082054e-13).unwrap(), "1.4566126083082054e-13");
        assert_eq!(json_num(0.000012804130218313503).unwrap(), "0.000012804130218313503");
        assert_eq!(json_num(1.0).unwrap(), "1");
        assert_eq!(quote("a\"b"), "\"a\\\"b\"");
    }
}
