// SPDX-License-Identifier: Apache-2.0
//! Times the inference stage alone (rbfast_infer::run) on span dumps held in memory: reading and the copy of
//! the unsorted table before each run are outside the timer. Prints one BENCH line per (capture, mode, threads).
//!
//!   cargo run --release --example bench_infer -- [--threads 1,2,4,8] [--reps 5] [--mode parallel|go-exact|both] DUMPDIR...
//!
//! Each setting's result is also compared with DUMPDIR/inferred_full.json (Go's), when there is one: the line
//! then says go_json=identical or go_json=DIFFERS.
//!
//! A DUMPDIR holds spans.tsv.gz, resources.tsv, peers.tsv, addrs.tsv and counters.json (the oracle's layout).

use std::io::Read;
use std::path::Path;
use std::time::Instant;

use rbfast_infer::{run, Options, SortMode};

fn read(p: &Path) -> String {
    std::fs::read_to_string(p).unwrap_or_else(|e| panic!("{}: {e}", p.display()))
}

fn main() {
    let mut threads: Vec<usize> = vec![1, 2, 4, 8];
    let mut reps = 5usize;
    let mut modes = vec![SortMode::Parallel];
    let mut dirs = Vec::new();
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--threads" => threads = args.next().unwrap().split(',').map(|x| x.parse().unwrap()).collect(),
            "--reps" => reps = args.next().unwrap().parse().unwrap(),
            "--mode" => {
                modes = match args.next().unwrap().as_str() {
                    "parallel" => vec![SortMode::Parallel],
                    "go-exact" => vec![SortMode::GoExact],
                    _ => vec![SortMode::Parallel, SortMode::GoExact],
                }
            }
            _ => dirs.push(a),
        }
    }
    for dir in &dirs {
        let dir = Path::new(dir);
        let name = dir.file_name().unwrap().to_string_lossy().to_string();
        let t0 = Instant::now();
        let mut tsv = String::new();
        let f = std::fs::File::open(dir.join("spans.tsv.gz")).unwrap();
        flate2::read::MultiGzDecoder::new(std::io::BufReader::with_capacity(1 << 20, f))
            .read_to_string(&mut tsv)
            .unwrap();
        let data = rbfast_infer::dump::load(
            &tsv,
            &read(&dir.join("resources.tsv")),
            &read(&dir.join("peers.tsv")),
            &read(&dir.join("addrs.tsv")),
            &read(&dir.join("counters.json")),
        )
        .unwrap();
        drop(tsv);
        eprintln!("{name}: {} spans loaded in {:.1} s (not timed)", data.spans.len(), t0.elapsed().as_secs_f64());
        for &mode in &modes {
            for &t in &threads {
                let pool = rayon::ThreadPoolBuilder::new().num_threads(t).build().unwrap();
                let opt = Options { sort: mode, ..Default::default() };
                let mut walls = Vec::new();
                let mut check = String::new();
                for r in 0..=reps {
                    let mut d = data.clone();
                    let t1 = Instant::now();
                    let inf = pool.install(|| run(&mut d, &opt)).expect("inference");
                    let w = t1.elapsed().as_secs_f64();
                    let j = inf.to_json().unwrap().pretty();
                    if r == 0 {
                        check = j; // the warm-up run, not timed
                        continue;
                    }
                    assert!(j == check, "the result changed between runs");
                    walls.push(w);
                    drop(d);
                }
                let go = std::fs::read_to_string(dir.join("inferred_full.json")).ok();
                let go_json = match go {
                    Some(g) if g == check.clone() + "\n" => "identical",
                    Some(_) => "DIFFERS",
                    None => "absent",
                };
                walls.sort_by(f64::total_cmp);
                let med = walls[walls.len() / 2];
                println!(
                    "BENCH lang=rust capture={name} spans={} mode={} threads={t} reps={reps} median_s={med:.4} min_s={:.4} max_s={:.4} go_json={go_json}",
                    data.spans.len(),
                    if mode == SortMode::GoExact { "go-exact" } else { "parallel" },
                    walls[0],
                    walls[walls.len() - 1]
                );
            }
        }
    }
}
