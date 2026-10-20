// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
//
// go_clean below is derived from Go's src/path/path.go (Clean), Copyright The Go Authors, under the BSD-3-Clause
// licence in rust/LICENSE-GO; the rest is Apache-2.0.

//! Reading a capture: rhobound-cli's `otlp.ReadDir`, in parallel.
//!
//! Files are found and ordered as Go does. Every file is read in parallel with the others; a plain `.jsonl`
//! file is split at line ends into chunks, each read with pread(2) into a per-thread buffer and decoded in
//! parallel; a gzipped `.jsonl.gz` file is inflated by one task (gzip members are sequential) that hands
//! batches of whole lines to the pool; a `.json` or `.json.gz` file (a stream of JSON values) is read by one
//! task that finds the values (Go's json.Decoder syntax rules and errors) in a window of the stream and hands
//! batches of whole values to the pool. Memory stays near the chunks in flight, whatever the file size. Each
//! chunk yields a part with its own first-seen tables; parts are merged in capture order, so resources, peers
//! and addresses get Go's indices (first seen in capture order) and the spans Go's order. The span copy into
//! the final table and the probe-children fix-up run in parallel too.
//!
//! Files are read, not memory-mapped: a capture that shrinks while it is read (a Collector still writing it,
//! log rotation with copytruncate) gives a short read, not a SIGBUS. As in Go, such a read has no defined
//! result: the spans read so far, or a JSON error.

use crate::decode::{resource_from_key, Decoder, FxBuild, Interner, Part};
use crate::json::{self, SynErr};
use crate::{Data, Span};
use rayon::prelude::*;
use std::collections::HashSet;
use std::fs::File;
use std::io::{self, Read};
use std::mem::MaybeUninit;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;

/// How to read.
#[derive(Clone, Debug, Default)]
pub struct ReadOptions {
    /// Worker threads; 0 means one per available core (Go's default GOMAXPROCS).
    pub threads: usize,
    /// Target bytes per decode chunk; 0 picks one from the input size and the thread count.
    pub chunk_bytes: usize,
}

/// What kind of failure a read is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReadErrorKind {
    /// The path could not be examined or listed (Go: the os.Stat or os.ReadDir error).
    Path,
    /// No trace files under the path.
    NoFiles,
    /// A file could not be opened, read or decompressed, or a `.json` stream is not valid JSON.
    File,
    /// A request is not OTLP/JSON as Go's json.Unmarshal reads it.
    BadJson,
}

/// A read failure. Its text is Go's error text for the same input (see the crate notes for where it can differ).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReadError {
    pub kind: ReadErrorKind,
    /// The text, valid UTF-8 (each byte of a path that is not UTF-8 replaced by U+FFFD, as Go's encoders do).
    pub message: String,
    /// The text as Go prints it: a path that is not UTF-8 keeps its bytes.
    pub raw: Vec<u8>,
}

impl std::fmt::Display for ReadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for ReadError {}

fn err(kind: ReadErrorKind, raw: Vec<u8>) -> ReadError {
    ReadError {
        kind,
        message: rbfast_gostr::lossy(&raw),
        raw,
    }
}

/// An error text made of byte strings (paths keep their bytes, as Go prints them).
fn cat(parts: &[&[u8]]) -> Vec<u8> {
    parts.concat()
}

/// Go's text for an OS error: the C library's message with a lower-case first letter (as Go's syscall table
/// has it), without Rust's " (os error N)".
fn os_text(e: &io::Error) -> String {
    if let Some(inner) = e.get_ref() {
        if let Some(g) = inner.downcast_ref::<crate::gzip::GzError>() {
            return g.0.clone();
        }
    }
    let mut s = e.to_string();
    if let Some(k) = s.find(" (os error ") {
        s.truncate(k);
    }
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_lowercase().collect::<String>() + c.as_str(),
        None => s,
    }
}

/// [`os_text`] of an error's text: without Rust's " (os error N)", first letter in lower case.
fn os_text_str(s: &str) -> String {
    let mut s = s.to_string();
    if let Some(k) = s.find(" (os error ") {
        s.truncate(k);
    }
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_lowercase().collect::<String>() + c.as_str(),
        None => s,
    }
}

// ------------------------------------------------------------------ files

#[cfg(unix)]
fn os_bytes(p: &Path) -> Vec<u8> {
    use std::os::unix::ffi::OsStrExt;
    p.as_os_str().as_bytes().to_vec()
}

#[cfg(not(unix))]
fn os_bytes(p: &Path) -> Vec<u8> {
    p.to_string_lossy().as_bytes().to_vec()
}

#[cfg(unix)]
fn bytes_path(b: &[u8]) -> PathBuf {
    use std::os::unix::ffi::OsStrExt;
    PathBuf::from(std::ffi::OsStr::from_bytes(b))
}

#[cfg(not(unix))]
fn bytes_path(b: &[u8]) -> PathBuf {
    PathBuf::from(String::from_utf8_lossy(b).into_owned())
}

/// Go's path.Clean (filepath.Clean on '/' systems).
pub(crate) fn go_clean(path: &[u8]) -> Vec<u8> {
    if path.is_empty() {
        return b".".to_vec();
    }
    let rooted = path[0] == b'/';
    let n = path.len();
    let mut out: Vec<u8> = Vec::with_capacity(n);
    let (mut r, mut dotdot) = (0usize, 0usize);
    if rooted {
        out.push(b'/');
        r = 1;
        dotdot = 1;
    }
    while r < n {
        if path[r] == b'/' || (path[r] == b'.' && (r + 1 == n || path[r + 1] == b'/')) {
            // an empty or "." element
            r += 1;
        } else if path[r] == b'.' && path[r + 1] == b'.' && (r + 2 == n || path[r + 2] == b'/') {
            r += 2;
            if out.len() > dotdot {
                let mut w = out.len() - 1;
                while w > dotdot && out[w] != b'/' {
                    w -= 1;
                }
                out.truncate(w);
            } else if !rooted {
                if !out.is_empty() {
                    out.push(b'/');
                }
                out.extend_from_slice(b"..");
                dotdot = out.len();
            }
        } else {
            if (rooted && out.len() != 1) || (!rooted && !out.is_empty()) {
                out.push(b'/');
            }
            while r < n && path[r] != b'/' {
                out.push(path[r]);
                r += 1;
            }
        }
    }
    if out.is_empty() {
        return b".".to_vec();
    }
    out
}

fn go_join(dir: &[u8], name: &[u8]) -> Vec<u8> {
    let mut j = dir.to_vec();
    j.push(b'/');
    j.extend_from_slice(name);
    go_clean(&j)
}

/// One trace file: where to open it, and its name as Go lists it in Data.Files (bytes: Go prints them raw).
struct TraceFile {
    path: PathBuf,
    shown: Vec<u8>,
}

impl TraceFile {
    fn base(&self) -> Vec<u8> {
        // filepath.Base
        let b = os_bytes(&self.path);
        let mut s: &[u8] = &b;
        while s.len() > 1 && s.ends_with(b"/") {
            s = &s[..s.len() - 1];
        }
        match s.iter().rposition(|&c| c == b'/') {
            Some(k) if s.len() > 1 => s[k + 1..].to_vec(),
            _ => s.to_vec(),
        }
    }
    fn gz(&self) -> bool {
        os_bytes(&self.path).ends_with(b".gz")
    }
    fn lines(&self) -> bool {
        memchr::memmem::find(&self.base(), b".jsonl").is_some()
    }
}

/// Go's traceFiles: a file path as given; a folder's `traces/` subfolder if it has one; files ending in
/// .jsonl, .json, .jsonl.gz or .json.gz, sorted.
fn trace_files(path: &Path) -> Result<Vec<TraceFile>, ReadError> {
    let pb = os_bytes(path);
    let st = std::fs::metadata(path).map_err(|e| {
        err(
            ReadErrorKind::Path,
            cat(&[b"stat ", &pb, b": ", os_text(&e).as_bytes()]),
        )
    })?;
    if !st.is_dir() {
        return Ok(vec![TraceFile {
            path: path.to_path_buf(),
            shown: pb,
        }]);
    }
    let mut dir = pb.clone();
    let sub = go_join(&pb, b"traces");
    if std::fs::metadata(bytes_path(&sub))
        .map(|m| m.is_dir())
        .unwrap_or(false)
    {
        dir = sub;
    }
    let rd = std::fs::read_dir(bytes_path(&dir)).map_err(|e| {
        err(
            ReadErrorKind::Path,
            cat(&[b"open ", &dir, b": ", os_text(&e).as_bytes()]),
        )
    })?;
    let mut out: Vec<Vec<u8>> = Vec::new();
    for ent in rd {
        let ent = ent.map_err(|e| {
            err(
                ReadErrorKind::Path,
                cat(&[b"readdirent ", &dir, b": ", os_text(&e).as_bytes()]),
            )
        })?;
        let is_dir = ent.file_type().map(|t| t.is_dir()).unwrap_or(false);
        if is_dir {
            continue;
        }
        let name = os_bytes(Path::new(&ent.file_name()));
        if name.ends_with(b".jsonl")
            || name.ends_with(b".json")
            || name.ends_with(b".jsonl.gz")
            || name.ends_with(b".json.gz")
        {
            out.push(go_join(&dir, &name));
        }
    }
    out.sort();
    Ok(out
        .into_iter()
        .map(|b| TraceFile {
            path: bytes_path(&b),
            shown: b,
        })
        .collect())
}

// ------------------------------------------------------------------ reading

/// One file's outcome: its parts in order, or the read error Go would return for it (bytes: the path raw).
struct FileOut {
    parts: Vec<Part>,
    err: Option<Vec<u8>>,
}

impl FileOut {
    fn fail(e: Vec<u8>) -> FileOut {
        FileOut {
            parts: Vec::new(),
            err: Some(e),
        }
    }
}

fn open(tf: &TraceFile) -> Result<File, Vec<u8>> {
    let f = File::open(&tf.path)
        .map_err(|e| cat(&[b"open ", &tf.shown, b": ", os_text(&e).as_bytes()]))?;
    if let Ok(m) = f.metadata() {
        if m.is_dir() {
            // Go opens a directory fine and fails on the first read
            return Err(cat(&[
                &tf.shown,
                b": read ",
                &tf.shown,
                b": is a directory",
            ]));
        }
    }
    Ok(f)
}

/// Go's text for a failed read of a plain file: "PATH: read PATH: ERR" (feedFile wraps the *PathError).
fn read_err(tf: &TraceFile, e: &io::Error) -> Vec<u8> {
    cat(&[
        &tf.shown,
        b": read ",
        &tf.shown,
        b": ",
        os_text(e).as_bytes(),
    ])
}

/// Reads from `off` until `buf` is full or the file ends; the number of bytes read.
#[cfg(unix)]
fn read_at_full(f: &File, buf: &mut [u8], off: u64) -> io::Result<usize> {
    use std::os::unix::fs::FileExt;
    let mut got = 0;
    while got < buf.len() {
        match f.read_at(&mut buf[got..], off + got as u64) {
            Ok(0) => break,
            Ok(n) => got += n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
    Ok(got)
}

#[cfg(not(unix))]
fn read_at_full(f: &File, buf: &mut [u8], off: u64) -> io::Result<usize> {
    use std::io::{Seek, SeekFrom};
    let mut f = f;
    f.seek(SeekFrom::Start(off))?;
    let mut got = 0;
    while got < buf.len() {
        match f.read(&mut buf[got..]) {
            Ok(0) => break,
            Ok(n) => got += n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
    Ok(got)
}

/// Decodes the lines of `buf` (Go: every non-blank line, with its newline, is one request).
fn decode_lines(buf: &[u8]) -> Part {
    let mut part = Part::default();
    let mut dec = Decoder::default();
    decode_lines_into(&mut part, &mut dec, buf);
    part
}

/// [`decode_lines`] into an existing part.
fn decode_lines_into(part: &mut Part, dec: &mut Decoder, buf: &[u8]) {
    let mut start = 0;
    while start < buf.len() {
        let end = match memchr::memchr(b'\n', &buf[start..]) {
            Some(k) => start + k + 1,
            None => buf.len(),
        };
        let line = &buf[start..end];
        if !line_is_blank(line) {
            part.add_doc(dec, line);
            if part.err.is_some() {
                break;
            }
        }
        start = end;
    }
}

/// The read size within a chunk: small enough that the bytes are still in the core's cache when decoded.
const PIECE: usize = 512 << 10;

/// Reads bytes `a..b` of a lines file (which start and end at line ends) a piece at a time into `buf` and
/// decodes them. A line that runs past a piece is carried to the next one; a short read (the file shrank)
/// ends the range there.
fn decode_file_range(
    f: &File,
    a: u64,
    b: u64,
    piece: usize,
    buf: &mut Vec<u8>,
) -> io::Result<Part> {
    let mut part = Part::default();
    let mut dec = Decoder::default();
    let mut off = a;
    let mut carry = 0usize;
    loop {
        let want = piece.min((b - off) as usize);
        if buf.len() < carry + want {
            buf.resize(carry + want, 0);
        }
        let got = read_at_full(f, &mut buf[carry..carry + want], off)?;
        off += got as u64;
        let filled = carry + got;
        let last = got < want || off >= b;
        let cut = if last {
            filled
        } else {
            memchr::memrchr(b'\n', &buf[..filled]).map_or(0, |k| k + 1)
        };
        decode_lines_into(&mut part, &mut dec, &buf[..cut]);
        if last || part.err.is_some() {
            return Ok(part);
        }
        buf.copy_within(cut..filled, 0);
        carry = filled - cut;
    }
}

#[inline]
fn line_is_blank(line: &[u8]) -> bool {
    // fast: a line that starts (after JSON whitespace) with '{' is not blank
    let i = json::skip_ws(line, 0);
    if i < line.len() && line[i] == b'{' {
        return false;
    }
    json::is_blank(line)
}

/// Chunk boundaries of `buf` at line ends, about `target` bytes each.
fn line_chunks(buf: &[u8], target: usize) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    let mut start = 0;
    while start < buf.len() {
        let mut end = (start + target).min(buf.len());
        if end < buf.len() {
            // end after the newline at or after end-1 (a chunk that already ends a line is cut there)
            end = match memchr::memchr(b'\n', &buf[end - 1..]) {
                Some(k) => end + k,
                None => buf.len(),
            };
        }
        out.push((start, end));
        start = end;
    }
    out
}

/// Chunk boundaries of a file of `len` bytes at line ends, about `target` bytes apart: each cut is just after
/// the first newline at or after the target position (found with small reads; a cut never goes backwards, so
/// a file of one long line is searched once).
fn file_line_cuts(f: &File, len: u64, target: usize) -> io::Result<Vec<u64>> {
    let mut cuts = vec![0u64];
    let mut win = vec![0u8; 64 << 10];
    let mut k = 1u64;
    loop {
        let t = k * target as u64;
        if t >= len {
            break;
        }
        let mut at = (t - 1).max(*cuts.last().unwrap());
        let cut = loop {
            if at >= len {
                break len;
            }
            let want = win.len().min((len - at) as usize);
            let got = read_at_full(f, &mut win[..want], at)?;
            if got == 0 {
                break len; // the file shrank
            }
            if let Some(i) = memchr::memchr(b'\n', &win[..got]) {
                break at + i as u64 + 1;
            }
            at += got as u64;
        };
        if cut >= len {
            break;
        }
        if cut > *cuts.last().unwrap() {
            cuts.push(cut);
        }
        // the next target past this cut
        k = (cut / target as u64 + 1).max(k + 1);
    }
    if len > 0 {
        cuts.push(len);
    }
    Ok(cuts)
}

thread_local! {
    /// A reusable read buffer per worker thread (its pages are touched once, not once per chunk).
    static CHUNK_BUF: std::cell::RefCell<Vec<u8>> = const { std::cell::RefCell::new(Vec::new()) };
}

/// How a file is read: the size of each read (a `.json` stream's, a piece of a lines chunk), and whether small
/// files are read whole. Small steps only in tests (ReadOptions::chunk_bytes), to cut inputs everywhere.
#[derive(Clone, Copy)]
struct Steps {
    read: usize,
    piece: usize,
    whole_small: bool,
}

/// A plain lines file: cut at line ends into chunks of about `target` bytes, each read with pread into its
/// thread's buffer and decoded there, in parallel.
fn read_plain_lines(tf: &TraceFile, target: usize, steps: Steps) -> FileOut {
    let mut f = match open(tf) {
        Ok(f) => f,
        Err(e) => return FileOut::fail(e),
    };
    let len = f.metadata().map(|m| m.len()).unwrap_or(0);
    if len < 1 << 20 && steps.whole_small {
        let mut v = Vec::with_capacity(len as usize);
        if let Err(e) = f.read_to_end(&mut v) {
            return FileOut::fail(read_err(tf, &e));
        }
        let parts = line_chunks(&v, target)
            .par_iter()
            .map(|&(a, b)| decode_lines(&v[a..b]))
            .collect();
        return FileOut { parts, err: None };
    }
    let cuts = match file_line_cuts(&f, len, target) {
        Ok(c) => c,
        Err(e) => return FileOut::fail(read_err(tf, &e)),
    };
    let outs: Vec<Result<Part, io::Error>> = cuts
        .par_windows(2)
        .map(|w| {
            // a short read (the file shrank since it was measured) decodes what was read
            CHUNK_BUF
                .with(|cell| decode_file_range(&f, w[0], w[1], steps.piece, &mut cell.borrow_mut()))
        })
        .collect();
    let mut parts = Vec::with_capacity(outs.len());
    for o in outs {
        match o {
            Ok(p) => parts.push(p),
            Err(e) => return FileOut::fail(read_err(tf, &e)),
        }
    }
    FileOut { parts, err: None }
}

/// Inflates a gzipped lines file on this task and decodes batches of whole lines on the pool. At most
/// `inflight` batches wait for a worker; beyond that this task decodes the batch itself (no blocking, so it
/// works with one thread too).
fn read_gz_lines(tf: &TraceFile, target: usize, inflight: usize, waiting: &AtomicUsize) -> FileOut {
    let f = match open(tf) {
        Ok(f) => f,
        Err(e) => return FileOut::fail(e),
    };
    let mut gz = crate::gzip::GzReader::new(f);
    let results: Mutex<Vec<(usize, Part)>> = Mutex::new(Vec::new());
    let mut read_fail: Option<Vec<u8>> = None;
    rayon::scope(|s| {
        let mut idx = 0usize;
        let mut carry: Vec<u8> = Vec::new();
        let mut eof = false;
        while !eof {
            // fill a batch: at least `target` bytes, cut after the last newline
            let mut buf = std::mem::take(&mut carry);
            if buf.capacity() < target + (1 << 20) {
                buf.reserve(target + (1 << 20) - buf.len());
            }
            let mut has_nl = memchr::memchr(b'\n', &buf).is_some();
            loop {
                if has_nl && buf.len() >= target {
                    break;
                }
                let at = buf.len();
                match gz.read_vec(&mut buf, 1 << 20) {
                    Ok(0) => {
                        eof = true;
                        break;
                    }
                    Ok(_) => has_nl = has_nl || memchr::memchr(b'\n', &buf[at..]).is_some(),
                    Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                    Err(e) => {
                        read_fail = Some(cat(&[&tf.shown, b": ", os_text(&e).as_bytes()]));
                        eof = true;
                        break;
                    }
                }
            }
            if read_fail.is_some() {
                break;
            }
            if !eof {
                let cut = memchr::memrchr(b'\n', &buf).unwrap() + 1;
                carry = buf[cut..].to_vec();
                buf.truncate(cut);
            }
            if buf.is_empty() {
                continue;
            }
            dispatch(s, idx, waiting, inflight, &results, move || {
                decode_lines(&buf)
            });
            idx += 1;
        }
    });
    if let Some(e) = read_fail {
        return FileOut::fail(e);
    }
    let mut r = results.into_inner().unwrap();
    r.sort_by_key(|x| x.0);
    FileOut {
        parts: r.into_iter().map(|x| x.1).collect(),
        err: None,
    }
}

/// Runs `job` (batch number `idx`) on the pool, or here when `inflight` batches already wait for a worker.
fn dispatch<'s, T: Send + 's, F: FnOnce() -> T + Send + 's>(
    s: &rayon::Scope<'s>,
    idx: usize,
    waiting: &'s AtomicUsize,
    inflight: usize,
    results: &'s Mutex<Vec<(usize, T)>>,
    job: F,
) {
    if waiting.load(Ordering::Acquire) >= inflight {
        let p = job();
        results.lock().unwrap().push((idx, p));
    } else {
        waiting.fetch_add(1, Ordering::AcqRel);
        s.spawn(move |_| {
            waiting.fetch_sub(1, Ordering::AcqRel);
            let p = job();
            results.lock().unwrap().push((idx, p));
        });
    }
}

/// The byte source of a `.json` stream: the file, or its gzip stream.
enum Src {
    Plain(File),
    Gz(Box<crate::gzip::GzReader<File>>),
}

impl Src {
    /// Appends up to `room` more bytes to `v`; 0 at the end of the stream.
    fn read_more(&mut self, v: &mut Vec<u8>, room: usize) -> io::Result<usize> {
        match self {
            Src::Gz(g) => g.read_vec(v, room),
            Src::Plain(f) => {
                let at = v.len();
                v.resize(at + room, 0);
                let r = f.read(&mut v[at..]);
                v.truncate(at + *r.as_ref().unwrap_or(&0));
                r
            }
        }
    }
}

/// A `.json` file (or `.json.gz`): any number of whitespace-separated (or adjacent) top-level JSON values, as
/// Go's json.Decoder reads them; each value is one request.
///
/// First the fast path, [`read_json_batches`]; when it cannot vouch for its result (a syntax error, a read or
/// gzip error, a stream it cannot cut), the file is read again by [`read_json_serial`], whose values and errors
/// are those of a serial scan of the whole stream: Go's.
fn read_json_stream(
    tf: &TraceFile,
    target: usize,
    step: usize,
    inflight: usize,
    waiting: &AtomicUsize,
) -> FileOut {
    match read_json_batches(tf, target, step, inflight, waiting) {
        Some(out) => out,
        None => read_json_serial(tf, target, step, inflight, waiting),
    }
}

/// The most a batch of a `.json` stream may grow while no place to cut it is found; beyond it the stream is
/// read by the serial path.
const MAX_JSON_BATCH: usize = 64 << 20;

/// Where a batch of a `.json` stream may end: just after the last newline that a '{' follows (in valid JSON a
/// newline is never inside a string, and a value written one per line, or pretty-printed, starts a line with
/// '{' only at the top level). None when there is no such place.
fn json_cut(b: &[u8]) -> Option<usize> {
    memchr::memmem::rfind(b, b"\n{").map(|k| k + 1)
}

/// Finds the values of a batch from its start (a value boundary) and decodes them. Some(part) only when the
/// batch is clean: whole values to its end (then only white space), with no syntax error; a value may end at the
/// very end only in the stream's last batch.
fn scan_decode_batch(buf: &[u8], last: bool) -> Option<Part> {
    let mut part = Part::default();
    let mut dec = Decoder::default();
    let mut stack = Vec::new();
    let mut i = 0;
    loop {
        i = json::skip_ws(buf, i);
        if i >= buf.len() {
            return Some(part);
        }
        match json::skip_value(buf, i, 0, &mut stack) {
            Ok(end) if end < buf.len() || last => {
                part.add_doc(&mut dec, &buf[i..end]);
                i = end;
            }
            _ => return None,
        }
    }
}

/// The fast path for a `.json` stream: one task reads it (read or inflate) and cuts it, without scanning, into
/// batches of about `target` bytes at places where a top-level value is likely to start ([`json_cut`]); the
/// batches are scanned and decoded in parallel (at most `inflight` waiting). Batch 0 starts at the stream's
/// start, and a batch that is clean ([`scan_decode_batch`]) ends where the next value starts, so when every
/// batch is clean the values are exactly those of a serial scan. None when one is not, or the stream cannot be
/// read or cut: the caller then reads the file serially (which also finds Go's error, if there is one).
fn read_json_batches(
    tf: &TraceFile,
    target: usize,
    step: usize,
    inflight: usize,
    waiting: &AtomicUsize,
) -> Option<FileOut> {
    let f = match open(tf) {
        Ok(f) => f,
        Err(e) => return Some(FileOut::fail(e)),
    };
    let mut src = if tf.gz() {
        Src::Gz(Box::new(crate::gzip::GzReader::new(f)))
    } else {
        Src::Plain(f)
    };
    let results: Mutex<Vec<(usize, Option<Part>)>> = Mutex::new(Vec::new());
    let bad = std::sync::atomic::AtomicBool::new(false);
    let mut give_up = false;
    rayon::scope(|s| {
        let mut idx = 0usize;
        let mut carry: Vec<u8> = Vec::new();
        let mut eof = false;
        while !eof && !bad.load(Ordering::Relaxed) {
            let mut buf = std::mem::take(&mut carry);
            if buf.capacity() < target + step {
                buf.reserve(target + step - buf.len());
            }
            loop {
                if buf.len() >= target && json_cut(&buf).is_some() {
                    break;
                }
                if buf.len() > MAX_JSON_BATCH {
                    give_up = true;
                    break;
                }
                match src.read_more(&mut buf, step) {
                    Ok(0) => {
                        eof = true;
                        break;
                    }
                    Ok(_) => {}
                    Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                    Err(_) => {
                        // the serial path reports it, after any syntax error in the bytes before it
                        give_up = true;
                        break;
                    }
                }
            }
            if give_up {
                break;
            }
            if !eof {
                let cut = json_cut(&buf).expect("a cut was found");
                carry = buf[cut..].to_vec();
                buf.truncate(cut);
            }
            let last = eof;
            let bad = &bad;
            dispatch(s, idx, waiting, inflight, &results, move || {
                let p = scan_decode_batch(&buf, last);
                if p.is_none() {
                    bad.store(true, Ordering::Relaxed);
                }
                p
            });
            idx += 1;
        }
    });
    if give_up || bad.load(Ordering::Relaxed) {
        return None;
    }
    let mut r = results.into_inner().unwrap();
    r.sort_by_key(|x| x.0);
    let parts: Option<Vec<Part>> = r.into_iter().map(|x| x.1).collect();
    Some(FileOut {
        parts: parts?,
        err: None,
    })
}

/// The serial path for a `.json` stream (see [`read_json_stream`]).
///
/// One task reads the stream into a window and finds the values in it with Go's syntax rules (json::skip_value,
/// as the decoder's own scan); batches of about `target` bytes of whole values are cut off the front of the
/// window and decoded on the pool (at most `inflight` waiting, as for gzipped lines). A value is taken as
/// complete only when a byte follows it or the stream has ended, and a syntax error near the end of the window
/// is confirmed with more input, so the values and the error are those of a scan of the whole stream: Go's.
/// As with Go's decoder, a syntax error in the bytes read comes before a read (or gzip) error, which is
/// reported when the scan needs more input.
fn read_json_serial(
    tf: &TraceFile,
    target: usize,
    step: usize,
    inflight: usize,
    waiting: &AtomicUsize,
) -> FileOut {
    let f = match open(tf) {
        Ok(f) => f,
        Err(e) => return FileOut::fail(e),
    };
    let gz = tf.gz();
    let mut src = if gz {
        Src::Gz(Box::new(crate::gzip::GzReader::new(f)))
    } else {
        Src::Plain(f)
    };
    let results: Mutex<Vec<(usize, Part)>> = Mutex::new(Vec::new());
    let mut fail: Option<Vec<u8>> = None;
    rayon::scope(|s| {
        let mut idx = 0usize;
        let mut win: Vec<u8> = Vec::with_capacity(target + step);
        let mut values: Vec<(usize, usize)> = Vec::new();
        let mut stack = Vec::new();
        let mut pos = 0usize; // where the scan stands in win (the end of the last value found)
        let mut ended = false; // the stream has no more bytes (or failed: src_err)
        let mut src_err: Option<Vec<u8>> = None;
        let mut confirm = false; // a syntax error waits for more input before it is reported
        loop {
            // what the scan needs next: Ok(None) a value was found, Ok(Some(room)) more input
            let next: Result<Option<usize>, Vec<u8>> = {
                let i = json::skip_ws(&win, pos);
                if i >= win.len() {
                    if ended {
                        break;
                    }
                    Ok(Some(step))
                } else {
                    match json::skip_value(&win, i, 0, &mut stack) {
                        Ok(end) if end < win.len() || ended => {
                            values.push((i, end));
                            pos = end;
                            confirm = false;
                            Ok(None)
                        }
                        // a value that ends the window could go on (a number): look one byte further
                        Ok(_) => Ok(Some(step)),
                        Err(SynErr::Eof) => {
                            if ended {
                                Err(src_err
                                    .clone()
                                    .unwrap_or_else(|| cat(&[&tf.shown, b": unexpected EOF"])))
                            } else {
                                // read at least as much again as the unfinished value holds (so a huge value
                                // is rescanned a few times only)
                                Ok(Some((win.len() - i).max(step)))
                            }
                        }
                        Err(SynErr::Msg(m)) => {
                            if ended || confirm {
                                Err(cat(&[&tf.shown, b": ", m.as_bytes()]))
                            } else {
                                // the error's text quotes the character found, which may continue past the
                                // window: read on, then scan the value again
                                confirm = true;
                                Ok(Some(step))
                            }
                        }
                    }
                }
            };
            match next {
                Err(e) => {
                    fail = Some(e);
                    break;
                }
                Ok(None) => {
                    if pos >= target {
                        // cut the values found so far off the front of the window into a batch
                        let rest = win[pos..].to_vec();
                        let mut batch = std::mem::replace(&mut win, rest);
                        batch.truncate(pos);
                        let vals = std::mem::take(&mut values);
                        pos = 0;
                        dispatch(s, idx, waiting, inflight, &results, move || {
                            decode_values(&batch, &vals)
                        });
                        idx += 1;
                        if win.capacity() < target + step {
                            win.reserve(target + step - win.len());
                        }
                    }
                }
                Ok(Some(room)) => {
                    // (never at the end of the stream: there every outcome above is final)
                    debug_assert!(!ended);
                    loop {
                        match src.read_more(&mut win, room) {
                            Ok(0) => ended = true,
                            Ok(_) => {}
                            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                            Err(e) => {
                                ended = true;
                                src_err = Some(if gz {
                                    cat(&[&tf.shown, b": ", os_text(&e).as_bytes()])
                                } else {
                                    read_err(tf, &e)
                                });
                            }
                        }
                        break;
                    }
                }
            }
        }
        if fail.is_none() {
            if let Some(e) = src_err {
                // the scan ended cleanly on the bytes read, but the stream failed after them
                fail = Some(e);
            } else if !values.is_empty() {
                win.truncate(pos);
                let vals = std::mem::take(&mut values);
                dispatch(s, idx, waiting, inflight, &results, move || {
                    decode_values(&win, &vals)
                });
            }
        }
    });
    if let Some(e) = fail {
        return FileOut::fail(e);
    }
    let mut r = results.into_inner().unwrap();
    r.sort_by_key(|x| x.0);
    FileOut {
        parts: r.into_iter().map(|x| x.1).collect(),
        err: None,
    }
}

/// How much of a `.json` stream is read at a time: small next to a batch, since the bytes read past a batch's
/// last value are copied into the next window.
const READ_STEP: usize = 256 << 10;

/// Decodes the values of a `.json` batch (each one request), in order.
fn decode_values(buf: &[u8], values: &[(usize, usize)]) -> Part {
    let mut part = Part::default();
    let mut dec = Decoder::default();
    for &(a, z) in values {
        part.add_doc(&mut dec, &buf[a..z]);
        if part.err.is_some() {
            break;
        }
    }
    part
}

/// Reads a capture as rhobound-cli's `otlp.ReadDir` does, using every core: CAPTURE/traces/*.jsonl, *.json and
/// their .gz forms; a folder of trace files, or a single file, is accepted too.
pub fn read_dir(path: impl AsRef<Path>) -> Result<Data, ReadError> {
    read_dir_with(path, &ReadOptions::default())
}

/// Reads one trace file whatever its name (Go's ReadDir given a file path): lines when its name contains
/// ".jsonl", else a stream of JSON values; gzip when it ends in ".gz".
pub fn read_file(path: impl AsRef<Path>) -> Result<Data, ReadError> {
    read_dir_with(path, &ReadOptions::default())
}

/// [`read_dir`] with options (thread count, chunk size).
pub fn read_dir_with(path: impl AsRef<Path>, opts: &ReadOptions) -> Result<Data, ReadError> {
    let mut st = Stages::new();
    let path = path.as_ref();
    let files = trace_files(path)?;
    st.mark("list files");
    if files.is_empty() {
        return Err(err(
            ReadErrorKind::NoFiles,
            cat(&[
                b"no trace files (*.jsonl, *.json, *.gz) under ",
                &os_bytes(path),
            ]),
        ));
    }
    let threads = if opts.threads > 0 {
        opts.threads
    } else {
        std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(1)
    };
    let pool = rayon::ThreadPoolBuilder::new()
        .num_threads(threads)
        .thread_name(|i| format!("rbfast-otlp-{i}"))
        .build()
        .map_err(|e| {
            err(
                ReadErrorKind::File,
                format!("thread pool: {}", os_text_str(&e.to_string())).into_bytes(),
            )
        })?;
    st.mark("thread pool");
    let r = pool.install(|| read_files(files, opts, threads, &mut st));
    drop(pool);
    st.mark("pool shutdown");
    st.print();
    r
}

/// Stage timers, printed to stderr when RBFAST_OTLP_STAGES is set.
struct Stages {
    on: bool,
    t: std::time::Instant,
    t0: std::time::Instant,
    out: String,
}

impl Stages {
    fn new() -> Self {
        let now = std::time::Instant::now();
        Stages {
            on: std::env::var_os("RBFAST_OTLP_STAGES").is_some(),
            t: now,
            t0: now,
            out: String::new(),
        }
    }
    fn mark(&mut self, what: &str) {
        if self.on {
            let now = std::time::Instant::now();
            self.out.push_str(&format!(
                " {}={:.4}",
                what.replace(' ', "_"),
                (now - self.t).as_secs_f64()
            ));
            self.t = now;
        }
    }
    fn print(&self) {
        if self.on {
            eprintln!(
                "RBFAST_OTLP_STAGES total={:.4}{}",
                self.t0.elapsed().as_secs_f64(),
                self.out
            );
        }
    }
}

fn read_files(
    files: Vec<TraceFile>,
    opts: &ReadOptions,
    threads: usize,
    st: &mut Stages,
) -> Result<Data, ReadError> {
    let total: u64 = files
        .iter()
        .map(|f| std::fs::metadata(&f.path).map(|m| m.len()).unwrap_or(0))
        .sum();
    let target = if opts.chunk_bytes > 0 {
        opts.chunk_bytes
    } else {
        ((total / (threads as u64 * 8).max(1)) as usize).clamp(256 << 10, 8 << 20)
    };
    let gz_target = target.max(1 << 20);
    // a .json stream's batches: large next to its reads (READ_STEP), whose overshoot is copied per batch (a
    // chunk size given in the options is taken as it is, so that tests can cut streams into many batches)
    let json_target = if opts.chunk_bytes > 0 {
        target
    } else {
        4 << 20
    };
    let steps = if opts.chunk_bytes > 0 {
        let k = opts.chunk_bytes.min(READ_STEP);
        Steps {
            read: k,
            piece: k.min(PIECE),
            whole_small: false,
        }
    } else {
        Steps {
            read: READ_STEP,
            piece: PIECE,
            whole_small: true,
        }
    };
    // batches of inflated lines or stream values waiting for a worker, over all such files: bounds the memory
    // they hold
    let gz_waiting = AtomicUsize::new(0);
    let outs: Vec<FileOut> = files
        .par_iter()
        .map(|tf| {
            if tf.lines() {
                if tf.gz() {
                    read_gz_lines(tf, gz_target, 2 * threads, &gz_waiting)
                } else {
                    read_plain_lines(tf, target, steps)
                }
            } else {
                read_json_stream(tf, json_target, steps.read, 2 * threads, &gz_waiting)
            }
        })
        .collect();
    st.mark("decode");
    // Go: a read error (the first file in order that fails) wins over a request that does not decode
    for o in &outs {
        if let Some(e) = &o.err {
            return Err(err(ReadErrorKind::File, e.clone()));
        }
    }
    let parts: Vec<Part> = outs.into_iter().flat_map(|o| o.parts).collect();
    for p in &parts {
        if let Some(e) = &p.err {
            return Err(err(
                ReadErrorKind::BadJson,
                format!("bad OTLP/JSON: {e}").into_bytes(),
            ));
        }
    }
    Ok(merge(
        parts,
        files
            .into_iter()
            .map(|f| rbfast_gostr::lossy(&f.shown))
            .collect(),
        st,
    ))
}

/// Merges parts in capture order: Go's tables (first seen) and span order.
fn merge(mut parts: Vec<Part>, files: Vec<String>, st: &mut Stages) -> Data {
    let mut res = Interner::default();
    let mut peers = Interner::default();
    let mut addrs = Interner::default();
    let mut maps: Vec<(Vec<i32>, Vec<i32>, Vec<i32>)> = Vec::with_capacity(parts.len());
    let (mut skipped, mut probes) = (0usize, 0usize);
    let mut probe_keys: Vec<(u64, u64, u64)> = Vec::new();
    for p in &mut parts {
        let m = |own: &Interner, global: &mut Interner| -> Vec<i32> {
            own.keys.iter().map(|k| global.intern(k).0 as i32).collect()
        };
        maps.push((
            m(&p.res, &mut res),
            m(&p.peers, &mut peers),
            m(&p.addrs, &mut addrs),
        ));
        skipped += p.skipped;
        probes += p.probes.len();
        probe_keys.append(&mut p.probes);
    }
    st.mark("intern");
    let total: usize = parts.iter().map(|p| p.spans.len()).sum();
    let mut spans: Vec<Span> = Vec::with_capacity(total);
    {
        // Each part's spans are freed as soon as they are copied, so the peak is about one span table, not two
        // (the destination's pages are only touched as they are written).
        let mut rest: &mut [MaybeUninit<Span>] = &mut spans.spare_capacity_mut()[..total];
        let mut jobs = Vec::with_capacity(parts.len());
        for (p, m) in parts.into_iter().zip(&maps) {
            let (mine, tail) = rest.split_at_mut(p.spans.len());
            rest = tail;
            jobs.push((mine, p.spans, m));
        }
        jobs.into_par_iter().for_each(|(dst, src, (rm, pm, am))| {
            for (d, s) in dst.iter_mut().zip(src.iter()) {
                let mut sp = *s;
                sp.res = rm[sp.res as usize];
                if sp.peer >= 0 {
                    sp.peer = pm[sp.peer as usize];
                }
                if sp.addr >= 0 {
                    sp.addr = am[sp.addr as usize];
                }
                d.write(sp);
            }
            drop(src);
        });
    }
    // SAFETY: every one of the `total` slots was written above (the parts' lengths sum to `total`).
    unsafe { spans.set_len(total) };
    st.mark("copy spans");

    let mut probe_children = 0;
    if probes > 0 {
        let set: HashSet<(u64, u64, u64), FxBuild> = probe_keys.into_iter().collect();
        probe_children = spans
            .par_chunks_mut(1 << 16)
            .map(|ch| {
                let mut n = 0;
                for sp in ch {
                    if sp.parent != 0 && set.contains(&(sp.trace[0], sp.trace[1], sp.parent)) {
                        sp.parent = 0;
                        n += 1;
                    }
                }
                n
            })
            .sum();
    }
    st.mark("probe fixup");
    let strs = |t: Interner| -> Vec<String> {
        t.keys
            .into_iter()
            .map(|k| {
                String::from_utf8(k.into_vec())
                    .unwrap_or_else(|e| String::from_utf8_lossy(e.as_bytes()).into_owned())
            })
            .collect()
    };
    Data {
        spans,
        resources: res.keys.iter().map(|k| resource_from_key(k)).collect(),
        peers: strs(peers),
        addrs: strs(addrs),
        skipped,
        probes,
        probe_children,
        files,
    }
}

/// Benchmark helper (not part of the API): inflates a gzip file with the reader's gzip code and returns the
/// inflated size. `into_vec` inflates into a growing buffer's spare capacity (as the reader does), else
/// through Read::read into a 1 MiB buffer.
#[doc(hidden)]
pub fn bench_inflate(path: &Path, into_vec: bool) -> io::Result<u64> {
    let mut gz = crate::gzip::GzReader::new(File::open(path)?);
    let mut total = 0u64;
    if into_vec {
        let mut v = Vec::with_capacity(9 << 20);
        loop {
            v.clear();
            while v.len() < (8 << 20) {
                if gz.read_vec(&mut v, 1 << 20)? == 0 {
                    break;
                }
            }
            if v.is_empty() {
                return Ok(total);
            }
            total += v.len() as u64;
        }
    }
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = gz.read(&mut buf)?;
        if n == 0 {
            return Ok(total);
        }
        total += n as u64;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clean() {
        let c = |s: &str| String::from_utf8(go_clean(s.as_bytes())).unwrap();
        assert_eq!(c("a/b/../c/./d//"), "a/c/d");
        assert_eq!(c("/../a"), "/a");
        assert_eq!(c("../../a/.."), "../..");
        assert_eq!(c(""), ".");
        assert_eq!(c("./"), ".");
        assert_eq!(c("/"), "/");
        assert_eq!(c("a/traces"), "a/traces");
        assert_eq!(c("a/b/.."), "a");
        assert_eq!(c("/a/b/../../.."), "/");
        assert_eq!(c("a/../../b"), "../b");
        assert_eq!(c("//x//y/"), "/x/y");
    }

    #[test]
    fn chunks_at_lines() {
        let b = b"aaaa\nbb\ncccccc\nd";
        let ch = line_chunks(b, 3);
        assert_eq!(ch, vec![(0, 5), (5, 8), (8, 15), (15, 16)]);
        let ch = line_chunks(b, 100);
        assert_eq!(ch, vec![(0, 16)]);
    }
}
