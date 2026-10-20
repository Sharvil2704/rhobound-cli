// SPDX-License-Identifier: Apache-2.0
//! How the tests compare a float with Go's. The Go values in testdata/ and in the oracle were made by Go 1.27.2 on
//! linux/arm64. On aarch64 every float must have Go's bits (any NaN for a NaN). Elsewhere a float within
//! [`TOLERANCE`] (relative) of Go's passes and is counted ([`report`] prints the count): Rust's float operations,
//! and the fused multiply-adds the ports place where Go's arm64 build fuses, give the same bits on every
//! architecture, so none is expected, but that was verified on linux/arm64 only. `RBFAST_PARITY=tolerant` selects
//! the tolerant comparison on aarch64 as well. Texts (error messages, JSON bytes) are compared exactly everywhere.
#![allow(dead_code)]

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::OnceLock;

pub const TOLERANCE: f64 = 1e-9;
static INEXACT: AtomicUsize = AtomicUsize::new(0);

/// Whether floats must be bit-identical to Go's (aarch64, unless RBFAST_PARITY=tolerant).
pub fn bit_exact() -> bool {
    static EXACT: OnceLock<bool> = OnceLock::new();
    *EXACT.get_or_init(|| {
        cfg!(target_arch = "aarch64")
            && std::env::var_os("RBFAST_PARITY").is_none_or(|v| v != "tolerant")
    })
}

/// a equals Go's b: the same bits (or both NaN); when not [`bit_exact`], also within [`TOLERANCE`] relative.
pub fn same(a: f64, b: f64) -> bool {
    if a.to_bits() == b.to_bits() || (a.is_nan() && b.is_nan()) {
        return true;
    }
    if bit_exact() || !a.is_finite() || !b.is_finite() {
        return false;
    }
    let ok = (a - b).abs() <= TOLERANCE * a.abs().max(b.abs());
    if ok {
        INEXACT.fetch_add(1, Ordering::Relaxed);
    }
    ok
}

/// Prints how the floats of a test were compared (at its end).
pub fn report(what: &str) {
    if bit_exact() {
        eprintln!("{what}: floats compared bit for bit with Go linux/arm64");
    } else {
        eprintln!(
            "{what}: floats compared within {TOLERANCE:e} relative (not aarch64, or RBFAST_PARITY=tolerant): {} not \
             bit-identical to Go linux/arm64",
            INEXACT.load(Ordering::Relaxed)
        );
    }
}

/// The oracle directory (RBFAST_ORACLE); None, with the reason printed, when it is unset or not an oracle.
pub fn oracle_dir() -> Option<std::path::PathBuf> {
    match std::env::var_os("RBFAST_ORACLE") {
        None => {
            eprintln!(
                "skipped: RBFAST_ORACLE is not set (the oracle: the Go binary's outputs; not in the repository, \
                 see rust/README.md)"
            );
            None
        }
        Some(p) => {
            let p = std::path::PathBuf::from(p);
            if p.join("model").is_dir() {
                Some(p)
            } else {
                eprintln!(
                    "skipped: RBFAST_ORACLE={} has no model/ folder",
                    p.display()
                );
                None
            }
        }
    }
}
