// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Derived from Go's src/text/tabwriter/tabwriter.go, Copyright The Go Authors, under the BSD-3-Clause licence in
// rust/LICENSE-GO; the rest is Apache-2.0.

//! Go's text/tabwriter, ported from Go 1.27's tabwriter.go (Write, Flush, format, writeLines, the escape and
//! cell handling) for the report's options: a space as the padding character, the AlignRight flag or none, no
//! other flags (no FilterHTML, StripEscape, DiscardEmptyColumns, TabIndent or Debug). It works on bytes, as Go
//! does: '\t' and '\v' end a cell, '\n' and '\f' end a line, a line of one cell (and every '\f') flushes, the
//! Escape byte 0xff starts and ends a section written as is, and widths count runes with utf8.RuneCount (an
//! invalid byte is one rune).
//!
//! Ported from Go's src/text/tabwriter/tabwriter.go: Copyright 2009 The Go Authors. All rights reserved. Use
//! of this source code is governed by a BSD-style license (rust/LICENSE-GO).

/// tabwriter.Escape.
const ESCAPE: u8 = 0xff;

#[derive(Clone, Copy, Default)]
struct Cell {
    /// cell size in bytes
    size: usize,
    /// cell width in runes
    width: usize,
    /// true if the cell is terminated by an htab ('\t')
    htab: bool,
}

pub struct TabWriter {
    minwidth: usize,
    padding: usize,
    align_right: bool,
    /// collected text excluding tabs or line breaks
    buf: Vec<u8>,
    /// buffer position up to which cell.width of incomplete cell has been computed
    pos: usize,
    /// current incomplete cell
    cell: Cell,
    /// terminating char of an escaped sequence (Escape), or 0
    end_char: u8,
    lines: Vec<Vec<Cell>>,
    widths: Vec<usize>,
    out: Vec<u8>,
}

/// utf8.RuneCount.
fn rune_count(b: &[u8]) -> usize {
    if let Ok(s) = std::str::from_utf8(b) {
        return s.chars().count();
    }
    let (mut n, mut i) = (0, 0);
    while i < b.len() {
        let (_, w) = rbfast_gostr::decode_rune(&b[i..]);
        i += w.max(1);
        n += 1;
    }
    n
}

impl TabWriter {
    /// tabwriter.NewWriter(w, minwidth, 8, padding, ' ', flags), flags AlignRight when `align_right`, else 0.
    pub fn new(minwidth: usize, padding: usize, align_right: bool) -> TabWriter {
        let mut w = TabWriter {
            minwidth,
            padding,
            align_right,
            buf: Vec::new(),
            pos: 0,
            cell: Cell::default(),
            end_char: 0,
            lines: Vec::new(),
            widths: Vec::new(),
            out: Vec::new(),
        };
        w.reset();
        w
    }

    fn reset(&mut self) {
        self.buf.clear();
        self.pos = 0;
        self.cell = Cell::default();
        self.end_char = 0;
        self.lines.clear();
        self.widths.clear();
        self.lines.push(Vec::new());
    }

    fn append(&mut self, text_start: usize, text_end: usize, src: &[u8]) {
        self.buf.extend_from_slice(&src[text_start..text_end]);
        self.cell.size += text_end - text_start;
    }

    fn update_width(&mut self) {
        self.cell.width += rune_count(&self.buf[self.pos..]);
        self.pos = self.buf.len();
    }

    fn end_escape(&mut self) {
        if self.end_char == ESCAPE {
            self.update_width();
            // StripEscape is off: the two Escape bytes are written but not counted
            self.cell.width -= 2;
        }
        self.pos = self.buf.len();
        self.end_char = 0;
    }

    fn terminate_cell(&mut self, htab: bool) -> usize {
        self.cell.htab = htab;
        let c = std::mem::take(&mut self.cell);
        let line = self.lines.last_mut().expect("a current line");
        line.push(c);
        line.len()
    }

    fn flush_no_defers(&mut self) {
        if self.cell.size > 0 {
            if self.end_char != 0 {
                self.end_escape();
            }
            self.terminate_cell(false);
        }
        let n = self.lines.len();
        self.format(0, 0, n);
        self.reset();
    }

    /// Writer.Write.
    pub fn write(&mut self, src: &[u8]) {
        let mut n = 0;
        for (i, &ch) in src.iter().enumerate() {
            if self.end_char == 0 {
                match ch {
                    b'\t' | 0x0b | b'\n' | 0x0c => {
                        self.append(n, i, src);
                        self.update_width();
                        n = i + 1;
                        let ncells = self.terminate_cell(ch == b'\t');
                        if ch == b'\n' || ch == 0x0c {
                            self.lines.push(Vec::new());
                            if ch == 0x0c || ncells == 1 {
                                self.flush_no_defers();
                            }
                        }
                    }
                    ESCAPE => {
                        self.append(n, i, src);
                        self.update_width();
                        n = i;
                        self.end_char = ESCAPE;
                    }
                    _ => {}
                }
            } else if ch == self.end_char {
                self.append(n, i + 1, src);
                n = i + 1;
                self.end_escape();
            }
        }
        self.append(n, src.len(), src);
    }

    pub fn write_str(&mut self, s: &str) {
        self.write(s.as_bytes());
    }

    /// Flush, and all the bytes written so far.
    pub fn finish(mut self) -> Vec<u8> {
        self.flush_no_defers();
        self.out
    }

    fn padding(&mut self, textw: usize, cellw: usize) {
        // cellw >= textw always (a column is at least as wide as its cells plus the padding)
        for _ in textw..cellw {
            self.out.push(b' ');
        }
    }

    fn write_lines(&mut self, pos0: usize, line0: usize, line1: usize) -> usize {
        let mut pos = pos0;
        for i in line0..line1 {
            let nc = self.lines[i].len();
            for j in 0..nc {
                let c = self.lines[i][j];
                if c.size == 0 {
                    if j < self.widths.len() {
                        self.padding(c.width, self.widths[j]);
                    }
                } else if !self.align_right {
                    self.out.extend_from_slice(&self.buf[pos..pos + c.size]);
                    pos += c.size;
                    if j < self.widths.len() {
                        self.padding(c.width, self.widths[j]);
                    }
                } else {
                    if j < self.widths.len() {
                        self.padding(c.width, self.widths[j]);
                    }
                    self.out.extend_from_slice(&self.buf[pos..pos + c.size]);
                    pos += c.size;
                }
            }
            if i + 1 == self.lines.len() {
                // the last buffered line: write the incomplete cell (no newline)
                let sz = self.cell.size;
                self.out.extend_from_slice(&self.buf[pos..pos + sz]);
                pos += sz;
            } else {
                self.out.push(b'\n');
            }
        }
        pos
    }

    fn format(&mut self, pos0: usize, line0: usize, line1: usize) -> usize {
        let mut pos = pos0;
        let mut line0 = line0;
        let column = self.widths.len();
        let mut this = line0;
        while this < line1 {
            if column + 1 >= self.lines[this].len() {
                this += 1;
                continue;
            }
            // a cell in this column: a column block starts here
            pos = self.write_lines(pos, line0, this);
            line0 = this;
            let mut width = self.minwidth;
            while this < line1 {
                let line = &self.lines[this];
                if column + 1 >= line.len() {
                    break;
                }
                let w = line[column].width + self.padding;
                if w > width {
                    width = w;
                }
                this += 1;
            }
            self.widths.push(width);
            pos = self.format(pos, line0, this);
            self.widths.pop();
            line0 = this;
            // Go's for loop: this++ after the block (the line that ended it is looked at again by the next
            // iteration's test in Go only through `this < line1`; it was already found to have no cell here)
            this += 1;
        }
        self.write_lines(pos, line0, line1)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(minw: usize, pad: usize, right: bool, s: &[u8]) -> Vec<u8> {
        let mut tw = TabWriter::new(minw, pad, right);
        tw.write(s);
        tw.finish()
    }

    /// The expected bytes are Go 1.27's text/tabwriter output for the same input and options (written by
    /// scripts/go/tabwriter_cases/main.go).
    #[test]
    fn go_outputs() {
        for (minw, pad, right, input, want) in GO_CASES {
            let got = run(*minw, *pad, *right, input);
            assert_eq!(
                got,
                want.to_vec(),
                "input {:?}: got {:?} want {:?}",
                String::from_utf8_lossy(input),
                String::from_utf8_lossy(&got),
                String::from_utf8_lossy(want)
            );
        }
    }

    include!("tabwriter_cases.rs");
}
