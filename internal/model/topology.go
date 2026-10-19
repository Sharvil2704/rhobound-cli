// SPDX-License-Identifier: Apache-2.0

package model

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
)

// Call is one sequential or parallel call from a service to a child.
type Call struct {
	Child int     // index into Topology.Services
	P     float64 // probability the call is made on a visit, in (0, 1]
	// Async marks a call the service does not wait for (fire and forget, such
	// as one sent after the response): it loads the child (it counts in the
	// visit ratios and the arrival streams) but is not on the service's
	// latency path, so neither the child's latency nor a change of it reaches
	// the caller. It takes no part in a parallel fan-out.
	Async bool
}

// SyncCalls returns the calls the service waits for: its calls without the
// async ones (the slice itself when it has none).
func (s *Service) SyncCalls() []Call {
	n := 0
	for _, c := range s.Calls {
		if c.Async {
			n++
		}
	}
	if n == 0 {
		return s.Calls
	}
	out := make([]Call, 0, len(s.Calls)-n)
	for _, c := range s.Calls {
		if !c.Async {
			out = append(out, c)
		}
	}
	return out
}

// Service is one node of the call graph. Times are in milliseconds.
type Service struct {
	Name     string
	S        float64 // mean own service time per visit, ms
	Calls    []Call  // a repeated child is a repeated call
	Parallel bool    // calls are made together; the parent waits for the slowest
	Servers  int     // replicas (or pooled workers when Routing is pooled)
	Workers  int     // workers per replica; greater than 1 needs Random routing
	CS2      float64 // squared coefficient of variation of the service time
	Routing  string  // Pooled or Random
	Delay    bool    // a pure delay: infinite servers, no queue
	Hop      float64 // network time added to every call into this service, ms
	// BranchCorr is the correlation between the latencies of this service's
	// parallel branches (0 = independent). Only the matched-maximum model reads it.
	BranchCorr float64
	// Glue is time per visit that holds no worker and is not spent in a call:
	// work between or after the calls (the client library, writing the
	// response), ms. It is a pure delay added once the calls are done, so a
	// parallel service adds it after its slowest branch. GlueCS2 is its
	// squared coefficient of variation (only the matched-maximum model reads it).
	Glue    float64
	GlueCS2 float64
	// Shares, when set, is each replica's share of the service's visits (one
	// per replica, summing to 1) for Random routing over two or more replicas;
	// nil is an even split. Keep-alive clients behind a Kubernetes Service can
	// hold an uneven split, since it picks a replica per connection. Each
	// replica is a queue fed its share (ResidenceShares).
	Shares []float64
}

// Topology is a DAG of services plus where external traffic enters.
type Topology struct {
	Name     string
	Services []Service
	Entry    map[int]float64 // entry weights; they scale the external rate
	order    []int
}

// Names returns the service names in index order.
func (t *Topology) Names() []string {
	out := make([]string, len(t.Services))
	for i, s := range t.Services {
		out[i] = s.Name
	}
	return out
}

// Index returns the index of a service by name, or -1.
func (t *Topology) Index(name string) int {
	for i, s := range t.Services {
		if s.Name == name {
			return i
		}
	}
	return -1
}

// Order returns a topological order (callers before callees).
func (t *Topology) Order() []int { return t.order }

// Finish validates the topology and computes its order. It must be called
// after the services and entry weights are set.
func (t *Topology) Finish() error {
	seen := map[string]bool{}
	for i := range t.Services {
		s := &t.Services[i]
		if seen[s.Name] {
			return fmt.Errorf("duplicate service name %q", s.Name)
		}
		seen[s.Name] = true
		if s.Servers < 0 || s.Workers < 0 {
			return fmt.Errorf("%s: servers and workers must not be negative", s.Name)
		}
		if s.Servers == 0 && s.Shares != nil {
			s.Servers = len(s.Shares)
		}
		if s.Servers == 0 {
			s.Servers = 1
		}
		if s.Workers == 0 {
			s.Workers = 1
		}
		if s.Routing == "" {
			s.Routing = Pooled
		}
		if s.Routing != Pooled && s.Routing != Random {
			return fmt.Errorf("%s: routing %q is not supported (pooled and random are)", s.Name, s.Routing)
		}
		if s.Workers > 1 && s.Routing == Pooled {
			return fmt.Errorf("%s: workers per replica needs random routing; a pooled service is one shared queue of `servers` workers", s.Name)
		}
		if !(s.S >= 0) || math.IsInf(s.S, 1) {
			return fmt.Errorf("%s: service time must be a finite non-negative number, got %v", s.Name, s.S)
		}
		if !(s.CS2 >= 0) || math.IsInf(s.CS2, 0) {
			return fmt.Errorf("%s: cs2 must be a finite non-negative number, got %v", s.Name, s.CS2)
		}
		if !(s.Hop >= 0) || math.IsInf(s.Hop, 0) {
			return fmt.Errorf("%s: hop must be a finite non-negative number of ms, got %v", s.Name, s.Hop)
		}
		if !(s.Glue >= 0) || math.IsInf(s.Glue, 0) || !(s.GlueCS2 >= 0) || math.IsInf(s.GlueCS2, 0) {
			return fmt.Errorf("%s: glue and glue_cs2 must be finite non-negative numbers, got %v and %v", s.Name, s.Glue, s.GlueCS2)
		}
		if s.Shares != nil {
			if err := checkShares(s); err != nil {
				return fmt.Errorf("%s: %v", s.Name, err)
			}
		}
		if !(s.BranchCorr >= -1 && s.BranchCorr <= 1) {
			return fmt.Errorf("%s: branch_corr must be in [-1, 1] (values <= 0 are treated as independent), got %v", s.Name, s.BranchCorr)
		}
		for _, c := range s.Calls {
			if c.Child < 0 || c.Child >= len(t.Services) {
				return fmt.Errorf("%s: call to an unknown service", s.Name)
			}
			if !(c.P > 0 && c.P <= 1) {
				return fmt.Errorf("%s: call probability must be in (0, 1], got %v", s.Name, c.P)
			}
		}
		if sc := s.SyncCalls(); s.Parallel && len(sc) > 1 {
			for _, c := range sc {
				if c.P < 1 {
					return fmt.Errorf("%s: a parallel fan-out with call probabilities is not modelled", s.Name)
				}
			}
		}
	}
	if len(t.Entry) == 0 {
		return fmt.Errorf("the topology has no entry service")
	}
	wsum := 0.0
	for i, w := range t.Entry {
		if i < 0 || i >= len(t.Services) {
			return fmt.Errorf("entry index %d is not a service", i)
		}
		if !(w >= 0) || math.IsInf(w, 0) {
			return fmt.Errorf("%s: entry weight must be a finite non-negative number, got %v", t.Services[i].Name, w)
		}
		wsum += w
	}
	if !(wsum > 0) {
		return fmt.Errorf("the entry weights sum to zero")
	}
	// Kahn's algorithm. Children are visited in call order (not map order), so
	// the order, and every floating-point sum taken along it, is reproducible.
	n := len(t.Services)
	kids := make([][]int, n)
	for i, s := range t.Services {
		seen := map[int]bool{}
		for _, c := range s.Calls {
			if !seen[c.Child] {
				seen[c.Child] = true
				kids[i] = append(kids[i], c.Child)
			}
		}
	}
	indeg := make([]int, n)
	for i := range kids {
		for _, c := range kids[i] {
			indeg[c]++
		}
	}
	queue := []int{}
	for i := 0; i < n; i++ {
		if indeg[i] == 0 {
			queue = append(queue, i)
		}
	}
	order := make([]int, 0, n)
	for len(queue) > 0 {
		i := queue[0]
		queue = queue[1:]
		order = append(order, i)
		for _, c := range kids[i] {
			indeg[c]--
			if indeg[c] == 0 {
				queue = append(queue, c)
			}
		}
	}
	if len(order) != n {
		return fmt.Errorf("the call graph has a cycle; the model needs a DAG")
	}
	t.order = order
	return nil
}

// checkShares checks a service's replica shares: one per replica, each a
// positive number, summing to 1 (within 1e-6: they are used as given).
func checkShares(s *Service) error {
	switch {
	case s.Delay:
		return fmt.Errorf("a delay has no replicas to share its traffic")
	case s.Routing != Random:
		return fmt.Errorf("replica shares need random routing (each replica its own queue), not %q", s.Routing)
	case len(s.Shares) < 2 || len(s.Shares) != s.Servers:
		return fmt.Errorf("%d replica shares for %d replicas; give one per replica, for two or more", len(s.Shares), s.Servers)
	}
	sum := 0.0
	for _, p := range s.Shares {
		if !(p > 0) || math.IsInf(p, 1) {
			return fmt.Errorf("a replica share must be a positive number, got %v", p)
		}
		sum += p
	}
	if math.Abs(sum-1) > 1e-6 {
		return fmt.Errorf("the replica shares sum to %v, not 1", sum)
	}
	return nil
}

// VisitRatios returns the expected visits to each service per unit of
// external traffic. Async calls count: they load their child.
func (t *Topology) VisitRatios() []float64 {
	v := make([]float64, len(t.Services))
	for r := range v {
		v[r] = t.Entry[r]
	}
	for _, i := range t.order {
		for _, c := range t.Services[i].Calls {
			v[c.Child] += v[i] * c.P
		}
	}
	return v
}

// fileService is the JSON form of a Service. It reads the same field names as
// the reference implementation's topology files, plus glue and glue_cs2 (the
// reference writes glue as a delay service, glue:<name>, which reads as one),
// the optional shares (each replica's share; absent is an even split) and a
// child's optional async flag ({"name": ..., "p": ..., "async": true}: a call
// the service does not wait for; absent is false).
type fileService struct {
	Name       string            `json:"name"`
	S          float64           `json:"s"`
	Children   []json.RawMessage `json:"children"`
	Parallel   bool              `json:"parallel"`
	Servers    int               `json:"servers"`
	Workers    int               `json:"workers"`
	CS2        *float64          `json:"cs2"`
	Routing    string            `json:"routing"`
	Delay      bool              `json:"delay"`
	Hop        float64           `json:"hop"`
	BranchCorr float64           `json:"branch_corr"`
	Glue       float64           `json:"glue"`
	GlueCS2    float64           `json:"glue_cs2"`
	Shares     []float64         `json:"shares"`
	Hold       bool              `json:"hold"`
	OwnSlots   *int              `json:"own_slots"`
}

type fileTopology struct {
	Name     string             `json:"name"`
	Services []fileService      `json:"services"`
	Entry    map[string]float64 `json:"entry"`
}

// ParseTopology reads a topology from JSON. Features the model does not
// support (held workers, p2c and round-robin routing) are refused by name.
func ParseTopology(data []byte) (*Topology, error) {
	var ft fileTopology
	if err := json.Unmarshal(data, &ft); err != nil {
		return nil, err
	}
	t := &Topology{Name: ft.Name, Entry: map[int]float64{}}
	idx := map[string]int{}
	for i, s := range ft.Services {
		idx[s.Name] = i
	}
	for _, fs := range ft.Services {
		if fs.Hold || fs.OwnSlots != nil {
			return nil, fmt.Errorf("%s: held workers are not supported", fs.Name)
		}
		s := Service{Name: fs.Name, S: fs.S, Parallel: fs.Parallel, Servers: fs.Servers, Workers: fs.Workers,
			CS2: 1, Routing: fs.Routing, Delay: fs.Delay, Hop: fs.Hop, BranchCorr: fs.BranchCorr, Glue: fs.Glue, GlueCS2: fs.GlueCS2,
			Shares: fs.Shares}
		if fs.CS2 != nil {
			s.CS2 = *fs.CS2
		}
		for _, raw := range fs.Children {
			var name string
			p, async := 1.0, false
			if err := json.Unmarshal(raw, &name); err != nil {
				var obj struct {
					Name  string   `json:"name"`
					P     *float64 `json:"p"`
					Async bool     `json:"async"`
				}
				if err := json.Unmarshal(raw, &obj); err != nil {
					return nil, fmt.Errorf("%s: a child must be a name or {name, p, async}", fs.Name)
				}
				name, async = obj.Name, obj.Async
				if obj.P != nil {
					p = *obj.P
				}
			}
			ci, ok := idx[name]
			if !ok {
				return nil, fmt.Errorf("%s: unknown child %q", fs.Name, name)
			}
			s.Calls = append(s.Calls, Call{Child: ci, P: p, Async: async})
		}
		t.Services = append(t.Services, s)
	}
	for name, w := range ft.Entry {
		i, ok := idx[name]
		if !ok {
			return nil, fmt.Errorf("unknown entry service %q", name)
		}
		t.Entry[i] = w
	}
	if err := t.Finish(); err != nil {
		return nil, err
	}
	return t, nil
}

// LoadTopology reads a topology file.
func LoadTopology(path string) (*Topology, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return ParseTopology(data)
}

// MarshalTopology writes a topology in the JSON form ParseTopology reads.
func MarshalTopology(t *Topology) ([]byte, error) {
	type child struct {
		Name  string  `json:"name"`
		P     float64 `json:"p"`
		Async bool    `json:"async,omitempty"`
	}
	type svc struct {
		Name       string    `json:"name"`
		S          float64   `json:"s"`
		Children   []any     `json:"children,omitempty"`
		Parallel   bool      `json:"parallel,omitempty"`
		Servers    int       `json:"servers,omitempty"`
		Workers    int       `json:"workers,omitempty"`
		CS2        float64   `json:"cs2"`
		Routing    string    `json:"routing,omitempty"`
		Delay      bool      `json:"delay,omitempty"`
		Hop        float64   `json:"hop,omitempty"`
		BranchCorr float64   `json:"branch_corr,omitempty"`
		Glue       float64   `json:"glue,omitempty"`
		GlueCS2    float64   `json:"glue_cs2,omitempty"`
		Shares     []float64 `json:"shares,omitempty"`
	}
	doc := struct {
		Name     string             `json:"name"`
		Services []svc              `json:"services"`
		Entry    map[string]float64 `json:"entry"`
	}{Name: t.Name, Entry: map[string]float64{}}
	for _, s := range t.Services {
		o := svc{Name: s.Name, S: s.S, Parallel: s.Parallel, Servers: s.Servers, Workers: s.Workers,
			CS2: s.CS2, Routing: s.Routing, Delay: s.Delay, Hop: s.Hop, BranchCorr: s.BranchCorr, Glue: s.Glue, GlueCS2: s.GlueCS2,
			Shares: s.Shares}
		if o.Workers == 1 {
			o.Workers = 0
		}
		for _, c := range s.Calls {
			if c.P == 1 && !c.Async {
				o.Children = append(o.Children, t.Services[c.Child].Name)
			} else {
				o.Children = append(o.Children, child{t.Services[c.Child].Name, c.P, c.Async})
			}
		}
		doc.Services = append(doc.Services, o)
	}
	for i, w := range t.Entry {
		doc.Entry[t.Services[i].Name] = w
	}
	return json.MarshalIndent(doc, "", "  ")
}
