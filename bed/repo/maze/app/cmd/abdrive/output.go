package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"time"
)

// LoadgenHeader is the header of loadgen.csv (the CLI's DATA.md 8 format).
const LoadgenHeader = "arm,seq,sent_unix_ns,answered_unix_ns,status"

var armNames = [2]string{"A", "B"}

// RequestCount is rhobound.request-count/v1.
type RequestCount struct {
	Schema  string       `json:"schema"`
	Window  Window       `json:"window"`
	Source  string       `json:"source"`
	Entries []EntryCount `json:"entries"`
}

// Window is a window in RFC 3339 UTC.
type Window struct {
	Start string `json:"start"`
	End   string `json:"end"`
}

// EntryCount is one entry's count.
type EntryCount struct {
	Entry string `json:"entry"`
	Count int64  `json:"count"`
}

// ArmSummary is what summary.json says of one arm's measured run.
type ArmSummary struct {
	Scheduled     int            `json:"scheduled"`
	Sent          int            `json:"sent"`
	Answered      int64          `json:"answered"`
	Failed        int            `json:"failed"`
	AnsweredShare float64        `json:"answered_share"`
	Status        map[string]int `json:"status"`
	MeanMs        float64        `json:"mean_ms"`
	Errors        []string       `json:"errors"`
}

// Summary is summary.json.
type Summary struct {
	Schema           string                `json:"schema"`
	Service          string                `json:"service"`
	URLs             map[string]string     `json:"urls"`
	Paths            []MixPath             `json:"paths"`
	Rate             float64               `json:"rate"`
	Seconds          float64               `json:"seconds"`
	Warmup           float64               `json:"warmup"`
	Seed             uint64                `json:"seed"`
	FreshConn        bool                  `json:"fresh_conn"`
	Host             string                `json:"host"` // the Host header sent ("": each URL's own)
	TimeoutS         float64               `json:"timeout_s"`
	MinAnswered      float64               `json:"min_answered"`
	Window           Window                `json:"window"`
	FirstSendUnixNs  int64                 `json:"first_send_unix_ns"`
	LastAnswerUnixNs int64                 `json:"last_answer_unix_ns"`
	Arms             map[string]ArmSummary `json:"arms"`
	WarmupCounts     map[string]Counts     `json:"warmup_counts"`
	LateMaxMs        float64               `json:"late_max_ms"`
	LateOver1ms      int                   `json:"late_over_1ms"`
	Interrupted      bool                  `json:"interrupted"`
	OK               bool                  `json:"ok"`
}

func rfc3339(ns int64) string { return time.Unix(0, ns).UTC().Format(time.RFC3339Nano) }

// writeAtomic writes b to dir/name through a temporary file and a rename.
func writeAtomic(dir, name string, b []byte) error {
	f, err := os.CreateTemp(dir, ".tmp-"+name+"-*")
	if err != nil {
		return err
	}
	if _, err := f.Write(b); err != nil {
		f.Close()
		os.Remove(f.Name())
		return err
	}
	if err := f.Close(); err != nil {
		os.Remove(f.Name())
		return err
	}
	if err := os.Chmod(f.Name(), 0o644); err != nil {
		return err
	}
	return os.Rename(f.Name(), filepath.Join(dir, name))
}

// Summarize computes the window, the per-arm counts and the verdict of a run.
func Summarize(cfg Config, service string, minAnswered float64, res *Result) *Summary {
	s := &Summary{Schema: "rbd.abdrive-summary/v1", Service: service,
		URLs: map[string]string{"A": cfg.URLs[0], "B": cfg.URLs[1]}, Rate: cfg.Rate, Seconds: cfg.Seconds,
		Warmup: cfg.Warmup, Seed: cfg.Seed, FreshConn: cfg.FreshConn, Host: cfg.Host, TimeoutS: cfg.Timeout.Seconds(),
		MinAnswered: minAnswered, Arms: map[string]ArmSummary{}, WarmupCounts: map[string]Counts{},
		LateMaxMs: float64(res.LateMaxNs) / 1e6, LateOver1ms: res.LateOver1ms, Interrupted: res.Interrupted}
	for i, p := range cfg.Paths {
		s.Paths = append(s.Paths, MixPath{Path: p, W: cfg.Weights[i]})
	}
	first, last := int64(0), int64(0)
	ok := !res.Interrupted
	for k, rows := range res.Rows {
		a := ArmSummary{Scheduled: len(rows), Status: map[string]int{}, Errors: []string{}}
		sum := 0.0
		for _, r := range rows {
			if r.Sent == 0 {
				continue
			}
			a.Sent++
			if first == 0 || r.Sent < first {
				first = r.Sent
			}
			if !r.Done {
				a.Failed++
				if len(a.Errors) < 5 {
					a.Errors = append(a.Errors, r.Err)
				}
				continue
			}
			a.Answered++
			a.Status[strconv.Itoa(r.Status)]++
			sum += float64(r.Answered-r.Sent) / 1e6
			if r.Answered > last {
				last = r.Answered
			}
		}
		if a.Answered > 0 {
			a.MeanMs = sum / float64(a.Answered)
		}
		if a.Scheduled > 0 {
			a.AnsweredShare = float64(a.Answered) / float64(a.Scheduled)
		}
		ok = ok && a.AnsweredShare >= minAnswered
		s.Arms[armNames[k]] = a
		s.WarmupCounts[armNames[k]] = res.Warm[k]
	}
	if last < first {
		last = first
	}
	s.FirstSendUnixNs, s.LastAnswerUnixNs = first, last
	s.Window = Window{Start: rfc3339(first), End: rfc3339(last)}
	s.OK = ok
	return s
}

// WriteOutputs writes loadgen.csv, rc-a.json, rc-b.json and, last, summary.json into dir.
func WriteOutputs(dir string, s *Summary, res *Result) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	var csv bytes.Buffer
	csv.WriteString(LoadgenHeader + "\n")
	for k, rows := range res.Rows {
		idx := make([]int, 0, len(rows))
		for i, r := range rows {
			if r.Done {
				idx = append(idx, i)
			}
		}
		sort.Ints(idx)
		for _, i := range idx {
			r := rows[i]
			fmt.Fprintf(&csv, "%s,%d,%d,%d,%d\n", armNames[k], i+1, r.Sent, r.Answered, r.Status)
		}
	}
	if err := writeAtomic(dir, "loadgen.csv", csv.Bytes()); err != nil {
		return err
	}
	for k, name := range []string{"rc-a.json", "rc-b.json"} {
		rc := RequestCount{Schema: "rhobound.request-count/v1", Window: s.Window, Source: "loadgen",
			Entries: []EntryCount{{Entry: s.Service, Count: s.Arms[armNames[k]].Answered}}}
		b, err := json.Marshal(rc)
		if err != nil {
			return err
		}
		if err := writeAtomic(dir, name, append(b, '\n')); err != nil {
			return err
		}
	}
	b, err := json.MarshalIndent(s, "", " ")
	if err != nil {
		return err
	}
	return writeAtomic(dir, "summary.json", append(b, '\n'))
}
