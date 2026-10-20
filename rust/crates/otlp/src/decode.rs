// SPDX-License-Identifier: Apache-2.0

//! One ExportTraceServiceRequest (a JSON document) decoded the way Go's `json.Unmarshal` fills rhobound-cli's
//! `jsonRequest`, then reduced to spans exactly as its `decodeRequest` does.
//!
//! The document is first decoded completely into flat arenas (Go decodes the whole request before it looks at
//! it: a resource may come after its spans, and an error anywhere refuses the whole request), then processed.
//! Go's v1 merge rules are kept: a repeated member decodes into what the first one left (struct fields merge,
//! strings and numbers are replaced, a JSON null leaves strings, numbers and structs alone and empties slices); a
//! repeated array decodes element by element into the old slice's backing array, whose elements beyond the new
//! length survive for a later repetition (Go's `reflect.Value.Grow` copies the whole backing array, so its
//! capacity never loses them); an empty array resets it. Strings are Go's: escapes resolved, invalid UTF-8
//! replaced byte by byte. Names match case-insensitively (strings.EqualFold) when no name matches exactly.
//!
//! Errors: a syntax error anywhere wins; otherwise the first type error (or timestamp error) in document order.

use crate::gonum::{self, Nanos};
use crate::json::{self, kind_word, read_string, skip_ws, SynErr, S, SR};
use crate::{Resource, Span, KIND_CLIENT, KIND_SERVER};
use std::collections::HashMap;
use std::hash::{BuildHasherDefault, Hasher};

// ------------------------------------------------------------------ hashing

// After rustc-hash 1.x's FxHasher (https://github.com/rust-lang/rustc-hash), Copyright 2015 The Rust Project
// Developers, Apache-2.0 OR MIT (used under Apache-2.0).
/// FxHash (rustc's hasher): fast on the short keys interned here.
#[derive(Default, Clone, Copy)]
pub(crate) struct FxHasher {
    hash: u64,
}

const SEED: u64 = 0x51_7c_c1_b7_27_22_0a_95;

impl FxHasher {
    #[inline(always)]
    fn add(&mut self, w: u64) {
        self.hash = (self.hash.rotate_left(5) ^ w).wrapping_mul(SEED);
    }
}

impl Hasher for FxHasher {
    #[inline]
    fn write(&mut self, mut b: &[u8]) {
        while b.len() >= 8 {
            self.add(u64::from_le_bytes(b[..8].try_into().unwrap()));
            b = &b[8..];
        }
        if b.len() >= 4 {
            self.add(u32::from_le_bytes(b[..4].try_into().unwrap()) as u64);
            b = &b[4..];
        }
        for &c in b {
            self.add(c as u64);
        }
    }
    #[inline]
    fn write_u8(&mut self, i: u8) {
        self.add(i as u64)
    }
    #[inline]
    fn write_u64(&mut self, i: u64) {
        self.add(i)
    }
    #[inline]
    fn write_usize(&mut self, i: usize) {
        self.add(i as u64)
    }
    #[inline]
    fn finish(&self) -> u64 {
        // hashbrown picks the bucket from the low bits: fold the well-mixed high bits in
        self.hash ^ (self.hash >> 29)
    }
}

pub(crate) type FxBuild = BuildHasherDefault<FxHasher>;
pub(crate) type FxMap<K, V> = HashMap<K, V, FxBuild>;

/// First-seen interning of byte strings.
#[derive(Default)]
pub(crate) struct Interner {
    map: FxMap<Box<[u8]>, u32>,
    pub keys: Vec<Box<[u8]>>,
}

impl Interner {
    #[inline]
    pub fn intern(&mut self, k: &[u8]) -> (u32, bool) {
        if let Some(&i) = self.map.get(k) {
            return (i, false);
        }
        let i = self.keys.len() as u32;
        let bk: Box<[u8]> = k.into();
        self.keys.push(bk.clone());
        self.map.insert(bk, i);
        (i, true)
    }
}

/// The key a resource is interned by: the three strings with a separator no UTF-8 string contains.
pub(crate) fn resource_key(
    out: &mut Vec<u8>,
    svc: &[u8],
    pod: &[u8],
    img_name: &[u8],
    img_tag: &[u8],
) {
    out.clear();
    out.extend_from_slice(svc);
    out.push(0xFF);
    out.extend_from_slice(pod);
    out.push(0xFF);
    out.extend_from_slice(img_name);
    if !img_tag.is_empty() && !img_name.is_empty() {
        out.push(b':');
        out.extend_from_slice(img_tag);
    }
}

pub(crate) fn resource_from_key(k: &[u8]) -> Resource {
    let mut it = k.split(|&c| c == 0xFF);
    let s = |b: Option<&[u8]>| {
        String::from_utf8(b.unwrap_or_default().to_vec()).expect("decoded strings are UTF-8")
    };
    Resource {
        service: s(it.next()),
        pod: s(it.next()),
        image: s(it.next()),
    }
}

// ------------------------------------------------------------------ the decoded document

/// A slice field: `len` elements at `start` in its arena; `cap` elements of backing array there (the elements
/// from `len` to `cap` are what an earlier, longer occurrence left).
#[derive(Clone, Copy, Debug, Default)]
struct Sl {
    start: u32,
    len: u32,
    cap: u32,
}

/// A raw JSON value (json.RawMessage): a range of the document; `set` false when the member was absent.
#[derive(Clone, Copy, Debug, Default)]
struct Raw {
    start: u32,
    end: u32,
    set: bool,
}

#[derive(Clone, Copy, Debug, Default)]
struct Kv {
    key: S,
    sval: S,
    ival: Raw,
}

#[derive(Clone, Copy, Debug, Default)]
struct JSpan {
    trace: S,
    sid: S,
    parent: S,
    name: S,
    kind: i64,
    start: u64,
    end: u64,
    attrs: Sl,
}

#[derive(Clone, Copy, Debug, Default)]
struct SsRec {
    spans: Sl,
}

#[derive(Clone, Copy, Debug, Default)]
struct RsRec {
    attrs: Sl,
    ss: Sl,
}

/// A type error, located by the position of the offending value (its path is found only when it is reported).
struct SemErr {
    pos: usize,
    what: String,
    ty: &'static str,
}

enum FirstErr {
    Type(SemErr),
    /// An error returned by an UnmarshalJSON method (the timestamp rule): Go reports it as it is.
    Plain(String),
}

// Go's type names, as its UnmarshalTypeError prints them.
const TY_REQUEST: &str = "otlp.jsonRequest";
const TY_RS_SLICE: &str = "[]struct { Resource struct { Attributes []otlp.keyValue \"json:\\\"attributes\\\"\" } \"json:\\\"resource\\\"\"; ScopeSpans []struct { Spans []otlp.jsonSpan \"json:\\\"spans\\\"\" } \"json:\\\"scopeSpans\\\"\" }";
const TY_RS: &str = "struct { Resource struct { Attributes []otlp.keyValue \"json:\\\"attributes\\\"\" } \"json:\\\"resource\\\"\"; ScopeSpans []struct { Spans []otlp.jsonSpan \"json:\\\"spans\\\"\" } \"json:\\\"scopeSpans\\\"\" }";
const TY_RESOURCE: &str = "struct { Attributes []otlp.keyValue \"json:\\\"attributes\\\"\" }";
const TY_SS_SLICE: &str = "[]struct { Spans []otlp.jsonSpan \"json:\\\"spans\\\"\" }";
const TY_SS: &str = "struct { Spans []otlp.jsonSpan \"json:\\\"spans\\\"\" }";
const TY_SPAN_SLICE: &str = "[]otlp.jsonSpan";
const TY_SPAN: &str = "otlp.jsonSpan";
const TY_KV_SLICE: &str = "[]otlp.keyValue";
const TY_KV: &str = "otlp.keyValue";
const TY_ANY: &str = "otlp.anyValue";
const TY_STRING: &str = "string";
const TY_INT: &str = "int";

// Member names of each Go struct, in field order.
const F_REQ: &[&[u8]] = &[b"resourceSpans"];
const F_RS: &[&[u8]] = &[b"resource", b"scopeSpans"];
const F_RESOURCE: &[&[u8]] = &[b"attributes"];
const F_SS: &[&[u8]] = &[b"spans"];
const F_SPAN: &[&[u8]] = &[
    b"traceId",
    b"spanId",
    b"parentSpanId",
    b"name",
    b"kind",
    b"startTimeUnixNano",
    b"endTimeUnixNano",
    b"attributes",
];
const F_KV: &[&[u8]] = &[b"key", b"value"];
const F_ANY: &[&[u8]] = &[b"stringValue", b"intValue"];

/// strings.EqualFold of a member name against one of our (ASCII-letter) field names. Beyond ASCII case, only
/// U+017F (long s) folds to 's' and U+212A (Kelvin sign) to 'k'.
fn fold_eq(key: &[u8], name: &[u8]) -> bool {
    if key.is_ascii() {
        return key.eq_ignore_ascii_case(name);
    }
    let Ok(k) = std::str::from_utf8(key) else {
        return false;
    };
    let mut ni = name.iter();
    for c in k.chars() {
        let Some(&n) = ni.next() else { return false };
        let ok = match c {
            '\u{017F}' => n == b's' || n == b'S',
            '\u{212A}' => n == b'k' || n == b'K',
            c if c.is_ascii() => (c as u8).eq_ignore_ascii_case(&n),
            _ => false,
        };
        if !ok {
            return false;
        }
    }
    ni.next().is_none()
}

#[inline(always)]
fn match_field(key: &[u8], fields: &[&[u8]]) -> Option<usize> {
    for (i, f) in fields.iter().enumerate() {
        if key == *f {
            return Some(i);
        }
    }
    match_field_fold(key, fields)
}

#[cold]
fn match_field_fold(key: &[u8], fields: &[&[u8]]) -> Option<usize> {
    // an ASCII key (every unknown member of a real capture: "flags", "status", "schemaUrl", "scope") folds only
    // to a field of its own length; check is_ascii once, not once per field
    if key.is_ascii() {
        return fields
            .iter()
            .position(|f| f.len() == key.len() && key.eq_ignore_ascii_case(f));
    }
    fields.iter().position(|f| fold_eq(key, f))
}

/// The largest request (one line, or one value of a .json stream) the decoder takes: offsets into the document
/// and into the side buffer of decoded strings are u32.
pub(crate) const MAX_DOC: usize = (u32::MAX / 4) as usize;

/// The structural decoder. Arenas are kept between documents (cleared, not freed).
#[derive(Default)]
pub(crate) struct Decoder {
    esc: Vec<u8>,
    rs: Vec<RsRec>,
    ss: Vec<SsRec>,
    spans: Vec<JSpan>,
    kvs: Vec<Kv>,
    stack: Vec<bool>,
    first: Option<FirstErr>,
    top: Sl,
}

/// An error decoding one document: the text Go's json.Unmarshal returns for it.
pub(crate) enum DocErr {
    Syntax(SynErr),
    Other(String),
}

struct Cur<'a> {
    b: &'a [u8],
    i: usize,
}

impl Decoder {
    /// Decodes one document. On success the arenas hold Go's jsonRequest.
    pub(crate) fn decode(&mut self, b: &[u8]) -> Result<(), DocErr> {
        if b.len() > MAX_DOC {
            // offsets are 32-bit, and replacing invalid UTF-8 can triple a string: refuse rather than truncate
            return Err(DocErr::Other(format!(
                "request of {} bytes: the Rust reader takes at most {} bytes per request (Go has no such limit)",
                b.len(),
                MAX_DOC
            )));
        }
        self.esc.clear();
        self.rs.clear();
        self.ss.clear();
        self.spans.clear();
        self.kvs.clear();
        self.first = None;
        self.top = Sl::default();
        let mut c = Cur { b, i: 0 };
        if let Err(e) = self.request(&mut c) {
            return Err(DocErr::Syntax(e));
        }
        match self.first.take() {
            None => Ok(()),
            Some(FirstErr::Plain(s)) => Err(DocErr::Other(s)),
            Some(FirstErr::Type(e)) => Err(DocErr::Other(type_error_text(b, &e))),
        }
    }

    #[inline]
    fn sem(&mut self, pos: usize, what: String, ty: &'static str) {
        if self.first.is_none() {
            self.first = Some(FirstErr::Type(SemErr { pos, what, ty }));
        }
    }

    /// Skips the value at `c.i` (already past whitespace) after a type mismatch, recording the error.
    #[cold]
    fn mismatch(&mut self, c: &mut Cur, depth: usize, ty: &'static str) -> SR<()> {
        let pos = c.i;
        let what = kind_word(c.b[pos]).to_string();
        c.i = json::skip_value(c.b, pos, depth, &mut self.stack)?;
        self.sem(pos, what, ty);
        Ok(())
    }

    #[inline]
    fn skip(&mut self, c: &mut Cur, depth: usize) -> SR<()> {
        c.i = json::skip_value(c.b, c.i, depth, &mut self.stack)?;
        Ok(())
    }

    fn request(&mut self, c: &mut Cur) -> SR<()> {
        c.i = skip_ws(c.b, c.i);
        if c.i >= c.b.len() {
            return Err(SynErr::Eof);
        }
        match c.b[c.i] {
            b'{' => {
                let mut top = self.top;
                self.object(c, 1, F_REQ, |d, c, _f, depth| {
                    top = d.array(
                        c,
                        depth,
                        top,
                        TY_RS_SLICE,
                        TY_RS,
                        Decoder::rs_arena,
                        Decoder::rs_elem,
                    )?;
                    Ok(())
                })?;
                self.top = top;
            }
            b'n' => c.i = json::skip_literal(c.b, c.i, b"null")?,
            _ => self.mismatch(c, 0, TY_REQUEST)?,
        }
        c.i = skip_ws(c.b, c.i);
        if c.i < c.b.len() {
            return Err(json::invalid_char(c.b, c.i, json::W_TOP));
        }
        Ok(())
    }

    /// Walks the object at `c.b[c.i] == '{'` (at nesting `depth`, counting this object). For each member that
    /// names one of `fields`, calls `f` with the field index, positioned at the value (after whitespace), at
    /// the depth of the object; `f` must consume the value. Other members are skipped.
    #[inline(always)]
    fn object<F>(&mut self, c: &mut Cur, depth: usize, fields: &[&[u8]], mut f: F) -> SR<()>
    where
        F: FnMut(&mut Decoder, &mut Cur, usize, usize) -> SR<()>,
    {
        json::check_depth(depth)?;
        let b = c.b;
        let mut i = skip_ws(b, c.i + 1);
        if i >= b.len() {
            return Err(SynErr::Eof);
        }
        if b[i] == b'}' {
            c.i = i + 1;
            return Ok(());
        }
        loop {
            if b[i] != b'"' {
                return Err(json::invalid_char(b, i, json::W_KEY));
            }
            let (key, j) = read_string(b, i, &mut self.esc)?;
            i = skip_ws(b, j);
            if i >= b.len() {
                return Err(SynErr::Eof);
            }
            if b[i] != b':' {
                return Err(json::invalid_char(b, i, json::W_COLON));
            }
            i = skip_ws(b, i + 1);
            if i >= b.len() {
                return Err(SynErr::Eof);
            }
            c.i = i;
            let kb = key.get(b, &self.esc);
            match match_field(kb, fields) {
                Some(fi) => f(self, c, fi, depth)?,
                None => self.skip(c, depth)?,
            }
            i = skip_ws(b, c.i);
            if i >= b.len() {
                return Err(SynErr::Eof);
            }
            match b[i] {
                b',' => {
                    i = skip_ws(b, i + 1);
                    if i >= b.len() {
                        return Err(SynErr::Eof);
                    }
                }
                b'}' => {
                    c.i = i + 1;
                    return Ok(());
                }
                _ => return Err(json::invalid_char(b, i, json::W_OBJ_NEXT)),
            }
        }
    }

    /// Decodes a slice member (value at `c.i`, inside a container at `depth`) into `cur` with Go's legacy merge
    /// rules. `elem` decodes one element object into a copy of its old value.
    #[inline(always)]
    #[allow(clippy::too_many_arguments)]
    fn array<T: Copy + Default>(
        &mut self,
        c: &mut Cur,
        depth: usize,
        cur: Sl,
        ty_slice: &'static str,
        ty_elem: &'static str,
        arena: fn(&mut Decoder) -> &mut Vec<T>,
        elem: fn(&mut Decoder, &mut Cur, &mut T, usize) -> SR<()>,
    ) -> SR<Sl> {
        let b = c.b;
        match b[c.i] {
            b'[' => {}
            b'n' => {
                c.i = json::skip_literal(b, c.i, b"null")?;
                return Ok(Sl::default()); // SetZero
            }
            _ => {
                self.mismatch(c, depth, ty_slice)?;
                return Ok(cur);
            }
        }
        let d = depth + 1;
        json::check_depth(d)?;
        let mut i = skip_ws(b, c.i + 1);
        if i >= b.len() {
            return Err(SynErr::Eof);
        }
        if b[i] == b']' {
            c.i = i + 1;
            return Ok(Sl::default()); // MakeSlice(0, 0)
        }
        let start = arena(self).len() as u32;
        let mut n: u32 = 0;
        loop {
            let mut e = if n < cur.cap {
                arena(self)[(cur.start + n) as usize]
            } else {
                T::default()
            };
            c.i = i;
            match b[i] {
                b'{' => elem(self, c, &mut e, d + 1)?,
                b'n' => c.i = json::skip_literal(b, i, b"null")?,
                _ => self.mismatch(c, d, ty_elem)?,
            }
            arena(self).push(e);
            n += 1;
            i = skip_ws(b, c.i);
            if i >= b.len() {
                return Err(SynErr::Eof);
            }
            match b[i] {
                b',' => {
                    i = skip_ws(b, i + 1);
                    if i >= b.len() {
                        return Err(SynErr::Eof);
                    }
                }
                b']' => {
                    c.i = i + 1;
                    break;
                }
                _ => return Err(json::invalid_char(b, i, json::W_ARR_NEXT)),
            }
        }
        // the old backing array's elements beyond the new length stay behind it
        for k in n..cur.cap {
            let e = arena(self)[(cur.start + k) as usize];
            arena(self).push(e);
        }
        Ok(Sl {
            start,
            len: n,
            cap: n.max(cur.cap),
        })
    }

    fn rs_arena(&mut self) -> &mut Vec<RsRec> {
        &mut self.rs
    }
    fn ss_arena(&mut self) -> &mut Vec<SsRec> {
        &mut self.ss
    }
    fn span_arena(&mut self) -> &mut Vec<JSpan> {
        &mut self.spans
    }
    fn kv_arena(&mut self) -> &mut Vec<Kv> {
        &mut self.kvs
    }

    /// A struct member: object (decoded into the old value), null (left alone), anything else a type error.
    #[inline(always)]
    fn struct_member<T>(
        &mut self,
        c: &mut Cur,
        depth: usize,
        v: &mut T,
        ty: &'static str,
        elem: fn(&mut Decoder, &mut Cur, &mut T, usize) -> SR<()>,
    ) -> SR<()> {
        match c.b[c.i] {
            b'{' => elem(self, c, v, depth + 1),
            b'n' => {
                c.i = json::skip_literal(c.b, c.i, b"null")?;
                Ok(())
            }
            _ => self.mismatch(c, depth, ty),
        }
    }

    fn rs_elem(&mut self, c: &mut Cur, e: &mut RsRec, depth: usize) -> SR<()> {
        self.object(c, depth, F_RS, |d, c, f, depth| {
            if f == 0 {
                let mut attrs = e.attrs;
                d.struct_member(c, depth, &mut attrs, TY_RESOURCE, Decoder::resource_obj)?;
                e.attrs = attrs;
            } else {
                e.ss = d.array(
                    c,
                    depth,
                    e.ss,
                    TY_SS_SLICE,
                    TY_SS,
                    Decoder::ss_arena,
                    Decoder::ss_elem,
                )?;
            }
            Ok(())
        })
    }

    fn resource_obj(&mut self, c: &mut Cur, attrs: &mut Sl, depth: usize) -> SR<()> {
        self.object(c, depth, F_RESOURCE, |d, c, _f, depth| {
            *attrs = d.array(
                c,
                depth,
                *attrs,
                TY_KV_SLICE,
                TY_KV,
                Decoder::kv_arena,
                Decoder::kv_elem,
            )?;
            Ok(())
        })
    }

    fn ss_elem(&mut self, c: &mut Cur, e: &mut SsRec, depth: usize) -> SR<()> {
        self.object(c, depth, F_SS, |d, c, _f, depth| {
            e.spans = d.array(
                c,
                depth,
                e.spans,
                TY_SPAN_SLICE,
                TY_SPAN,
                Decoder::span_arena,
                Decoder::span_elem,
            )?;
            Ok(())
        })
    }

    fn span_elem(&mut self, c: &mut Cur, e: &mut JSpan, depth: usize) -> SR<()> {
        self.object(c, depth, F_SPAN, |d, c, f, depth| match f {
            0 => d.string_member(c, depth, &mut e.trace),
            1 => d.string_member(c, depth, &mut e.sid),
            2 => d.string_member(c, depth, &mut e.parent),
            3 => d.string_member(c, depth, &mut e.name),
            4 => d.int_member(c, depth, &mut e.kind),
            5 => d.nanos_member(c, depth, &mut e.start),
            6 => d.nanos_member(c, depth, &mut e.end),
            _ => {
                e.attrs = d.array(
                    c,
                    depth,
                    e.attrs,
                    TY_KV_SLICE,
                    TY_KV,
                    Decoder::kv_arena,
                    Decoder::kv_elem,
                )?;
                Ok(())
            }
        })
    }

    fn kv_elem(&mut self, c: &mut Cur, e: &mut Kv, depth: usize) -> SR<()> {
        self.object(c, depth, F_KV, |d, c, f, depth| {
            if f == 0 {
                d.string_member(c, depth, &mut e.key)
            } else {
                let mut v = (e.sval, e.ival);
                d.struct_member(c, depth, &mut v, TY_ANY, Decoder::any_obj)?;
                (e.sval, e.ival) = v;
                Ok(())
            }
        })
    }

    fn any_obj(&mut self, c: &mut Cur, v: &mut (S, Raw), depth: usize) -> SR<()> {
        self.object(c, depth, F_ANY, |d, c, f, depth| {
            if f == 0 {
                d.string_member(c, depth, &mut v.0)
            } else {
                // json.RawMessage: the raw value, whatever it is (null included)
                let start = c.i;
                d.skip(c, depth)?;
                v.1 = Raw {
                    start: start as u32,
                    end: c.i as u32,
                    set: true,
                };
                Ok(())
            }
        })
    }

    #[inline(always)]
    fn string_member(&mut self, c: &mut Cur, depth: usize, dst: &mut S) -> SR<()> {
        match c.b[c.i] {
            b'"' => {
                let (s, j) = read_string(c.b, c.i, &mut self.esc)?;
                *dst = s;
                c.i = j;
                Ok(())
            }
            b'n' => {
                c.i = json::skip_literal(c.b, c.i, b"null")?;
                Ok(())
            }
            _ => self.mismatch(c, depth, TY_STRING),
        }
    }

    fn int_member(&mut self, c: &mut Cur, depth: usize, dst: &mut i64) -> SR<()> {
        let b = c.b;
        match b[c.i] {
            b'-' | b'0'..=b'9' => {
                let start = c.i;
                let end = json::skip_number(b, start)?;
                c.i = end;
                let lit = &b[start..end];
                match parse_i64(lit) {
                    Some(v) => *dst = v,
                    None => self.sem(
                        start,
                        format!("number {}", String::from_utf8_lossy(lit)),
                        TY_INT,
                    ),
                }
                Ok(())
            }
            b'n' => {
                c.i = json::skip_literal(b, c.i, b"null")?;
                Ok(())
            }
            _ => self.mismatch(c, depth, TY_INT),
        }
    }

    #[inline(always)]
    fn nanos_member(&mut self, c: &mut Cur, depth: usize, dst: &mut u64) -> SR<()> {
        let b = c.b;
        let start = c.i;
        // fast path: a string of up to 19 digits
        if b[start] == b'"' {
            let mut j = start + 1;
            let mut v: u64 = 0;
            while j < b.len() && b[j].is_ascii_digit() && j - start <= 19 {
                v = v * 10 + (b[j] - b'0') as u64;
                j += 1;
            }
            if j < b.len() && b[j] == b'"' && j > start + 1 && j - start <= 20 {
                *dst = v;
                c.i = j + 1;
                return Ok(());
            }
        }
        self.skip(c, depth)?;
        match gonum::nanos(&b[start..c.i]) {
            Nanos::Keep => {}
            Nanos::Set(v) => *dst = v,
            Nanos::Err(e) => {
                if self.first.is_none() {
                    self.first = Some(FirstErr::Plain(e));
                }
            }
        }
        Ok(())
    }
}

/// A JSON integer literal as Go's int (int64); None for a fraction, an exponent or an overflow.
fn parse_i64(lit: &[u8]) -> Option<i64> {
    let (neg, digits) = match lit.first() {
        Some(b'-') => (true, &lit[1..]),
        _ => (false, lit),
    };
    if digits.is_empty() || !digits.iter().all(u8::is_ascii_digit) {
        return None;
    }
    let mut v: i128 = 0;
    for &c in digits {
        v = v * 10 + (c - b'0') as i128;
        if v > i64::MAX as i128 + 1 {
            return None;
        }
    }
    if neg {
        v = -v;
    }
    i64::try_from(v).ok()
}

/// Go's UnmarshalTypeError text, with the path of the value at `e.pos` (member names as the input spells them,
/// unescaped; array indices).
fn type_error_text(b: &[u8], e: &SemErr) -> String {
    let mut path: Vec<String> = Vec::new();
    find_path(b, e.pos, &mut path);
    if path.is_empty() {
        return format!(
            "json: cannot unmarshal {} into Go value of type {}",
            e.what, e.ty
        );
    }
    let field = path.join(".");
    let last = path.last().unwrap();
    let into = if !last.is_empty() && last.bytes().all(|c| c.is_ascii_digit()) {
        ""
    } else {
        "Go struct field "
    };
    format!(
        "json: cannot unmarshal {} into {}jsonRequest.{} of type {}",
        e.what, into, field, e.ty
    )
}

/// The path from the top of a valid document to the value that starts at `pos`.
fn find_path(b: &[u8], pos: usize, path: &mut Vec<String>) {
    let mut esc = Vec::new();
    let mut stack = Vec::new();
    let mut i = skip_ws(b, 0);
    'outer: loop {
        if i == pos || i >= b.len() {
            return;
        }
        match b[i] {
            b'{' => {
                i = skip_ws(b, i + 1);
                while i < b.len() && b[i] != b'}' {
                    esc.clear();
                    let Ok((k, j)) = read_string(b, i, &mut esc) else {
                        return;
                    };
                    let name = String::from_utf8_lossy(k.get(b, &esc)).into_owned();
                    i = skip_ws(b, j) + 1; // past ':'
                    i = skip_ws(b, i);
                    let Ok(end) = json::skip_value(b, i, 0, &mut stack) else {
                        return;
                    };
                    if i <= pos && pos < end {
                        path.push(name);
                        continue 'outer;
                    }
                    i = skip_ws(b, end);
                    if i < b.len() && b[i] == b',' {
                        i = skip_ws(b, i + 1);
                    }
                }
                return;
            }
            b'[' => {
                i = skip_ws(b, i + 1);
                let mut idx = 0;
                while i < b.len() && b[i] != b']' {
                    let Ok(end) = json::skip_value(b, i, 0, &mut stack) else {
                        return;
                    };
                    if i <= pos && pos < end {
                        path.push(idx.to_string());
                        continue 'outer;
                    }
                    idx += 1;
                    i = skip_ws(b, end);
                    if i < b.len() && b[i] == b',' {
                        i = skip_ws(b, i + 1);
                    }
                }
                return;
            }
            _ => return,
        }
    }
}

// ------------------------------------------------------------------ reduction to spans

const PEER_KEYS: [&[u8]; 4] = [
    b"peer.service",
    b"server.address",
    b"net.peer.name",
    b"http.host",
];
const PATH_KEYS: [&[u8]; 5] = [
    b"url.path",
    b"http.target",
    b"http.route",
    b"http.path",
    b"http.url",
];
const METHOD_KEYS: [&[u8]; 2] = [b"http.request.method", b"http.method"];

/// Spans and tables from a run of documents (a chunk of one file), with part-local, first-seen tables.
#[derive(Default)]
pub(crate) struct Part {
    pub spans: Vec<Span>,
    pub res: Interner,
    pub peers: Interner,
    pub addrs: Interner,
    pub probes: Vec<(u64, u64, u64)>,
    pub skipped: usize,
    /// The first document error in this part (Go's text, without the "bad OTLP/JSON: " prefix).
    pub err: Option<String>,
    // scratch
    key: Vec<u8>,
    route: String,
}

#[inline]
fn hex_u64(s: &[u8]) -> Option<u64> {
    if s.len() != 16 {
        return None;
    }
    // 8 digits at a time (SWAR) instead of a branch per digit
    let hi = hex8(u64::from_be_bytes(s[..8].try_into().unwrap()))?;
    let lo = hex8(u64::from_be_bytes(s[8..].try_into().unwrap()))?;
    Some(hi << 32 | lo)
}

/// Eight ASCII hex digits, the first in the top byte of `w`, as a 32-bit value; None unless every byte is
/// [0-9a-fA-F] (what the per-digit loop accepted).
#[inline(always)]
fn hex8(w: u64) -> Option<u64> {
    const ONES: u64 = 0x0101_0101_0101_0101;
    const HIGH: u64 = 0x8080_8080_8080_8080;
    if w & HIGH != 0 {
        return None;
    }
    // every byte < 0x80 here, so these additions never carry into the next byte
    let is_digit =
        (w + ONES * (0x80 - b'0' as u64)) & !(w + ONES * (0x80 - b'9' as u64 - 1)) & HIGH;
    let l = w | (ONES * 0x20);
    let is_alpha =
        (l + ONES * (0x80 - b'a' as u64)) & !(l + ONES * (0x80 - b'f' as u64 - 1)) & HIGH;
    if is_digit | is_alpha != HIGH {
        return None;
    }
    let v = (w & (ONES * 0x0f)) + (is_alpha >> 7) * 9;
    let v = (v >> 4 | v) & 0x00ff_00ff_00ff_00ff;
    let v = (v >> 8 | v) & 0x0000_ffff_0000_ffff;
    Some((v >> 16 | v) & 0xffff_ffff)
}

fn text<'x>(kv: &Kv, doc: &'x [u8], esc: &'x [u8]) -> &'x [u8] {
    let s = kv.sval.get(doc, esc);
    if !s.is_empty() || !kv.ival.set {
        return s;
    }
    let mut r = &doc[kv.ival.start as usize..kv.ival.end as usize];
    while let [b'"', rest @ ..] = r {
        r = rest;
    }
    while let [rest @ .., b'"'] = r {
        r = rest;
    }
    r
}

impl Part {
    /// Decodes one document and adds what it holds (Go's decodeRequest), or records its error.
    pub(crate) fn add_doc(&mut self, dec: &mut Decoder, doc: &[u8]) {
        if self.err.is_some() {
            return; // a later error cannot come first; the read fails anyway
        }
        match dec.decode(doc) {
            Ok(()) => self.reduce(dec, doc),
            Err(DocErr::Syntax(SynErr::Eof)) => {
                self.err = Some("unexpected end of JSON input".into())
            }
            Err(DocErr::Syntax(SynErr::Msg(m))) | Err(DocErr::Other(m)) => self.err = Some(m),
        }
    }

    fn reduce(&mut self, dec: &Decoder, doc: &[u8]) {
        let esc = &dec.esc[..];
        let top = dec.top;
        for r in 0..top.len {
            let rs = dec.rs[(top.start + r) as usize];
            let none: &[u8] = b"";
            let (mut svc, mut dep, mut pod, mut inst, mut host, mut img, mut tag) =
                (none, none, none, none, none, none, none);
            for a in 0..rs.attrs.len {
                let kv = &dec.kvs[(rs.attrs.start + a) as usize];
                let v = kv.sval.get(doc, esc);
                match kv.key.get(doc, esc) {
                    b"service.name" => svc = v,
                    b"k8s.deployment.name" => dep = v,
                    b"k8s.pod.name" => pod = v,
                    b"service.instance.id" => inst = v,
                    b"host.name" => host = v,
                    b"container.image.name" => img = v,
                    b"container.image.tag" => tag = v,
                    _ => {}
                }
            }
            if svc.is_empty() {
                svc = dep;
            }
            if pod.is_empty() {
                pod = inst;
            }
            if pod.is_empty() {
                pod = host;
            }
            resource_key(&mut self.key, svc, pod, img, tag);
            let (ri, _) = self.res.intern(&self.key);
            let no_service = svc.is_empty();
            for s in 0..rs.ss.len {
                let ss = dec.ss[(rs.ss.start + s) as usize];
                for k in 0..ss.spans.len {
                    let js = &dec.spans[(ss.spans.start + k) as usize];
                    self.reduce_span(dec, doc, js, ri as i32, no_service);
                }
            }
        }
    }

    #[inline]
    fn reduce_span(&mut self, dec: &Decoder, doc: &[u8], js: &JSpan, ri: i32, no_service: bool) {
        let esc = &dec.esc[..];
        let tr = js.trace.get(doc, esc);
        let ids = if tr.len() == 32 {
            match (
                hex_u64(&tr[..16]),
                hex_u64(&tr[16..]),
                hex_u64(js.sid.get(doc, esc)),
            ) {
                (Some(hi), Some(lo), Some(sid)) => Some(([hi, lo], sid)),
                _ => None,
            }
        } else {
            None
        };
        let Some((trace, id)) = ids else {
            self.skipped += 1;
            return;
        };
        if no_service || js.start == 0 || js.end < js.start {
            self.skipped += 1;
            return;
        }
        let parent = if js.parent.is_empty() {
            0
        } else {
            hex_u64(js.parent.get(doc, esc)).unwrap_or(0)
        };
        let attrs = &dec.kvs[js.attrs.start as usize..(js.attrs.start + js.attrs.len) as usize];
        if js.kind == KIND_SERVER as i64 && self.span_is_probe(dec, doc, js, attrs) {
            self.probes.push((trace[0], trace[1], id));
            return;
        }
        let mut sp = Span {
            trace,
            id,
            parent,
            start: js.start,
            end: js.end,
            res: ri,
            peer: -1,
            addr: -1,
            kind: js.kind as u8,
        };
        if js.kind == KIND_CLIENT as i64 {
            'keys: for key in PEER_KEYS {
                for kv in attrs {
                    let v = kv.sval.get(doc, esc);
                    if kv.key.get(doc, esc) == key && !v.is_empty() {
                        let (pi, _) = self.peers.intern(v);
                        sp.peer = pi as i32;
                        self.key.clear();
                        self.key.extend_from_slice(v);
                        for kv2 in attrs {
                            let k2 = kv2.key.get(doc, esc);
                            if k2 == b"server.port" || k2 == b"net.peer.port" {
                                let t = text(kv2, doc, esc);
                                if !t.is_empty() {
                                    self.key.push(b':');
                                    self.key.extend_from_slice(t);
                                    break;
                                }
                            }
                        }
                        let (ai, _) = self.addrs.intern(&self.key);
                        sp.addr = ai as i32;
                        break 'keys;
                    }
                }
            }
        }
        self.spans.push(sp);
    }

    fn span_is_probe(&mut self, dec: &Decoder, doc: &[u8], js: &JSpan, attrs: &[Kv]) -> bool {
        let esc = &dec.esc[..];
        let first = |keys: &[&[u8]]| -> &[u8] {
            for key in keys {
                for kv in attrs {
                    if kv.key.get(doc, esc) == *key {
                        return kv.sval.get(doc, esc);
                    }
                }
            }
            b""
        };
        let path = first(&PATH_KEYS);
        let meth = first(&METHOD_KEYS);
        let name = js.name.get(doc, esc);
        // decoded strings are valid UTF-8
        fn s(b: &[u8]) -> &str {
            std::str::from_utf8(b).unwrap_or("")
        }
        let mut route = std::mem::take(&mut self.route);
        crate::route::route_into(&mut route, s(path), s(name), s(meth));
        let probe = crate::route::is_probe(json::trim_space(&route));
        self.route = route;
        probe
    }
}

#[cfg(test)]
mod hex_tests {
    fn slow(s: &[u8]) -> Option<u64> {
        if s.len() != 16 {
            return None;
        }
        let mut v: u64 = 0;
        for &c in s {
            let d = match c {
                b'0'..=b'9' => c - b'0',
                b'a'..=b'f' => c - b'a' + 10,
                b'A'..=b'F' => c - b'A' + 10,
                _ => return None,
            };
            v = v << 4 | d as u64;
        }
        Some(v)
    }
    #[test]
    fn swar_equals_loop() {
        let mut s = *b"0123456789abcdef";
        // every byte value at every position, on a valid background
        for pos in 0..16 {
            for c in 0..=255u8 {
                let mut t = s;
                t[pos] = c;
                assert_eq!(super::hex_u64(&t), slow(&t), "{t:?}");
            }
        }
        let mut x: u64 = 0x9E37_79B9_7F4A_7C15;
        for _ in 0..200_000 {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            for (k, b) in s.iter_mut().enumerate() {
                *b = b"0123456789abcdefABCDEF"[((x >> (k * 4)) % 22) as usize];
            }
            assert_eq!(super::hex_u64(&s), slow(&s));
        }
    }
}
