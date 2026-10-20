// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Derived from Go's src/flag/flag.go (parseOne), Copyright The Go Authors, under the BSD-3-Clause licence in
// rust/LICENSE-GO; the rest is Apache-2.0.

//! Go's `flag` package as cmd/rhobound uses it: a FlagSet with ContinueOnError and its output discarded, and
//! `parseInterleaved`, which lets flags follow the positional arguments. Ported from Go 1.27's flag.go
//! (`parseOne`): `-name` and `--name`, `-name=value`, `-name value` (not for booleans), `--` ends the flags (and
//! cmd/rhobound's loop then resumes after the next positional argument), `-h`/`-help` are errors when not
//! defined. Every error is just an error here: cmd/rhobound prints its usage line for any of them.
//!
//! Arguments are Go strings: any bytes (an argument that is not UTF-8 is kept as it is, so that a path opens
//! and an error quotes it as Go does).

use std::collections::BTreeMap;

use rbfast_math::model::parse_go_float;

#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Str(Vec<u8>),
    Float(f64),
    Bool(bool),
    /// a non-negative integer (rbfast's own flags, such as --threads)
    Count(usize),
}

/// A set of defined flags with their current values.
#[derive(Clone, Debug, Default)]
pub struct FlagSet {
    values: BTreeMap<&'static str, Value>,
    /// the flags set on the command line (Go's `actual`)
    set: BTreeMap<&'static str, ()>,
}

impl FlagSet {
    pub fn new() -> FlagSet {
        FlagSet::default()
    }

    pub fn define(&mut self, name: &'static str, default: Value) {
        self.values.insert(name, default);
    }

    /// A string flag's bytes.
    pub fn bytes(&self, name: &str) -> &[u8] {
        match self.values.get(name) {
            Some(Value::Str(s)) => s,
            _ => panic!("flag {name} is not a string flag"),
        }
    }

    pub fn float(&self, name: &str) -> f64 {
        match self.values.get(name) {
            Some(Value::Float(x)) => *x,
            _ => panic!("flag {name} is not a float flag"),
        }
    }

    pub fn bool(&self, name: &str) -> bool {
        match self.values.get(name) {
            Some(Value::Bool(b)) => *b,
            _ => panic!("flag {name} is not a bool flag"),
        }
    }

    pub fn count(&self, name: &str) -> usize {
        match self.values.get(name) {
            Some(Value::Count(n)) => *n,
            _ => panic!("flag {name} is not a count flag"),
        }
    }

    /// Whether the flag was given (Go's FlagSet.Visit); names in lexicographical order, as Visit has them.
    pub fn was_set(&self, name: &str) -> bool {
        self.set.contains_key(name)
    }

    /// cmd/rhobound's parseInterleaved: the positional arguments, with flags allowed anywhere.
    pub fn parse_interleaved(&mut self, args: &[Vec<u8>]) -> Result<Vec<Vec<u8>>, String> {
        let mut pos = Vec::new();
        let mut args: Vec<Vec<u8>> = args.to_vec();
        loop {
            let rest = self.parse(args)?;
            if rest.is_empty() {
                return Ok(pos);
            }
            pos.push(rest[0].clone());
            args = rest[1..].to_vec();
        }
    }

    /// FlagSet.Parse: parses flags up to the first non-flag argument; returns the remaining arguments.
    fn parse(&mut self, mut args: Vec<Vec<u8>>) -> Result<Vec<Vec<u8>>, String> {
        loop {
            match self.parse_one(&mut args)? {
                true => continue,
                false => return Ok(args),
            }
        }
    }

    fn parse_one(&mut self, args: &mut Vec<Vec<u8>>) -> Result<bool, String> {
        if args.is_empty() {
            return Ok(false);
        }
        let s = args[0].clone();
        let b = &s[..];
        if b.len() < 2 || b[0] != b'-' {
            return Ok(false);
        }
        let mut minuses = 1;
        if b[1] == b'-' {
            minuses += 1;
            if b.len() == 2 {
                // "--" terminates the flags
                args.remove(0);
                return Ok(false);
            }
        }
        let mut name = s[minuses..].to_vec();
        if name.is_empty() || name[0] == b'-' || name[0] == b'=' {
            return Err(format!("bad flag syntax: {}", String::from_utf8_lossy(&s)));
        }
        args.remove(0);
        let mut value: Vec<u8> = Vec::new();
        let mut has_value = false;
        if let Some(i) = name[1..].iter().position(|&c| c == b'=') {
            let i = i + 1;
            value = name[i + 1..].to_vec();
            has_value = true;
            name.truncate(i);
        }
        let key = match self.values.keys().find(|k| k.as_bytes() == name.as_slice()) {
            Some(k) => *k,
            None => {
                if name == b"help" || name == b"h" {
                    return Err("flag: help requested".to_string());
                }
                return Err(format!("flag provided but not defined: -{}", String::from_utf8_lossy(&name)));
            }
        };
        let cur = self.values.get(key).cloned().expect("defined");
        let name = String::from_utf8_lossy(&name).into_owned();
        let text = std::str::from_utf8(&value).ok();
        let new = match cur {
            Value::Bool(_) => {
                if has_value {
                    Value::Bool(text.and_then(parse_bool).ok_or_else(|| {
                        format!("invalid boolean value {:?} for -{name}: parse error", String::from_utf8_lossy(&value))
                    })?)
                } else {
                    Value::Bool(true)
                }
            }
            other => {
                if !has_value && !args.is_empty() {
                    value = args.remove(0);
                    has_value = true;
                }
                if !has_value {
                    return Err(format!("flag needs an argument: -{name}"));
                }
                let text = std::str::from_utf8(&value).ok();
                let bad =
                    || format!("invalid value {:?} for flag -{name}: parse error", String::from_utf8_lossy(&value));
                match other {
                    Value::Str(_) => Value::Str(value.clone()),
                    Value::Float(_) => Value::Float(text.and_then(parse_go_float).ok_or_else(bad)?),
                    Value::Count(_) => Value::Count(text.and_then(|t| t.parse::<usize>().ok()).ok_or_else(bad)?),
                    Value::Bool(_) => unreachable!(),
                }
            }
        };
        self.values.insert(key, new);
        self.set.insert(key, ());
        Ok(true)
    }
}

/// strconv.ParseBool.
fn parse_bool(s: &str) -> Option<bool> {
    match s {
        "1" | "t" | "T" | "TRUE" | "true" | "True" => Some(true),
        "0" | "f" | "F" | "FALSE" | "false" | "False" => Some(false),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn set() -> FlagSet {
        let mut f = FlagSet::new();
        f.define("patch", Value::Str(Vec::new()));
        f.define("max-rho", Value::Float(0.85));
        f.define("json", Value::Bool(false));
        f
    }

    fn args(a: &[&str]) -> Vec<Vec<u8>> {
        a.iter().map(|s| s.as_bytes().to_vec()).collect()
    }

    fn strs(v: Vec<Vec<u8>>) -> Vec<String> {
        v.into_iter().map(|b| String::from_utf8(b).unwrap()).collect()
    }

    #[test]
    fn interleaved() {
        let mut f = set();
        let pos = f.parse_interleaved(&args(&["cap", "--json", "--patch", "b=+1ms", "-max-rho=0.5"])).unwrap();
        assert_eq!(strs(pos), vec!["cap"]);
        assert!(f.bool("json"));
        assert_eq!(f.bytes("patch"), b"b=+1ms");
        assert_eq!(f.float("max-rho"), 0.5);
        assert!(f.was_set("patch") && !set().was_set("patch"));
    }

    #[test]
    fn go_rules() {
        assert!(set().parse_interleaved(&args(&["cap", "--nosuch"])).is_err());
        assert!(set().parse_interleaved(&args(&["cap", "-h"])).is_err());
        assert!(set().parse_interleaved(&args(&["cap", "--patch"])).is_err());
        assert!(set().parse_interleaved(&args(&["cap", "---x"])).is_err());
        assert!(set().parse_interleaved(&args(&["cap", "--json=maybe"])).is_err());
        assert!(set().parse_interleaved(&args(&["cap", "--max-rho", "x"])).is_err());
        let mut f = set();
        assert!(f.parse_interleaved(&args(&["cap", "--max-rho", "NaN"])).is_ok());
        assert!(f.float("max-rho").is_nan());
        // a bool flag does not take the next argument: "false" is a second positional
        let mut f = set();
        assert_eq!(strs(f.parse_interleaved(&args(&["--json", "false", "cap"])).unwrap()), vec!["false", "cap"]);
        // "--" ends the flags: the next argument is positional, flags resume after it
        let mut f = set();
        assert_eq!(strs(f.parse_interleaved(&args(&["--", "--json", "--patch", "x"])).unwrap()), vec!["--json"]);
        assert_eq!(f.bytes("patch"), b"x");
        // "-" alone is positional
        assert_eq!(strs(set().parse_interleaved(&args(&["-"])).unwrap()), vec!["-"]);
        // any bytes: a value that is not UTF-8 is kept as it is; as a number it does not parse
        let mut f = set();
        let a = vec![b"--patch".to_vec(), b"\xff=+1ms".to_vec(), b"c\xe9".to_vec()];
        assert_eq!(f.parse_interleaved(&a).unwrap(), vec![b"c\xe9".to_vec()]);
        assert_eq!(f.bytes("patch"), b"\xff=+1ms");
        assert!(set().parse_interleaved(&[b"--max-rho=0.5\xff".to_vec()]).is_err());
    }
}
