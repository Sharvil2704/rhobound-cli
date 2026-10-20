// SPDX-License-Identifier: Apache-2.0

//! The topology JSON schema: [`parse_topology`] reads what Go's `model.ParseTopology` reads, with Go's
//! encoding/json semantics where they matter (keys matched case-insensitively, the last duplicate winning, a
//! duplicated `entry` object merging, `null` leaving a field at its zero value, `cs2` absent or null meaning 1,
//! a type mismatch failing the parse, with Go 1.27's error text), and [`marshal_topology`] writes the bytes Go's
//! `model.MarshalTopology` writes (json.MarshalIndent, two spaces, sorted entry keys, Go's float and string
//! encodings).
//!
//! The document is read by a small JSON reader that keeps every number's literal text (Go's type errors quote
//! it: `cannot unmarshal number 2.5 into ... of type int`) and decodes strings as Go does (invalid UTF-8 bytes
//! become U+FFFD one by one). Numbers become float64 correctly rounded, as Go's strconv rounds them. A syntax
//! error is reported as "invalid JSON" (with the `oracle` feature, in serde_json's words); the CLI checks the
//! syntax with Go's texts first.

use crate::gofmt::{json_float, json_string, quote};
use crate::model::{Call, ModelError, Service, Topology};
use std::collections::{BTreeMap, HashMap};

/// A JSON value with its object keys in document order and numbers as their literal text.
#[derive(Clone, Debug, PartialEq)]
enum JVal {
    Null,
    Bool(bool),
    Num(String),
    Str(String),
    Arr(Vec<JVal>),
    Obj(Vec<(String, JVal)>),
}

impl JVal {
    fn kind(&self) -> &'static str {
        match self {
            JVal::Null => "null",
            JVal::Bool(_) => "bool",
            JVal::Num(_) => "number",
            JVal::Str(_) => "string",
            JVal::Arr(_) => "array",
            JVal::Obj(_) => "object",
        }
    }
}

/// Reads one JSON document; None on any syntax error.
struct Reader<'a> {
    b: &'a [u8],
    i: usize,
}

impl Reader<'_> {
    fn ws(&mut self) {
        while self.i < self.b.len() && matches!(self.b[self.i], b' ' | b'\t' | b'\n' | b'\r') {
            self.i += 1;
        }
    }

    fn doc(b: &[u8]) -> Option<JVal> {
        let mut r = Reader { b, i: 0 };
        let v = r.value(0)?;
        r.ws();
        (r.i == b.len()).then_some(v)
    }

    fn lit(&mut self, word: &[u8], v: JVal) -> Option<JVal> {
        if self.b[self.i..].starts_with(word) {
            self.i += word.len();
            Some(v)
        } else {
            None
        }
    }

    fn value(&mut self, depth: usize) -> Option<JVal> {
        if depth > 10000 {
            return None;
        }
        self.ws();
        match *self.b.get(self.i)? {
            b'{' => {
                self.i += 1;
                let mut o = Vec::new();
                self.ws();
                if self.b.get(self.i) == Some(&b'}') {
                    self.i += 1;
                    return Some(JVal::Obj(o));
                }
                loop {
                    self.ws();
                    if self.b.get(self.i) != Some(&b'"') {
                        return None;
                    }
                    let k = self.string()?;
                    self.ws();
                    if self.b.get(self.i) != Some(&b':') {
                        return None;
                    }
                    self.i += 1;
                    let v = self.value(depth + 1)?;
                    o.push((k, v));
                    self.ws();
                    match self.b.get(self.i)? {
                        b',' => self.i += 1,
                        b'}' => {
                            self.i += 1;
                            return Some(JVal::Obj(o));
                        }
                        _ => return None,
                    }
                }
            }
            b'[' => {
                self.i += 1;
                let mut a = Vec::new();
                self.ws();
                if self.b.get(self.i) == Some(&b']') {
                    self.i += 1;
                    return Some(JVal::Arr(a));
                }
                loop {
                    a.push(self.value(depth + 1)?);
                    self.ws();
                    match self.b.get(self.i)? {
                        b',' => self.i += 1,
                        b']' => {
                            self.i += 1;
                            return Some(JVal::Arr(a));
                        }
                        _ => return None,
                    }
                }
            }
            b'"' => self.string().map(JVal::Str),
            b't' => self.lit(b"true", JVal::Bool(true)),
            b'f' => self.lit(b"false", JVal::Bool(false)),
            b'n' => self.lit(b"null", JVal::Null),
            b'-' | b'0'..=b'9' => self.number(),
            _ => None,
        }
    }

    fn digits(&mut self) -> usize {
        let s = self.i;
        while self.i < self.b.len() && self.b[self.i].is_ascii_digit() {
            self.i += 1;
        }
        self.i - s
    }

    fn number(&mut self) -> Option<JVal> {
        let s = self.i;
        if self.b[self.i] == b'-' {
            self.i += 1;
        }
        match self.b.get(self.i)? {
            b'0' => self.i += 1,
            b'1'..=b'9' => {
                self.digits();
            }
            _ => return None,
        }
        if self.b.get(self.i) == Some(&b'.') {
            self.i += 1;
            if self.digits() == 0 {
                return None;
            }
        }
        if matches!(self.b.get(self.i), Some(b'e') | Some(b'E')) {
            self.i += 1;
            if matches!(self.b.get(self.i), Some(b'+') | Some(b'-')) {
                self.i += 1;
            }
            if self.digits() == 0 {
                return None;
            }
        }
        Some(JVal::Num(
            String::from_utf8(self.b[s..self.i].to_vec()).ok()?,
        ))
    }

    fn hex4(&mut self) -> Option<u32> {
        let h = std::str::from_utf8(self.b.get(self.i..self.i + 4)?).ok()?;
        let v = u32::from_str_radix(h, 16).ok()?;
        if !h.bytes().all(|c| c.is_ascii_hexdigit()) {
            return None;
        }
        self.i += 4;
        Some(v)
    }

    /// A string at `"`, decoded as Go decodes it: escapes (an unpaired surrogate is U+FFFD), and each byte of
    /// invalid UTF-8 replaced by U+FFFD (Go's utf8.DecodeRune steps one byte on an invalid sequence).
    fn string(&mut self) -> Option<String> {
        self.i += 1;
        let mut out = String::new();
        loop {
            let c = *self.b.get(self.i)?;
            match c {
                b'"' => {
                    self.i += 1;
                    return Some(out);
                }
                b'\\' => {
                    self.i += 1;
                    let e = *self.b.get(self.i)?;
                    self.i += 1;
                    match e {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\u{8}'),
                        b'f' => out.push('\u{c}'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => {
                            let u = self.hex4()?;
                            if (0xD800..0xDC00).contains(&u) {
                                // a high surrogate: a pair only with a low one right after it
                                if self.b.get(self.i..self.i + 2) == Some(b"\\u") {
                                    let save = self.i;
                                    self.i += 2;
                                    let l = self.hex4()?;
                                    if (0xDC00..0xE000).contains(&l) {
                                        let cp = 0x10000 + ((u - 0xD800) << 10) + (l - 0xDC00);
                                        out.push(char::from_u32(cp).unwrap_or('\u{fffd}'));
                                        continue;
                                    }
                                    self.i = save;
                                }
                                out.push('\u{fffd}');
                            } else {
                                out.push(char::from_u32(u).unwrap_or('\u{fffd}'));
                            }
                        }
                        _ => return None,
                    }
                }
                0..=0x1f => return None,
                0x20..=0x7f => {
                    out.push(c as char);
                    self.i += 1;
                }
                _ => {
                    let n = go_rune_len(&self.b[self.i..]);
                    match n {
                        Some(n) => {
                            out.push_str(std::str::from_utf8(&self.b[self.i..self.i + n]).ok()?);
                            self.i += n;
                        }
                        None => {
                            out.push('\u{fffd}');
                            self.i += 1;
                        }
                    }
                }
            }
        }
    }
}

/// The length of the valid UTF-8 sequence at the start of `b` (its first byte >= 0x80), as Go's
/// utf8.DecodeRune accepts it; None when it is invalid.
fn go_rune_len(b: &[u8]) -> Option<usize> {
    let c0 = b[0];
    let (n, lo, hi) = match c0 {
        0xC2..=0xDF => (2, 0x80, 0xBF),
        0xE0 => (3, 0xA0, 0xBF),
        0xE1..=0xEC | 0xEE..=0xEF => (3, 0x80, 0xBF),
        0xED => (3, 0x80, 0x9F),
        0xF0 => (4, 0x90, 0xBF),
        0xF1..=0xF3 => (4, 0x80, 0xBF),
        0xF4 => (4, 0x80, 0x8F),
        _ => return None,
    };
    if b.len() < n || !(lo..=hi).contains(&b[1]) {
        return None;
    }
    if b[2..n].iter().any(|&c| !(0x80..=0xBF).contains(&c)) {
        return None;
    }
    Some(n)
}

/// Where a value sits, for Go 1.27's UnmarshalTypeError text: `fileTopology.` and the JSON path (member names
/// as the document spells them, array indices); `member` when its last step is a member name (then Go writes
/// "Go struct field PATH", else just "PATH"). An empty path is the document itself.
#[derive(Clone, Copy)]
struct At<'a> {
    path: &'a str,
    member: bool,
}

/// Go's type-mismatch text. `value` is the JSON kind word, or "number LITERAL" for a number that does not fit
/// the numeric type.
fn mismatch(value: &str, at: At, ty: &str) -> ModelError {
    if at.path.is_empty() {
        return ModelError(format!(
            "json: cannot unmarshal {value} into Go value of type {ty}"
        ));
    }
    let field = if at.member { "Go struct field " } else { "" };
    ModelError(format!(
        "json: cannot unmarshal {value} into {field}{} of type {ty}",
        at.path
    ))
}

fn type_err(v: &JVal, at: At, ty: &str) -> ModelError {
    mismatch(v.kind(), at, ty)
}

/// encoding/json's key folding: ASCII letters to upper case, and the two non-ASCII runes that fold into ASCII
/// letters (U+017F long s, U+212A Kelvin sign).
fn fold(key: &str) -> String {
    key.chars()
        .map(|c| match c {
            '\u{17f}' => 'S',
            '\u{212a}' => 'K',
            c => c.to_ascii_uppercase(),
        })
        .collect()
}

/// Which of `fields` a key sets: the exact name, else a case-insensitive match (Go's rule).
fn field_of<'a>(key: &str, fields: &[&'a str]) -> Option<&'a str> {
    if let Some(f) = fields.iter().find(|f| **f == key) {
        return Some(f);
    }
    let k = fold(key);
    fields.iter().find(|f| fold(f) == k).copied()
}

fn get_f64(v: &JVal, at: At) -> Result<Option<f64>, ModelError> {
    match v {
        JVal::Null => Ok(None),
        JVal::Num(lit) => match lit.parse::<f64>() {
            Ok(x) if x.is_finite() => Ok(Some(x)),
            _ => Err(mismatch(&format!("number {lit}"), at, "float64")),
        },
        _ => Err(type_err(v, at, "float64")),
    }
}

fn get_int(v: &JVal, at: At) -> Result<Option<i64>, ModelError> {
    match v {
        JVal::Null => Ok(None),
        // strconv.ParseInt(literal, 10, 64): no fraction, no exponent, in range ("-0" is 0)
        JVal::Num(lit) => match lit.parse::<i64>() {
            Ok(i) => Ok(Some(i)),
            Err(_) => Err(mismatch(&format!("number {lit}"), at, "int")),
        },
        _ => Err(type_err(v, at, "int")),
    }
}

fn get_bool(v: &JVal, at: At) -> Result<Option<bool>, ModelError> {
    match v {
        JVal::Null => Ok(None),
        JVal::Bool(b) => Ok(Some(*b)),
        _ => Err(type_err(v, at, "bool")),
    }
}

fn get_str(v: &JVal, at: At) -> Result<Option<String>, ModelError> {
    match v {
        JVal::Null => Ok(None),
        JVal::Str(s) => Ok(Some(s.clone())),
        _ => Err(type_err(v, at, "string")),
    }
}

/// Go's fileService.
#[derive(Default)]
struct FileService {
    name: String,
    s: f64,
    children: Vec<JVal>,
    parallel: bool,
    servers: i64,
    workers: i64,
    cs2: Option<f64>,
    routing: String,
    delay: bool,
    hop: f64,
    branch_corr: f64,
    glue: f64,
    glue_cs2: f64,
    shares: Option<Vec<f64>>,
    hold: bool,
    own_slots: Option<i64>,
}

const SERVICE_FIELDS: [&str; 16] = [
    "name",
    "s",
    "children",
    "parallel",
    "servers",
    "workers",
    "cs2",
    "routing",
    "delay",
    "hop",
    "branch_corr",
    "glue",
    "glue_cs2",
    "shares",
    "hold",
    "own_slots",
];

/// Element `i` of the services array, at `base` (`fileTopology.<services key>`).
fn file_service(v: &JVal, base: &str, i: usize) -> Result<FileService, ModelError> {
    let mut fs = FileService::default();
    let elem = format!("{base}.{i}");
    let obj = match v {
        JVal::Null => return Ok(fs),
        JVal::Obj(o) => o,
        _ => {
            return Err(type_err(
                v,
                At {
                    path: &elem,
                    member: false,
                },
                "model.fileService",
            ))
        }
    };
    for (k, x) in obj {
        let Some(f) = field_of(k, &SERVICE_FIELDS) else {
            continue;
        };
        let path = format!("{elem}.{k}");
        let at = At {
            path: &path,
            member: true,
        };
        match f {
            "name" => {
                if let Some(s) = get_str(x, at)? {
                    fs.name = s;
                }
            }
            "s" => {
                if let Some(y) = get_f64(x, at)? {
                    fs.s = y;
                }
            }
            "children" => match x {
                JVal::Null => fs.children = Vec::new(),
                JVal::Arr(a) => fs.children = a.clone(),
                _ => return Err(type_err(x, at, "[]jsontext.Value")),
            },
            "parallel" => {
                if let Some(b) = get_bool(x, at)? {
                    fs.parallel = b;
                }
            }
            "servers" => {
                if let Some(i) = get_int(x, at)? {
                    fs.servers = i;
                }
            }
            "workers" => {
                if let Some(i) = get_int(x, at)? {
                    fs.workers = i;
                }
            }
            "cs2" => fs.cs2 = get_f64(x, at)?, // a pointer: null resets it
            "routing" => {
                if let Some(s) = get_str(x, at)? {
                    fs.routing = s;
                }
            }
            "delay" => {
                if let Some(b) = get_bool(x, at)? {
                    fs.delay = b;
                }
            }
            "hop" => {
                if let Some(y) = get_f64(x, at)? {
                    fs.hop = y;
                }
            }
            "branch_corr" => {
                if let Some(y) = get_f64(x, at)? {
                    fs.branch_corr = y;
                }
            }
            "glue" => {
                if let Some(y) = get_f64(x, at)? {
                    fs.glue = y;
                }
            }
            "glue_cs2" => {
                if let Some(y) = get_f64(x, at)? {
                    fs.glue_cs2 = y;
                }
            }
            "shares" => match x {
                JVal::Null => fs.shares = None,
                JVal::Arr(a) => {
                    let mut out = Vec::with_capacity(a.len());
                    for (j, e) in a.iter().enumerate() {
                        let ep = format!("{path}.{j}");
                        let eat = At {
                            path: &ep,
                            member: false,
                        };
                        out.push(get_f64(e, eat)?.unwrap_or(0.0));
                    }
                    fs.shares = Some(out);
                }
                _ => return Err(type_err(x, at, "[]float64")),
            },
            "hold" => {
                if let Some(b) = get_bool(x, at)? {
                    fs.hold = b;
                }
            }
            "own_slots" => fs.own_slots = get_int(x, at)?,
            _ => unreachable!(),
        }
    }
    Ok(fs)
}

/// A child: a name, or {name, p, async}. None where Go's two Unmarshal attempts both fail.
fn child_of(raw: &JVal) -> Option<(String, f64, bool)> {
    let at = At {
        path: "child",
        member: true,
    };
    match raw {
        JVal::Str(s) => Some((s.clone(), 1.0, false)),
        JVal::Null => Some((String::new(), 1.0, false)), // null into a string is a no-op
        JVal::Obj(o) => {
            let (mut name, mut p, mut is_async) = (String::new(), None, false);
            for (k, x) in o {
                match field_of(k, &["name", "p", "async"]) {
                    Some("name") => {
                        if let Some(s) = get_str(x, at).ok()? {
                            name = s;
                        }
                    }
                    Some("p") => p = get_f64(x, at).ok()?,
                    Some("async") => {
                        if let Some(b) = get_bool(x, at).ok()? {
                            is_async = b;
                        }
                    }
                    _ => {}
                }
            }
            Some((name, p.unwrap_or(1.0), is_async))
        }
        _ => None,
    }
}

/// ParseTopology reads a topology from JSON (Go's model.ParseTopology) and finishes it. Features the model
/// does not support (held workers) are refused by name. JSON type mismatches fail with Go 1.27's
/// encoding/json text; a syntax error as "invalid JSON" (see the module notes).
pub fn parse_topology(data: &[u8]) -> Result<Topology, ModelError> {
    let doc: JVal = match Reader::doc(data) {
        Some(d) => d,
        None => {
            // a syntax error: described by serde_json with the `oracle` feature; the CLI reports Go's text
            // before it gets here (rbfast_otlp::check_json_syntax)
            #[cfg(feature = "oracle")]
            let e = serde_json::from_slice::<serde_json::Value>(data)
                .err()
                .map_or_else(|| "invalid JSON".to_string(), |e| e.to_string());
            #[cfg(not(feature = "oracle"))]
            let e = "invalid JSON".to_string();
            return Err(ModelError(e));
        }
    };
    let mut name = String::new();
    let mut fservices: Vec<FileService> = Vec::new();
    let mut entry: Vec<(String, f64)> = Vec::new(); // Go map: later keys overwrite, a second object merges
    match &doc {
        JVal::Null => {}
        JVal::Obj(o) => {
            for (k, x) in o {
                let path = format!("fileTopology.{k}");
                let at = At {
                    path: &path,
                    member: true,
                };
                match field_of(k, &["name", "services", "entry"]) {
                    Some("name") => {
                        if let Some(s) = get_str(x, at)? {
                            name = s;
                        }
                    }
                    Some("services") => match x {
                        JVal::Null => fservices.clear(),
                        JVal::Arr(a) => {
                            fservices = a
                                .iter()
                                .enumerate()
                                .map(|(i, v)| file_service(v, &path, i))
                                .collect::<Result<_, _>>()?;
                        }
                        _ => return Err(type_err(x, at, "[]model.fileService")),
                    },
                    Some("entry") => match x {
                        JVal::Null => entry.clear(),
                        JVal::Obj(m) => {
                            for (ek, ev) in m {
                                let ep = format!("{path}.{ek}");
                                let eat = At {
                                    path: &ep,
                                    member: true,
                                };
                                let w = get_f64(ev, eat)?.unwrap_or(0.0);
                                if let Some(slot) = entry.iter_mut().find(|(n, _)| n == ek) {
                                    slot.1 = w;
                                } else {
                                    entry.push((ek.clone(), w));
                                }
                            }
                        }
                        _ => return Err(type_err(x, at, "map[string]float64")),
                    },
                    _ => {}
                }
            }
        }
        _ => {
            return Err(type_err(
                &doc,
                At {
                    path: "",
                    member: false,
                },
                "model.fileTopology",
            ))
        }
    }
    let mut idx: HashMap<&str, usize> = HashMap::new();
    for (i, s) in fservices.iter().enumerate() {
        idx.insert(&s.name, i);
    }
    let mut services = Vec::with_capacity(fservices.len());
    for fs in &fservices {
        if fs.hold || fs.own_slots.is_some() {
            return Err(ModelError(format!(
                "{}: held workers are not supported",
                fs.name
            )));
        }
        let mut s = Service {
            name: fs.name.clone(),
            s: fs.s,
            parallel: fs.parallel,
            servers: fs.servers,
            workers: fs.workers,
            cs2: fs.cs2.unwrap_or(1.0),
            routing: fs.routing.clone(),
            delay: fs.delay,
            hop: fs.hop,
            branch_corr: fs.branch_corr,
            glue: fs.glue,
            glue_cs2: fs.glue_cs2,
            shares: fs.shares.clone(),
            calls: Vec::new(),
        };
        for raw in &fs.children {
            let Some((cname, p, is_async)) = child_of(raw) else {
                return Err(ModelError(format!(
                    "{}: a child must be a name or {{name, p, async}}",
                    fs.name
                )));
            };
            let Some(&ci) = idx.get(cname.as_str()) else {
                return Err(ModelError(format!(
                    "{}: unknown child {}",
                    fs.name,
                    quote(&cname)
                )));
            };
            s.calls.push(Call {
                child: ci,
                p,
                is_async,
            });
        }
        services.push(s);
    }
    let mut emap = BTreeMap::new();
    for (ename, w) in &entry {
        let Some(&i) = idx.get(ename.as_str()) else {
            return Err(ModelError(format!(
                "unknown entry service {}",
                quote(ename)
            )));
        };
        emap.insert(i, *w);
    }
    let mut t = Topology::new(name, services, emap);
    t.finish()?;
    Ok(t)
}

/// LoadTopology reads a topology file.
pub fn load_topology(path: &std::path::Path) -> Result<Topology, ModelError> {
    let data = std::fs::read(path).map_err(|e| ModelError(e.to_string()))?;
    parse_topology(&data)
}

/// MarshalTopology writes a topology in the JSON form ParseTopology reads, byte for byte as Go's
/// `model.MarshalTopology` does. A NaN or infinite number is an error there (encoding/json refuses them).
pub fn marshal_topology(t: &Topology) -> Result<String, ModelError> {
    let mut w = Indent {
        out: String::new(),
        depth: 0,
    };
    w.open('{');
    w.key("name");
    w.str_val(&t.name);
    w.key("services");
    if t.services.is_empty() {
        w.raw("null");
    } else {
        w.open('[');
        for s in &t.services {
            w.elem();
            w.open('{');
            w.key("name");
            w.str_val(&s.name);
            w.key("s");
            w.num(s.s)?;
            if !s.calls.is_empty() {
                w.key("children");
                w.open('[');
                for c in &s.calls {
                    w.elem();
                    let cname = &t.services[c.child].name;
                    if c.p == 1.0 && !c.is_async {
                        w.str_val(cname);
                    } else {
                        w.open('{');
                        w.key("name");
                        w.str_val(cname);
                        w.key("p");
                        w.num(c.p)?;
                        if c.is_async {
                            w.key("async");
                            w.raw("true");
                        }
                        w.close('}');
                    }
                }
                w.close(']');
            }
            if s.parallel {
                w.key("parallel");
                w.raw("true");
            }
            if s.servers != 0 {
                w.key("servers");
                w.raw(&s.servers.to_string());
            }
            if s.workers != 0 && s.workers != 1 {
                w.key("workers");
                w.raw(&s.workers.to_string());
            }
            w.key("cs2");
            w.num(s.cs2)?;
            if !s.routing.is_empty() {
                w.key("routing");
                w.str_val(&s.routing);
            }
            if s.delay {
                w.key("delay");
                w.raw("true");
            }
            for (k, x) in [
                ("hop", s.hop),
                ("branch_corr", s.branch_corr),
                ("glue", s.glue),
                ("glue_cs2", s.glue_cs2),
            ] {
                if x != 0.0 || x.is_nan() {
                    w.key(k);
                    w.num(x)?;
                }
            }
            if let Some(sh) = &s.shares {
                if !sh.is_empty() {
                    w.key("shares");
                    w.open('[');
                    for &p in sh {
                        w.elem();
                        w.num(p)?;
                    }
                    w.close(']');
                }
            }
            w.close('}');
        }
        w.close(']');
    }
    w.key("entry");
    let mut entries: Vec<(&str, f64)> = t
        .entry
        .iter()
        .map(|(&i, &x)| (t.services[i].name.as_str(), x))
        .collect();
    entries.sort_by(|a, b| a.0.as_bytes().cmp(b.0.as_bytes()));
    if entries.is_empty() {
        w.raw("{}");
    } else {
        w.open('{');
        for (k, x) in entries {
            w.key(k);
            w.num(x)?;
        }
        w.close('}');
    }
    w.close('}');
    Ok(w.out)
}

/// json.MarshalIndent(v, "", "  ") output, written directly.
struct Indent {
    out: String,
    depth: usize,
}

impl Indent {
    fn newline(&mut self) {
        self.out.push('\n');
        for _ in 0..self.depth {
            self.out.push_str("  ");
        }
    }
    fn open(&mut self, c: char) {
        self.out.push(c);
        self.depth += 1;
        self.out.push('\u{0}'); // marks "nothing written yet in this container"
    }
    fn first(&mut self) -> bool {
        if self.out.ends_with('\u{0}') {
            self.out.pop();
            true
        } else {
            false
        }
    }
    fn elem(&mut self) {
        if !self.first() {
            self.out.push(',');
        }
        self.newline();
    }
    fn key(&mut self, k: &str) {
        self.elem();
        json_string(k, &mut self.out);
        self.out.push_str(": ");
    }
    fn close(&mut self, c: char) {
        self.depth -= 1;
        if self.first() {
            // empty container: Go writes [] and {}
        } else {
            self.newline();
        }
        self.out.push(c);
    }
    fn raw(&mut self, s: &str) {
        self.out.push_str(s);
    }
    fn str_val(&mut self, s: &str) {
        json_string(s, &mut self.out);
    }
    fn num(&mut self, x: f64) -> Result<(), ModelError> {
        if !x.is_finite() {
            return Err(ModelError(format!(
                "json: unsupported value: {}",
                crate::gofmt::fmt_v(x)
            )));
        }
        self.out.push_str(&json_float(x));
        Ok(())
    }
}
