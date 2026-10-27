// SPDX-License-Identifier: Apache-2.0

package oci

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
)

const (
	bundleType = "application/vnd.dev.sigstore.bundle.v0.3+json"
	sbomType   = "application/spdx+json"
)

func digestOf(b []byte) Digest {
	sum := sha256.Sum256(b)
	return Digest("sha256:" + hex.EncodeToString(sum[:]))
}

// registry is an OCI distribution endpoint: manifests and blobs by digest, tags, and a referrers API that can
// be missing, ignore the artifactType filter, or page its answer.
type registry struct {
	t   *testing.T
	srv *httptest.Server

	mu          sync.Mutex
	content     map[string][]byte // digest or tag -> bytes
	contentType map[string]string
	referrers   map[Digest][]Descriptor
	noReferrers bool // answer the referrers API with 404
	honour      bool // apply the artifactType filter
	pageSize    int  // page the referrers listing
	auth        []string
	accept      []string
}

func newRegistry(t *testing.T) *registry {
	r := &registry{t: t, content: map[string][]byte{}, contentType: map[string]string{}, referrers: map[Digest][]Descriptor{}}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v2/shop/checkout/referrers/{digest}", r.serveReferrers)
	mux.HandleFunc("GET /v2/shop/checkout/manifests/{ref}", r.serveContent)
	mux.HandleFunc("GET /v2/shop/checkout/blobs/{ref}", r.serveContent)
	r.srv = httptest.NewServer(mux)
	t.Cleanup(r.srv.Close)
	return r
}

func (r *registry) client() *Client {
	return &Client{Base: r.srv.URL, HTTP: r.srv.Client(), Tokens: tokens{}}
}

type tokens struct{}

func (tokens) Token(ctx context.Context, registry string) (string, error) {
	return "Basic dGVzdDp0ZXN0", nil
}

func (r *registry) put(b []byte, mediaType string, tags ...string) Digest {
	d := digestOf(b)
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, k := range append(tags, string(d)) {
		r.content[k], r.contentType[k] = b, mediaType
	}
	return d
}

func (r *registry) note(req *http.Request) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.auth = append(r.auth, req.Header.Get("Authorization"))
	r.accept = append(r.accept, req.Header.Get("Accept"))
}

func (r *registry) serveContent(w http.ResponseWriter, req *http.Request) {
	r.note(req)
	r.mu.Lock()
	b, ok := r.content[req.PathValue("ref")]
	ct := r.contentType[req.PathValue("ref")]
	r.mu.Unlock()
	if !ok {
		http.NotFound(w, req)
		return
	}
	w.Header().Set("Content-Type", ct)
	w.Write(b)
}

func (r *registry) serveReferrers(w http.ResponseWriter, req *http.Request) {
	r.note(req)
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.noReferrers {
		http.NotFound(w, req)
		return
	}
	ds := r.referrers[Digest(req.PathValue("digest"))]
	if at := req.URL.Query().Get("artifactType"); r.honour && at != "" {
		ds = filter(ds, at)
		w.Header().Set("OCI-Filters-Applied", "artifactType")
	}
	if r.pageSize > 0 {
		var page int
		fmt.Sscan(req.URL.Query().Get("page"), &page)
		end := min((page+1)*r.pageSize, len(ds))
		if end < len(ds) {
			w.Header().Set("Link", fmt.Sprintf(`<%s?page=%d&artifactType=%s>; rel="next"`, req.URL.Path, page+1,
				url.QueryEscape(req.URL.Query().Get("artifactType"))))
		}
		ds = ds[page*r.pageSize : end]
	}
	w.Header().Set("Content-Type", MediaTypeIndex)
	json.NewEncoder(w).Encode(map[string]any{"schemaVersion": 2, "mediaType": MediaTypeIndex, "manifests": ds})
}

var subject = digestOf([]byte("candidate image"))

func referrerSet() []Descriptor {
	d := func(s, at string) Descriptor {
		return Descriptor{MediaType: MediaTypeManifest, Digest: digestOf([]byte(s)), Size: 512, ArtifactType: at}
	}
	return []Descriptor{d("profile 1", bundleType), d("sbom", sbomType), d("profile 2", bundleType)}
}

func TestReferrersFilterOnTheClient(t *testing.T) {
	for _, honour := range []bool{false, true} {
		r := newRegistry(t)
		r.honour = honour
		r.referrers[subject] = referrerSet()
		got, err := r.client().Referrers(context.Background(), "shop/checkout", subject, bundleType)
		if err != nil {
			t.Fatal(err)
		}
		if len(got) != 2 || got[0].ArtifactType != bundleType || got[1].ArtifactType != bundleType {
			t.Fatalf("honour=%v: referrers %+v, want the two profiles", honour, got)
		}
		all, _ := r.client().Referrers(context.Background(), "shop/checkout", subject, "")
		if len(all) != 3 {
			t.Fatalf("unfiltered: %d referrers", len(all))
		}
		if r.auth[0] != "Basic dGVzdDp0ZXN0" || r.accept[0] != MediaTypeIndex {
			t.Fatalf("Authorization %q, Accept %q", r.auth[0], r.accept[0])
		}
	}
}

func TestReferrersFollowPages(t *testing.T) {
	r := newRegistry(t)
	r.pageSize = 1
	r.referrers[subject] = referrerSet()
	got, err := r.client().Referrers(context.Background(), "shop/checkout", subject, bundleType)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || len(r.accept) != 3 {
		t.Fatalf("%d referrers over %d requests, want 2 over 3 pages", len(got), len(r.accept))
	}
}

func TestReferrersFallBackToTheTag(t *testing.T) {
	r := newRegistry(t)
	r.noReferrers = true
	ix, _ := json.Marshal(map[string]any{"schemaVersion": 2, "mediaType": MediaTypeIndex, "manifests": referrerSet()})
	r.put(ix, MediaTypeIndex, "sha256-"+subject.Hex())
	got, err := r.client().Referrers(context.Background(), "shop/checkout", subject, bundleType)
	if err != nil || len(got) != 2 {
		t.Fatalf("tag fallback: %+v %v", got, err)
	}
	// no referrers API and no tag: no referrers, which is not an error
	other := digestOf([]byte("another image"))
	got, err = r.client().Referrers(context.Background(), "shop/checkout", other, bundleType)
	if err != nil || len(got) != 0 {
		t.Fatalf("no referrers: %+v %v", got, err)
	}
}

func codeOf(t *testing.T, err error) string {
	t.Helper()
	var c *CodedError
	if !errors.As(err, &c) {
		t.Fatalf("got %v, want a coded refusal", err)
	}
	var v map[string]any
	if json.Unmarshal(c.RefusalJSON(), &v) != nil || v["reason"] == "" || v["fix"] == "" {
		t.Fatalf("refusal %s", c.RefusalJSON())
	}
	return c.Finding.Code
}

func TestMediaTypeParametersAreRefused(t *testing.T) {
	r := newRegistry(t)
	set := referrerSet()
	set[1].ArtifactType = bundleType + ";version=0.3"
	r.referrers[subject] = set
	_, err := r.client().Referrers(context.Background(), "shop/checkout", subject, bundleType)
	if code := codeOf(t, err); code != CodeMediaTypeParameter {
		t.Fatalf("code %s", code)
	}
	// a manifest served with a parameter, and one whose mediaType field carries one
	cfg := r.put([]byte(`{"architecture":"arm64","os":"linux"}`), "application/vnd.oci.image.config.v1+json")
	m1 := r.put(manifest(cfg, MediaTypeManifest), MediaTypeManifest+";version=1")
	m2 := r.put(manifest(cfg, MediaTypeManifest+"; version=1"), MediaTypeManifest)
	for _, d := range []Digest{m1, m2} {
		_, err := r.client().ResolvePlatform(context.Background(), "shop/checkout", d, Platform{"linux", "arm64", ""})
		if code := codeOf(t, err); code != CodeMediaTypeParameter {
			t.Fatalf("%s: code %s", d, code)
		}
	}
}

func manifest(cfg Digest, mediaType string) []byte {
	b, _ := json.Marshal(map[string]any{"schemaVersion": 2, "mediaType": mediaType,
		"config": Descriptor{MediaType: "application/vnd.oci.image.config.v1+json", Digest: cfg, Size: 40},
		"layers": []Descriptor{}})
	return b
}

func platformIndex(r *registry) (ix, amd, arm Digest) {
	amdCfg := r.put([]byte(`{"architecture":"amd64","os":"linux"}`), "application/vnd.oci.image.config.v1+json")
	armCfg := r.put([]byte(`{"architecture":"arm64","os":"linux","variant":"v8"}`), "application/vnd.oci.image.config.v1+json")
	amd = r.put(manifest(amdCfg, MediaTypeManifest), MediaTypeManifest)
	arm = r.put(manifest(armCfg, MediaTypeManifest), MediaTypeManifest)
	b, _ := json.Marshal(map[string]any{"schemaVersion": 2, "mediaType": MediaTypeIndex, "manifests": []map[string]any{
		{"mediaType": MediaTypeManifest, "digest": amd, "size": 100, "platform": map[string]string{"architecture": "amd64", "os": "linux"}},
		{"mediaType": MediaTypeManifest, "digest": arm, "size": 100, "platform": map[string]string{"architecture": "arm64", "os": "linux", "variant": "v8"}},
	}})
	ix = r.put(b, MediaTypeIndex)
	return
}

func TestResolvePlatformFromAnIndex(t *testing.T) {
	r := newRegistry(t)
	ix, amd, arm := platformIndex(r)
	c, ctx := r.client(), context.Background()
	for _, p := range []Platform{{"linux", "arm64", ""}, {"linux", "arm64", "v8"}} {
		if got, err := c.ResolvePlatform(ctx, "shop/checkout", ix, p); err != nil || got != arm {
			t.Fatalf("%+v: %s %v, want the arm64 manifest", p, got, err)
		}
	}
	if got, err := c.ResolvePlatform(ctx, "shop/checkout", ix, Platform{"linux", "amd64", ""}); err != nil || got != amd {
		t.Fatalf("amd64: %s %v", got, err)
	}
	_, err := c.ResolvePlatform(ctx, "shop/checkout", ix, Platform{"linux", "arm", "v7"})
	if code := codeOf(t, err); code != CodeDigestUnresolvable {
		t.Fatalf("code %s", code)
	}
}

func TestResolvePlatformOfASingleManifest(t *testing.T) {
	r := newRegistry(t)
	_, amd, arm := platformIndex(r)
	c, ctx := r.client(), context.Background()
	if got, err := c.ResolvePlatform(ctx, "shop/checkout", arm, Platform{"linux", "arm64", ""}); err != nil || got != arm {
		t.Fatalf("%s %v", got, err)
	}
	_, err := c.ResolvePlatform(ctx, "shop/checkout", amd, Platform{"linux", "arm64", ""})
	if code := codeOf(t, err); code != CodeDigestUnresolvable {
		t.Fatalf("an amd64 manifest resolved for arm64: %s", code)
	}
	_, err = c.ResolvePlatform(ctx, "shop/checkout", digestOf([]byte("absent")), Platform{"linux", "arm64", ""})
	if code := codeOf(t, err); code != CodeDigestUnresolvable {
		t.Fatalf("an absent digest: %s", code)
	}
	// an artifact manifest names no platform
	empty := r.put([]byte(`{}`), "application/vnd.oci.empty.v1+json")
	art := r.put(manifest(empty, MediaTypeManifest), MediaTypeManifest)
	_, err = c.ResolvePlatform(ctx, "shop/checkout", art, Platform{"linux", "arm64", ""})
	if code := codeOf(t, err); code != CodeDigestUnresolvable {
		t.Fatalf("an artifact: %s", code)
	}
}

func TestContentMustMatchItsDigest(t *testing.T) {
	r := newRegistry(t)
	_, _, arm := platformIndex(r)
	r.mu.Lock()
	r.content[string(arm)] = append(r.content[string(arm)], ' ')
	r.mu.Unlock()
	if _, err := r.client().ResolvePlatform(context.Background(), "shop/checkout", arm, Platform{"linux", "arm64", ""}); err == nil ||
		!strings.Contains(err.Error(), "does not match its digest") {
		t.Fatalf("tampered manifest: %v", err)
	}
}

func TestBadNamesNeverReachTheRegistry(t *testing.T) {
	r := newRegistry(t)
	c, ctx := r.client(), context.Background()
	for _, repo := range []string{"../etc", "Shop/Checkout", "shop//checkout", "shop/checkout?x=1", ""} {
		if _, err := c.Referrers(ctx, repo, subject, ""); err == nil {
			t.Errorf("repository %q accepted", repo)
		}
	}
	if _, err := c.Referrers(ctx, "shop/checkout", "sha512:abc", ""); err == nil {
		t.Error("a non-sha256 subject accepted")
	}
	if _, err := c.ResolvePlatform(ctx, "shop/checkout", subject, Platform{}); err == nil {
		t.Error("an empty platform accepted")
	}
	if len(r.accept) != 0 {
		t.Fatalf("%d requests reached the registry", len(r.accept))
	}
}
