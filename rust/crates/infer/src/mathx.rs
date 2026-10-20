// SPDX-License-Identifier: Apache-2.0

//! The one numerical kernel the inference needs: the regularized lower incomplete gamma function, for the
//! even-split test (split.rs), and the Lgamma it uses.
//!
//! Earlier versions of this module held a private copy of rhobound-cli's `mathx.GammaP` (with glibc's ln and
//! exp, so a few ulps off Go's for large shapes). It now re-exports rbfast-math's ports, which are Go's
//! linux/arm64 values bit for bit (Go's own Exp, Log and Lgamma, with Go's fused multiply-adds); tests/mathx.rs
//! checks them against Go's values on the oracle's grids.

pub use rbfast_math::gomath::lgamma;
pub use rbfast_math::mathx::gamma_p;
