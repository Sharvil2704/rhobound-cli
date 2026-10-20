// SPDX-License-Identifier: Apache-2.0

//! rbfast-math: rhobound-cli's numerical kernels (`internal/mathx`) and mean-latency model (`internal/model`)
//! in Rust, bit for bit as the Go reference computes them on linux/arm64, plus a parallel batch API for
//! many what-ifs.
//!
//! * [`gomath`]: Go's `math` functions the model uses (Exp, Log, Lgamma, Erfc, Erfinv), ported with Go's arm64
//!   fused multiply-adds, and Go's NaN-propagating Max/Min.
//! * [`mathx`]: GammaP, NormCDF, NormQuantile, the moments of the maximum of gamma branches (independent and
//!   correlated), EmaxExp.
//! * [`model`]: Topology/Service/Call, validation (`finish`), ErlangC, the residence formulas, QNA arrival
//!   variability, AnalyticWith, ChangePatchWith, the CLI's `--patch` parser.
//! * [`topojson`]: the topology JSON schema (Go's ParseTopology and MarshalTopology).
//! * [`batch`]: scenario batches and grids evaluated on rayon threads, bit-identical to the serial model.
//! * [`simd`]: two- and four-lane NEON `Exp`/`Erfc` with the scalar functions' bits per lane (the copula's
//!   hot loop).
//! * [`gofmt`]: Go's `%v`, `%q` and encoding/json text forms.
//!
//! # Parity
//!
//! The Go code is the specification. Go's arm64 compiler fuses `a ± x*y` into fused multiply-adds, and Go's
//! math functions are its own; this crate ports both (see [`gomath`]), so it computes what Go computes on
//! linux/arm64, bit for bit (verified on linux/arm64; on other targets Rust's fused multiply-add gives the same
//! bits by definition, but that was not run). Checked by the tests: random inputs against Go's values
//! (tests/parity_kernels.rs), Go's edge-case behaviour, errors word for word (tests/parity_edge.rs), the
//! oracle's model and numerics files and MarshalTopology's bytes (tests/parity_oracle.rs, which reads the
//! oracle from `RBFAST_ORACLE`), and the Go tests' own reference sets at their tolerances (tests/reference.rs). Go's results on other architectures (amd64: no fusion, assembly Exp and
//! Log) differ from these in the last bits.
//!
//! # Speed
//!
//! Every speed-up keeps the bits: work that provably cannot change a result is skipped, independent work is
//! reordered and computed two lanes at a time, and many scenarios run on rayon threads ([`batch`]), optionally
//! sharing the unpatched base and memoising the matched maximum by input bits ([`mathx::MaxMemo`]). The binary
//! `rbfast-math-oracle` (built with the `oracle` feature, which also brings serde_json) times the kernels, one
//! model call, fan-outs and what-if grids against the Go benchmark loops written for the comparison (not
//! published).
//!
//! For one what-if (the CLI's predict), the matched maximum's quadrature can run on the rayon pool:
//! `model::analytic_exec(.., Exec { parallel_quadrature_min_branches: 2, ..Default::default() })`, same bits.
//! Measured on an inferred 10-service topology with a 3-way fan-out: one Default AnalyticWith 2.87 ms serial,
//! 0.42 ms on 8 threads (Go 4.26 ms). It is off by default, so the Go-named functions never start threads; in a
//! full batch it costs nothing measurable either way (the cores are already busy with scenarios).
//! [`model::change_patch_from_base`] reuses a base already solved (ChangePatchWith solves it again).

// Go's code, ported as written: its float literals digit for digit (more digits than a float64 holds, rounding
// to the same value), its own spellings of ln 2, log2(e) and sqrt(2), and its NaN-rejecting `!(x >= 0)` tests.
#![allow(
    clippy::excessive_precision,
    clippy::approx_constant,
    clippy::neg_cmp_op_on_partial_ord
)]

pub mod batch;
pub mod gofmt;
pub mod gomath;
pub mod mathx;
pub mod model;
pub mod simd;
pub mod topojson;

pub use mathx::{
    emax_exp, gamma_p, max_moments_gamma, max_moments_gamma_corr, max_moments_gamma_corr_par,
    norm_cdf, norm_quantile,
};
pub use model::{
    analytic, analytic_with, change, change_patch_with, change_shift, change_shift_with, erlang_c,
    parse_patch, residence, residence_routed, residence_shares, Call, Config, Delta, ModelError,
    ModelResult, Patch, Service, Topology, DEFAULT, PLAIN, POOLED, RANDOM,
};
pub use topojson::{load_topology, marshal_topology, parse_topology};
