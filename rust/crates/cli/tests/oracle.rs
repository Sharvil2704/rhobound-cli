// SPDX-License-Identifier: Apache-2.0
//! End to end against the Go oracle: every `rhobound` command line of every oracle capture's commands.txt
//! (infer, predict --json and text, --plain, --patch, --workers, --max-rho refusals, the GOMAXPROCS=1 run as
//! --threads 1) run through the rbfast binary, from the raw capture; stdout, stderr (after the program name)
//! and the exit status must be the oracle's bytes. Skipped when RBFAST_ORACLE is unset (the oracle is not in the
//! repository: see rust/README.md), and on other architectures than aarch64 (or with RBFAST_PARITY=tolerant): the
//! oracle is Go's linux/arm64 output, whose bytes were checked on aarch64 only (scripts/parity.sh compares with a
//! tolerance there).
//! scripts/parity.sh runs this and much more against a fresh Go build.

use std::path::{Path, PathBuf};
use std::process::Command;

fn oracle() -> Option<PathBuf> {
    let Some(p) = std::env::var_os("RBFAST_ORACLE").map(PathBuf::from) else {
        eprintln!("skipped: RBFAST_ORACLE is not set (the oracle: the Go binary's outputs; not in the repository)");
        return None;
    };
    if !cfg!(target_arch = "aarch64") || std::env::var_os("RBFAST_PARITY").is_some_and(|v| v == "tolerant") {
        eprintln!("skipped: the oracle's outputs are Go's linux/arm64 bytes; byte-identity is checked on aarch64 only");
        return None;
    }
    if !p.join("README.md").is_file() {
        eprintln!("skipped: RBFAST_ORACLE={} has no README.md", p.display());
        return None;
    }
    Some(p)
}

fn read_or_empty(p: &Path) -> Vec<u8> {
    std::fs::read(p).unwrap_or_default()
}

/// One commands.txt line: (GOMAXPROCS=1?, args, stdout file, stderr file, exit code).
fn parse(line: &str) -> Option<(bool, Vec<String>, String, String, i32)> {
    let (cmd, code) = line.split_once("# exit ")?;
    let code: i32 = code.trim().parse().ok()?;
    let mut words: Vec<&str> = cmd.split_whitespace().collect();
    let one = words.first() == Some(&"GOMAXPROCS=1");
    if one {
        words.remove(0);
    }
    if !words.first()?.ends_with("/rhobound") {
        return None;
    }
    let gt = words.iter().position(|w| *w == ">")?;
    let out = words.get(gt + 1)?.to_string();
    let err = words.get(gt + 3)?.to_string();
    let args = words[1..gt].iter().map(|s| s.to_string()).collect();
    Some((one, args, out, err, code))
}

fn norm(b: &[u8]) -> String {
    let s = String::from_utf8_lossy(b);
    s.lines()
        .map(|l| l.strip_prefix("rbfast: ").map_or(l.to_string(), |r| format!("rhobound: {r}")))
        .collect::<Vec<_>>()
        .join("\n")
}

#[test]
fn every_oracle_command_line() {
    let Some(o) = oracle() else {
        return;
    };
    let bin = env!("CARGO_BIN_EXE_rbfast");
    let mut dirs: Vec<PathBuf> = std::fs::read_dir(&o)
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.join("commands.txt").is_file())
        .collect();
    dirs.sort();
    let (mut n, mut bad) = (0, Vec::new());
    for d in &dirs {
        let text = std::fs::read_to_string(d.join("commands.txt")).unwrap();
        for line in text.lines() {
            let Some((one, args, out, err, code)) = parse(line) else { continue };
            let mut want_out = d.join(&out);
            if !want_out.exists() && out == "predict.gomaxprocs1.json" && code == 0 {
                want_out = d.join("predict.json"); // the oracle keeps one copy: commands.txt notes they are the same bytes
            }
            let mut c = Command::new(bin);
            c.args(&args);
            if one {
                c.env("RBFAST_THREADS", "1");
            }
            let r = c.output().unwrap();
            n += 1;
            let name = format!("{} {}", d.file_name().unwrap().to_string_lossy(), out);
            if r.status.code() != Some(code) {
                bad.push(format!("{name}: exit {:?}, Go {code}", r.status.code()));
            } else if r.stdout != read_or_empty(&want_out) {
                bad.push(format!("{name}: stdout differs"));
            } else if norm(&r.stderr) != norm(&read_or_empty(&d.join(&err))) {
                bad.push(format!(
                    "{name}: stderr {:?} vs Go {:?}",
                    norm(&r.stderr),
                    norm(&read_or_empty(&d.join(&err)))
                ));
            }
        }
    }
    eprintln!("{} oracle command lines, {} differ", n, bad.len());
    // 269 in the recorded oracle; 209 without the unpublished test-bed captures
    assert!(n >= 200, "only {n} command lines found");
    assert!(bad.is_empty(), "{}", bad.join("\n"));
}
