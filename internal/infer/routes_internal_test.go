// SPDX-License-Identifier: Apache-2.0

package infer

import (
	"reflect"
	"testing"
)

// The route buckets: up to MaxRoutesPerService routes of at least MinRouteShare each, the rest under OtherRoute, and
// none at all for a service where fewer than two routes pass (so its outputs stay as they were).
func TestRouteBuckets(t *testing.T) {
	routes := []string{"GET /a", "GET /b", "GET /c", "GET /d"}
	var vrec []visitRec
	add := func(svc int32, route uint16, n int) {
		for k := 0; k < n; k++ {
			vrec = append(vrec, visitRec{svc: svc, route: route})
		}
	}
	add(0, 1, 70) // service 0: /a 70%, /b 26%, /c 3%, no route 1%
	add(0, 2, 26)
	add(0, 3, 3)
	add(0, 0, 1)
	add(1, 1, 97) // service 1: one route passes
	add(1, 2, 3)
	add(2, 4, 50) // service 2: two routes, nothing else
	add(2, 3, 50)
	names, bucket := routeBuckets(vrec, routes, 3)
	if !reflect.DeepEqual(names[0], []string{"GET /a", "GET /b", OtherRoute}) || bucket[0][1] != 0 || bucket[0][2] != 1 {
		t.Errorf("service 0: %v %v", names[0], bucket[0])
	}
	if bucketOf(names[0], bucket[0], 3) != 2 || bucketOf(names[0], bucket[0], 0) != 2 {
		t.Error("a small route and no route count under other")
	}
	if names[1] != nil || bucket[1] != nil {
		t.Errorf("service 1 has one route: %v", names[1])
	}
	if !reflect.DeepEqual(names[2], []string{"GET /c", "GET /d"}) { // a tie is broken by name; no other bucket
		t.Errorf("service 2: %v", names[2])
	}
}

func TestNodeOwner(t *testing.T) {
	for in, want := range map[string]string{"web": "web", "stage:web:1.2": "web", "shape:web:2": "web",
		"stage:a:b:3": "a:b", "ext:db": "ext:db"} {
		if got := NodeOwner(in); got != want {
			t.Errorf("NodeOwner(%q) = %q, want %q", in, got, want)
		}
	}
}
