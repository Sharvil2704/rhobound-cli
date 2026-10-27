// SPDX-License-Identifier: Apache-2.0

//go:build !race

package main

// raceEnabled is true in a test binary built with -race.
const raceEnabled = false
