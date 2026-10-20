// SPDX-License-Identifier: Apache-2.0

//! The span table, field for field as rhobound-cli's Go `internal/otlp` (otlp.Span, otlp.Resource, otlp.Data).
//! Builders: keep these types and their meaning identical to the Go ones; add fields only with a reason.
//!
//! The reader ([`read_dir`], [`read_dir_with`], [`read_file`]) is a parallel port of Go's `otlp.ReadDir`: the
//! same files in the same order, the same JSON rules (Go 1.27's encoding/json with its v1 options), the same
//! skipping, probe and interning rules, the same span order and table indices. See `reader.rs` and
//! `decode.rs` for how it is parallel and what is kept from Go.

mod decode;
pub mod dump;
mod gonum;
mod gzip;
mod json;
mod reader;
mod route;

#[doc(hidden)]
pub use reader::bench_inflate;
pub use reader::{read_dir, read_dir_with, read_file, ReadError, ReadErrorKind, ReadOptions};
pub use route::is_probe;

/// Checks that `doc` is one JSON value (with optional white space around it), as Go's `json.Unmarshal` checks
/// its input before decoding: Ok, or Go's syntax error text (`invalid character '}' looking for beginning of
/// value`, `unexpected end of JSON input`, ...). Used by the CLI for topology files, so that a syntax error
/// reads as rhobound's does.
pub fn check_json_syntax(doc: &[u8]) -> Result<(), String> {
    let eof = || "unexpected end of JSON input".to_string();
    let i = json::skip_ws(doc, 0);
    if i >= doc.len() {
        return Err(eof());
    }
    let mut stack = Vec::new();
    match json::skip_value(doc, i, 0, &mut stack) {
        Err(json::SynErr::Eof) => Err(eof()),
        Err(json::SynErr::Msg(m)) => Err(m),
        Ok(end) => {
            let j = json::skip_ws(doc, end);
            if j < doc.len() {
                match json::invalid_char(doc, j, json::W_TOP) {
                    json::SynErr::Msg(m) => Err(m),
                    json::SynErr::Eof => Err(eof()),
                }
            } else {
                Ok(())
            }
        }
    }
}

/// Span kinds, as OTLP numbers them (the Go constants KindInternal..KindConsumer).
pub const KIND_INTERNAL: u8 = 1;
pub const KIND_SERVER: u8 = 2;
pub const KIND_CLIENT: u8 = 3;
pub const KIND_PRODUCER: u8 = 4;
pub const KIND_CONSUMER: u8 = 5;

/// One span. Times are Unix nanoseconds. Mirrors Go's otlp.Span.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Span {
    pub trace: [u64; 2],
    pub id: u64,
    /// 0 when the span has no parent.
    pub parent: u64,
    pub start: u64,
    pub end: u64,
    /// Index into Data::resources.
    pub res: i32,
    /// Index into Data::peers for client spans, else -1.
    pub peer: i32,
    /// Index into Data::addrs ("peer:port") for client spans with a peer, else -1.
    pub addr: i32,
    pub kind: u8,
}

impl Span {
    /// Duration in milliseconds (0 when end < start), as Go's Span.Dur.
    pub fn dur_ms(&self) -> f64 {
        if self.end < self.start {
            0.0
        } else {
            (self.end - self.start) as f64 / 1e6
        }
    }
}

/// Who emitted a span. Mirrors Go's otlp.Resource.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct Resource {
    /// service.name, else k8s.deployment.name
    pub service: String,
    /// k8s.pod.name, else service.instance.id, else host.name
    pub pod: String,
    /// container.image.name[:tag]
    pub image: String,
}

/// Everything read from one capture. Mirrors Go's otlp.Data.
#[derive(Clone, Debug, Default)]
pub struct Data {
    pub spans: Vec<Span>,
    pub resources: Vec<Resource>,
    pub peers: Vec<String>,
    pub addrs: Vec<String>,
    /// Spans dropped for a missing id, service, start or end.
    pub skipped: usize,
    /// Health and readiness probe spans dropped.
    pub probes: usize,
    /// Spans whose parent was a dropped probe; they are roots now (parent 0).
    pub probe_children: usize,
    pub files: Vec<String>,
}
