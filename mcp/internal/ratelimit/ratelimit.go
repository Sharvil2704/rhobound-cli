// SPDX-License-Identifier: Apache-2.0

// Package ratelimit holds the per-principal limits of the compute tools (ARCHITECTURE.md 10): a token bucket per
// principal on each limited tool (predict, budget, context and explain), and at most a fixed number of fit jobs running
// at once per principal. A call over a limit is refused with rate.limited and the time after which it would be allowed
// (ARCHITECTURE.md 5.8).
//
// The limits are in memory, for one server process: stdio and container modes. On Lambda they live in the state
// table (DEPLOY_AWS.md 3.2) and come with that binding.
package ratelimit

import (
	"sync"
	"time"
)

// Bucket is a token bucket: Burst calls at once, then one more every Every.
type Bucket struct {
	Burst int
	Every time.Duration
}

// Rules are the limits of a server.
type Rules struct {
	// Tools are the buckets by tool name; a tool not listed is not limited.
	Tools map[string]Bucket
	// MaxFits is the most fit jobs one principal may have running at once (0: no limit).
	MaxFits int
}

// Default are the limits when the configuration sets none [D]: an agent's loop makes a few context and budget calls
// and a handful of predictions and explanations a minute, far below these. The predict bucket also pays for the first
// computation of a prediction's report, judge packet or explain section, one token a request, and the context bucket
// for a fit's full-summary resource. The explain bucket bounds the explanations of a fit or an A/B record, which run
// the engine on every call.
var Default = Rules{
	Tools: map[string]Bucket{
		"predict": {Burst: 30, Every: time.Second},
		"budget":  {Burst: 10, Every: 2 * time.Second},
		"context": {Burst: 10, Every: 2 * time.Second},
		"explain": {Burst: 30, Every: time.Second},
	},
	MaxFits: 2,
}

// Limiter applies Rules. Its clock is the process's own (Now), never a pinned server clock: limits are about elapsed
// time. It is safe for concurrent use.
type Limiter struct {
	rules Rules
	Now   func() time.Time

	mu      sync.Mutex
	buckets map[key]*state
	fits    map[string]int
}

type key struct{ principal, tool string }

// state is a bucket's tokens at a time.
type state struct {
	tokens float64
	at     time.Time
}

// New returns a limiter for the rules.
func New(r Rules) *Limiter {
	return &Limiter{rules: r, Now: time.Now, buckets: map[key]*state{}, fits: map[string]int{}}
}

// Allow takes one token from the principal's bucket for the tool. When the bucket is empty it takes nothing and
// returns how long until a token is there.
func (l *Limiter) Allow(principal, tool string) (bool, time.Duration) {
	b, ok := l.rules.Tools[tool]
	if !ok || b.Burst <= 0 || b.Every <= 0 {
		return true, 0
	}
	now := l.Now()
	l.mu.Lock()
	defer l.mu.Unlock()
	k := key{principal, tool}
	s, ok := l.buckets[k]
	if !ok {
		s = &state{tokens: float64(b.Burst), at: now}
		l.buckets[k] = s
	}
	if el := now.Sub(s.at); el > 0 {
		s.tokens = min(float64(b.Burst), s.tokens+float64(el)/float64(b.Every))
		s.at = now
	}
	if s.tokens >= 1 {
		s.tokens--
		return true, 0
	}
	wait := time.Duration((1 - s.tokens) * float64(b.Every))
	if wait < time.Millisecond {
		wait = time.Millisecond
	}
	return false, wait
}

// Prune forgets the buckets that have refilled to their burst. Such a bucket allows what a new one does, so no limit
// changes, and the limiter keeps no entry for a principal that has not called for a while. The server's sweeper calls
// it every hour. It returns how many buckets it forgot.
func (l *Limiter) Prune() int {
	now := l.Now()
	l.mu.Lock()
	defer l.mu.Unlock()
	n := 0
	for k, s := range l.buckets {
		b := l.rules.Tools[k.tool]
		if b.Every <= 0 || s.tokens+float64(now.Sub(s.at))/float64(b.Every) >= float64(b.Burst) {
			delete(l.buckets, k)
			n++
		}
	}
	return n
}

// StartFit counts a fit job the principal starts, unless the principal already runs MaxFits of them. done must be
// called once when the job ends.
func (l *Limiter) StartFit(principal string) (done func(), ok bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.rules.MaxFits > 0 && l.fits[principal] >= l.rules.MaxFits {
		return nil, false
	}
	l.fits[principal]++
	var once sync.Once
	return func() {
		once.Do(func() {
			l.mu.Lock()
			defer l.mu.Unlock()
			if l.fits[principal]--; l.fits[principal] <= 0 {
				delete(l.fits, principal)
			}
		})
	}, true
}
