// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Derived from Go's src/compress/gzip/gunzip.go (readHeader, the multistream rules and error texts), Copyright The Go
// Authors, under the BSD-3-Clause licence in rust/LICENSE-GO; the rest is Apache-2.0.

//! A gzip reader with Go's `compress/gzip` rules (multistream on): members follow each other until the input
//! ends exactly at a member boundary; an empty input is the error `EOF`; a short header, body or trailer is
//! `unexpected EOF`; a bad magic number, method or header CRC is `gzip: invalid header`; a CRC-32 or size
//! mismatch is `gzip: invalid checksum`. Deflate data is decoded by flate2 (raw inflate); a corrupt stream is
//! reported as Go words it (`flate: corrupt input before offset N`, where N here is the compressed bytes of the
//! member's deflate data consumed so far: an approximation of Go's offset).

use flate2::{Crc, Decompress, FlushDecompress, Status};
use std::io::{self, Read};

const IN_BUF: usize = 256 << 10;

/// The error texts Go's gzip reader returns.
#[derive(Debug)]
pub(crate) struct GzError(pub String);

impl std::fmt::Display for GzError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for GzError {}

fn gz_err(s: &str) -> io::Error {
    io::Error::other(GzError(s.to_string()))
}

#[derive(PartialEq, Eq)]
enum State {
    Header { first: bool },
    Body,
    Done,
}

pub(crate) struct GzReader<R: Read> {
    inner: R,
    buf: Vec<u8>,
    pos: usize,
    end: usize,
    inner_eof: bool,
    dec: Decompress,
    crc: Crc,
    state: State,
    member_in_start: u64,
    failed: Option<String>,
}

impl<R: Read> GzReader<R> {
    pub(crate) fn new(inner: R) -> Self {
        GzReader {
            inner,
            buf: vec![0; IN_BUF],
            pos: 0,
            end: 0,
            inner_eof: false,
            dec: Decompress::new(false),
            crc: Crc::new(),
            state: State::Header { first: true },
            member_in_start: 0,
            failed: None,
        }
    }

    /// Makes at least one byte available unless the input has ended. Returns false at the end.
    fn fill(&mut self) -> io::Result<bool> {
        if self.pos < self.end {
            return Ok(true);
        }
        if self.inner_eof {
            return Ok(false);
        }
        self.pos = 0;
        self.end = 0;
        loop {
            match self.inner.read(&mut self.buf) {
                Ok(0) => {
                    self.inner_eof = true;
                    return Ok(false);
                }
                Ok(n) => {
                    self.end = n;
                    return Ok(true);
                }
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(e),
            }
        }
    }

    fn byte(&mut self) -> io::Result<Option<u8>> {
        if !self.fill()? {
            return Ok(None);
        }
        let c = self.buf[self.pos];
        self.pos += 1;
        Ok(Some(c))
    }

    /// io.ReadFull: Ok(n) with n < want only at the end of input.
    fn read_full(&mut self, out: &mut [u8]) -> io::Result<usize> {
        let mut n = 0;
        while n < out.len() {
            match self.byte()? {
                Some(c) => {
                    out[n] = c;
                    n += 1;
                }
                None => break,
            }
        }
        Ok(n)
    }

    /// Go's readHeader. Returns Ok(false) when the input ends cleanly before a header (not for the first one).
    fn header(&mut self, first: bool) -> io::Result<bool> {
        let mut h = [0u8; 10];
        let n = self.read_full(&mut h)?;
        if n == 0 {
            if first {
                return Err(gz_err("EOF"));
            }
            return Ok(false);
        }
        if n < 10 {
            return Err(gz_err("unexpected EOF"));
        }
        if h[0] != 0x1f || h[1] != 0x8b || h[2] != 8 {
            return Err(gz_err("gzip: invalid header"));
        }
        let flg = h[3];
        let mut digest = Crc::new();
        digest.update(&h);
        if flg & 4 != 0 {
            let mut l = [0u8; 2];
            if self.read_full(&mut l)? < 2 {
                return Err(gz_err("unexpected EOF"));
            }
            digest.update(&l);
            let len = u16::from_le_bytes(l) as usize;
            let mut data = vec![0u8; len];
            if self.read_full(&mut data)? < len {
                return Err(gz_err("unexpected EOF"));
            }
            digest.update(&data);
        }
        for flag in [8u8, 16u8] {
            if flg & flag != 0 {
                // readString: at most 511 bytes and a NUL (Go's 512-byte buffer)
                let mut i = 0;
                loop {
                    if i >= 512 {
                        return Err(gz_err("gzip: invalid header"));
                    }
                    let Some(c) = self.byte()? else {
                        return Err(gz_err("unexpected EOF"));
                    };
                    digest.update(&[c]);
                    if c == 0 {
                        break;
                    }
                    i += 1;
                }
            }
        }
        if flg & 2 != 0 {
            let mut l = [0u8; 2];
            if self.read_full(&mut l)? < 2 {
                return Err(gz_err("unexpected EOF"));
            }
            if u16::from_le_bytes(l) != (digest.sum() & 0xffff) as u16 {
                return Err(gz_err("gzip: invalid header"));
            }
        }
        self.dec.reset(false);
        self.crc.reset();
        self.member_in_start = self.dec.total_in();
        Ok(true)
    }

    fn trailer(&mut self) -> io::Result<()> {
        let mut t = [0u8; 8];
        if self.read_full(&mut t)? < 8 {
            return Err(gz_err("unexpected EOF"));
        }
        let crc = u32::from_le_bytes(t[..4].try_into().unwrap());
        let size = u32::from_le_bytes(t[4..].try_into().unwrap());
        if crc != self.crc.sum() || size != self.crc.amount() {
            return Err(gz_err("gzip: invalid checksum"));
        }
        Ok(())
    }

    fn read_inner(&mut self, mut out: Out) -> io::Result<usize> {
        loop {
            match self.state {
                State::Done => return Ok(0),
                State::Header { first } => {
                    if self.header(first)? {
                        self.state = State::Body;
                    } else {
                        self.state = State::Done;
                        return Ok(0);
                    }
                }
                State::Body => {
                    let have_input = self.fill()?;
                    let input = &self.buf[self.pos..self.end];
                    let (in0, out0) = (self.dec.total_in(), self.dec.total_out());
                    let st = match &mut out {
                        Out::Slice(o) => self.dec.decompress(input, o, FlushDecompress::None),
                        Out::Vec(v) => self.dec.decompress_vec(input, v, FlushDecompress::None),
                    };
                    let used = (self.dec.total_in() - in0) as usize;
                    let made = (self.dec.total_out() - out0) as usize;
                    self.pos += used;
                    match &out {
                        Out::Slice(o) => self.crc.update(&o[..made]),
                        Out::Vec(v) => self.crc.update(&v[v.len() - made..]),
                    }
                    match st {
                        Ok(Status::StreamEnd) => {
                            if let Err(e) = self.trailer() {
                                // Go hands over the member's last bytes with the error; the error comes next
                                if made > 0 {
                                    self.failed = Some(e.to_string());
                                    return Ok(made);
                                }
                                return Err(e);
                            }
                            self.state = State::Header { first: false };
                            if made > 0 {
                                return Ok(made);
                            }
                        }
                        Ok(_) => {
                            if made > 0 {
                                return Ok(made);
                            }
                            if !have_input && used == 0 {
                                return Err(gz_err("unexpected EOF"));
                            }
                            if used == 0 && made == 0 && out.room() == 0 {
                                return Ok(0);
                            }
                        }
                        Err(_) => {
                            let off = self.dec.total_in() - self.member_in_start;
                            let msg = format!("flate: corrupt input before offset {}", off);
                            if made > 0 {
                                self.failed = Some(msg);
                                return Ok(made);
                            }
                            return Err(gz_err(&msg));
                        }
                    }
                }
            }
        }
    }
}

/// Where inflated bytes go: a caller's slice, or the spare capacity of a Vec (no zero-filling).
enum Out<'a> {
    Slice(&'a mut [u8]),
    Vec(&'a mut Vec<u8>),
}

impl Out<'_> {
    fn room(&self) -> usize {
        match self {
            Out::Slice(o) => o.len(),
            Out::Vec(v) => v.capacity() - v.len(),
        }
    }
}

impl<R: Read> GzReader<R> {
    fn read_out(&mut self, out: Out) -> io::Result<usize> {
        if let Some(e) = &self.failed {
            return Err(gz_err(e));
        }
        match self.read_inner(out) {
            Ok(n) => Ok(n),
            Err(e) => {
                self.failed = Some(e.to_string());
                Err(e)
            }
        }
    }

    /// Appends inflated bytes to `v` after reserving at least `room` bytes of spare capacity, filling as much of
    /// the spare capacity as the input allows; Ok(0) at the end of the input (as Read::read).
    pub(crate) fn read_vec(&mut self, v: &mut Vec<u8>, room: usize) -> io::Result<usize> {
        v.reserve(room);
        self.read_out(Out::Vec(v))
    }
}

impl<R: Read> Read for GzReader<R> {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        self.read_out(Out::Slice(out))
    }
}
