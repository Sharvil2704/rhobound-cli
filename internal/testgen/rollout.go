// SPDX-License-Identifier: Apache-2.0

package testgen

import "slices"

// Rollout replaces svc's image during c, as a rollout that settled at the instant at (Unix ns) leaves a capture whose
// trace files reach back past it: every resource reports the image digest of its service (Digest(service)), and every
// span of svc that ends before at moves to a resource of its own in the same request, the pod svc+"-old" of the image
// Digest(svc+"-old"). A resource left with no span is dropped. It returns the start and the end of the old pod's span
// that ends last (zero when no span of svc ends before at).
func Rollout(c *Capture, svc string, at uint64) (lastStart, lastEnd uint64) {
	digest := func(name string) map[string]any {
		return Strs("registry.example/" + svc + "@" + Digest(name))
	}
	for _, r := range c.Requests {
		var rss []*ResourceSpans
		for _, rs := range r.ResourceSpans {
			if rs.Service() != svc {
				rs.SetAttr("container.image.repo_digests", Strs("registry.example/"+rs.Service()+"@"+Digest(rs.Service())))
				rss = append(rss, rs)
				continue
			}
			rs.SetAttr("container.image.repo_digests", digest(svc))
			old := &ResourceSpans{Resource: Resource{Attributes: slices.Clone(rs.Resource.Attributes)}}
			var kept []*ScopeSpans
			for _, ss := range rs.ScopeSpans {
				var stay, moved []*Span
				for _, s := range ss.Spans {
					start, end := s.Times()
					if end >= at {
						stay = append(stay, s)
						continue
					}
					moved = append(moved, s)
					if end > lastEnd {
						lastStart, lastEnd = start, end
					}
				}
				if len(moved) > 0 {
					old.ScopeSpans = append(old.ScopeSpans, &ScopeSpans{Scope: ss.Scope, Spans: moved})
				}
				if len(stay) > 0 {
					ss.Spans = stay
					kept = append(kept, ss)
				}
			}
			if len(kept) > 0 {
				rs.ScopeSpans = kept
				rss = append(rss, rs)
			}
			if len(old.ScopeSpans) > 0 {
				old.SetAttr("k8s.pod.name", Str(svc+"-old"))
				old.SetAttr("container.image.repo_digests", digest(svc+"-old"))
				rss = append(rss, old)
			}
		}
		r.ResourceSpans = rss
	}
	return lastStart, lastEnd
}
