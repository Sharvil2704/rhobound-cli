// SPDX-License-Identifier: Apache-2.0

//! rbfast-otlp: the reader on its own, for parity checks and timing.
//!
//!   rbfast-otlp dump CAPTURE OUTDIR [--threads N] [--gz]
//!       the oracle's canonical dump (spans.tsv[.gz], resources.tsv, peers.tsv, addrs.tsv, counters.json); when
//!       the read fails, OUTDIR/error.txt holds the error and the exit code is 3
//!   rbfast-otlp bench CAPTURE [--threads N] [--reps R] [--chunk BYTES]
//!       times read_dir_with, one line per repetition

use rbfast_otlp::{dump, read_dir_with, ReadOptions};
use std::path::Path;
use std::time::Instant;

fn usage() -> ! {
    eprintln!("usage: rbfast-otlp dump CAPTURE OUTDIR [--threads N] [--gz]\n       rbfast-otlp bench CAPTURE [--threads N] [--reps R] [--chunk BYTES]");
    std::process::exit(2);
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() < 2 {
        usage();
    }
    let mut opts = ReadOptions::default();
    let mut reps = 1;
    let mut gz = false;
    let mut pos = Vec::new();
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--threads" => {
                i += 1;
                opts.threads = args
                    .get(i)
                    .and_then(|s| s.parse().ok())
                    .unwrap_or_else(|| usage());
            }
            "--reps" => {
                i += 1;
                reps = args
                    .get(i)
                    .and_then(|s| s.parse().ok())
                    .unwrap_or_else(|| usage());
            }
            "--chunk" => {
                i += 1;
                opts.chunk_bytes = args
                    .get(i)
                    .and_then(|s| s.parse().ok())
                    .unwrap_or_else(|| usage());
            }
            "--gz" => gz = true,
            s => pos.push(s.to_string()),
        }
        i += 1;
    }
    match args[0].as_str() {
        "dump" => {
            if pos.len() != 2 {
                usage();
            }
            let out = Path::new(&pos[1]);
            std::fs::create_dir_all(out).expect("create OUTDIR");
            match read_dir_with(&pos[0], &opts) {
                Ok(d) => {
                    dump::write_dump(&d, out, gz).expect("write dump");
                }
                Err(e) => {
                    std::fs::write(out.join("error.txt"), format!("{}\n", e))
                        .expect("write error.txt");
                    std::process::exit(3);
                }
            }
        }
        "bench" => {
            if pos.len() != 1 {
                usage();
            }
            for _ in 0..reps {
                let t0 = Instant::now();
                let d = match read_dir_with(&pos[0], &opts) {
                    Ok(d) => d,
                    Err(e) => {
                        eprintln!("{e}");
                        std::process::exit(1);
                    }
                };
                let el = t0.elapsed().as_secs_f64();
                let bytes: u64 = d
                    .files
                    .iter()
                    .map(|f| std::fs::metadata(f).map(|m| m.len()).unwrap_or(0))
                    .sum();
                let threads = if opts.threads > 0 {
                    opts.threads
                } else {
                    std::thread::available_parallelism()
                        .map(|n| n.get())
                        .unwrap_or(1)
                };
                println!(
                    "READ rust threads={} wall={:.4} spans={} bytes={} mbps={:.1}",
                    threads,
                    el,
                    d.spans.len(),
                    bytes,
                    bytes as f64 / 1e6 / el
                );
                drop(d);
            }
        }
        "inflate" => {
            // inflate FILE [vec]: time the gzip code alone
            let t0 = Instant::now();
            let n = rbfast_otlp::bench_inflate(
                Path::new(&pos[0]),
                pos.get(1).map(|s| s == "vec").unwrap_or(false),
            )
            .expect("inflate");
            let el = t0.elapsed().as_secs_f64();
            println!(
                "INFLATE bytes_out={} wall={:.4} out_mbps={:.1}",
                n,
                el,
                n as f64 / 1e6 / el
            );
        }
        "batch" => {
            // batch LIST OUT: one line per capture, in the form of the Go program that froze tests/data/go_golden.txt
            // (for fuzzing against Go)
            if pos.len() != 2 {
                usage();
            }
            let list = std::fs::read_to_string(&pos[0]).expect("read LIST");
            let mut out = String::new();
            for p in list.trim_end_matches('\n').split('\n') {
                match read_dir_with(p, &opts) {
                    Err(e) => out.push_str(&format!(
                        "{}\tERROR\t{}\n",
                        p,
                        e.message.replace('\n', "\\n")
                    )),
                    Ok(d) => {
                        let hex =
                            |s: &str| s.bytes().map(|b| format!("{b:02x}")).collect::<String>();
                        let mut h = format!(
                            "spans={} skipped={} probes={} probe_children={} files={}\n",
                            d.spans.len(),
                            d.skipped,
                            d.probes,
                            d.probe_children,
                            d.files.len()
                        );
                        for (i, r) in d.resources.iter().enumerate() {
                            h.push_str(&format!(
                                "R{}\t{}\t{}\t{}\n",
                                i,
                                hex(&r.service),
                                hex(&r.pod),
                                hex(&r.image)
                            ));
                        }
                        for (i, s) in d.peers.iter().enumerate() {
                            h.push_str(&format!("P{}\t{}\n", i, hex(s)));
                        }
                        for (i, s) in d.addrs.iter().enumerate() {
                            h.push_str(&format!("A{}\t{}\n", i, hex(s)));
                        }
                        for s in &d.spans {
                            h.push_str(&format!(
                                "{:016x}{:016x} {:016x} {:016x} {} {} {} {} {} {}\n",
                                s.trace[0],
                                s.trace[1],
                                s.id,
                                s.parent,
                                s.start,
                                s.end,
                                s.kind,
                                s.res,
                                s.peer,
                                s.addr
                            ));
                        }
                        out.push_str(&format!("{}\tOK\t{}\n", p, dump::sha256_hex(h.as_bytes())));
                    }
                }
            }
            std::fs::write(&pos[1], out).expect("write OUT");
        }
        _ => usage(),
    }
}
