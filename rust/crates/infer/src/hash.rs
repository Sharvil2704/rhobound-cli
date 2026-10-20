// SPDX-License-Identifier: Apache-2.0

//! A small multiplicative hasher (the Fx hash of rustc) for the per-chunk maps, whose keys are a few small
//! integers: much cheaper than SipHash, and no crate. Nothing here depends on iteration order.
//!
//! After rustc-hash 1.x's FxHasher (<https://github.com/rust-lang/rustc-hash>), Copyright 2015 The Rust Project
//! Developers, Apache-2.0 OR MIT (used under Apache-2.0).

use std::collections::HashMap;
use std::hash::{BuildHasherDefault, Hasher};

#[derive(Default, Clone, Copy)]
pub struct Fx(u64);

const SEED: u64 = 0x51_7c_c1_b7_27_22_0a_95;

impl Fx {
    #[inline]
    fn add(&mut self, w: u64) {
        self.0 = (self.0.rotate_left(5) ^ w).wrapping_mul(SEED);
    }
}

impl Hasher for Fx {
    #[inline]
    fn write(&mut self, bytes: &[u8]) {
        // chunks_exact, not as_chunks: the workspace's rust-version is 1.80
        #[allow(clippy::chunks_exact_to_as_chunks)]
        let mut it = bytes.chunks_exact(8);
        for c in &mut it {
            self.add(u64::from_le_bytes(c.try_into().unwrap()));
        }
        let r = it.remainder();
        if !r.is_empty() {
            let mut b = [0u8; 8];
            b[..r.len()].copy_from_slice(r);
            self.add(u64::from_le_bytes(b));
        }
    }
    #[inline]
    fn write_u8(&mut self, i: u8) {
        self.add(i as u64);
    }
    #[inline]
    fn write_u32(&mut self, i: u32) {
        self.add(i as u64);
    }
    #[inline]
    fn write_i32(&mut self, i: i32) {
        self.add(i as u32 as u64);
    }
    #[inline]
    fn write_u64(&mut self, i: u64) {
        self.add(i);
    }
    #[inline]
    fn write_usize(&mut self, i: usize) {
        self.add(i as u64);
    }
    #[inline]
    fn finish(&self) -> u64 {
        // the low bits pick the bucket: fold the well-mixed high bits in
        self.0 ^ (self.0 >> 29)
    }
}

pub type FxMap<K, V> = HashMap<K, V, BuildHasherDefault<Fx>>;

pub fn map<K, V>() -> FxMap<K, V> {
    HashMap::with_hasher(BuildHasherDefault::default())
}
