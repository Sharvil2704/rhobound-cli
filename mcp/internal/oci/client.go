// SPDX-License-Identifier: Apache-2.0

// Package oci reads image performance profiles from an OCI 1.1 registry (DATA.md 9): the referrers of an image
// (the referrers API, else the sha256-<hex> tag fallback, filtered by artifact type on the client side because a
// registry may ignore the filter), the platform manifest an image index points to for one architecture, and the
// perf-profile/v0.1 statement with its field rules and the checks of DATA.md 9.5 that need no signature.
// Signatures are not verified in this version: the only Verifier refuses (profile.bad_signature).
package oci

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

// Media types of the OCI image spec and their Docker predecessors.
const (
	MediaTypeIndex          = "application/vnd.oci.image.index.v1+json"
	MediaTypeManifest       = "application/vnd.oci.image.manifest.v1+json"
	MediaTypeDockerList     = "application/vnd.docker.distribution.manifest.list.v2+json"
	MediaTypeDockerManifest = "application/vnd.docker.distribution.manifest.v2+json"
)

// Digest is a content digest, "sha256:<64 hex>".
type Digest string

var digestRE = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)

// Hex returns the digest's hex part, or "" when it is not a sha256 digest.
func (d Digest) Hex() string {
	if !digestRE.MatchString(string(d)) {
		return ""
	}
	return string(d[len("sha256:"):])
}

// Platform names one platform of a multi-platform image.
type Platform struct{ OS, Arch, Variant string }

// Descriptor is an OCI content descriptor.
type Descriptor struct {
	MediaType    string            `json:"mediaType"`
	Digest       Digest            `json:"digest"`
	Size         int64             `json:"size"`
	ArtifactType string            `json:"artifactType,omitempty"`
	Annotations  map[string]string `json:"annotations,omitempty"`
	Platform     *struct {
		Architecture string `json:"architecture"`
		OS           string `json:"os"`
		Variant      string `json:"variant,omitempty"`
	} `json:"platform,omitempty"`
}

// TokenSource gives the Authorization header for a registry, scheme included (for Amazon ECR, "Basic " and the
// authorization token). The ECR binding needs the AWS SDK and is not part of this package.
type TokenSource interface {
	Token(ctx context.Context, registry string) (string, error)
}

// Client reads one registry. Base is its URL ("https://<host>"); HTTP nil means a client with a 30 s timeout;
// Tokens nil means anonymous requests.
type Client struct {
	Base   string
	HTTP   *http.Client
	Tokens TokenSource
}

const (
	// maxDocument bounds a manifest, an index or a config read from the registry (registries accept manifests
	// up to 4 MiB).
	maxDocument = 4 << 20
	// maxPages bounds a paginated referrers listing.
	maxPages = 100
)

// the repository name grammar of the OCI distribution spec
var repoRE = regexp.MustCompile(`^[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*(/[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*)*$`)

// Referrers returns the descriptors that refer to subject in repo with the given artifact type ("" for all). It
// asks the referrers API, falls back to the sha256-<hex> tag when the registry has no referrers API (404), and
// filters by artifact type itself, so a registry that ignores the filter changes nothing. No referrer is an
// empty list, not an error; the caller reports profile.not_found.
func (c *Client) Referrers(ctx context.Context, repo string, subject Digest, artifactType string) ([]Descriptor, error) {
	if !repoRE.MatchString(repo) || subject.Hex() == "" {
		return nil, errors.New("oci: bad repository name or subject digest")
	}
	next := c.Base + "/v2/" + repo + "/referrers/" + string(subject)
	if artifactType != "" {
		next += "?artifactType=" + url.QueryEscape(artifactType)
	}
	var out []Descriptor
	for page := 0; next != ""; page++ {
		if page == maxPages {
			return nil, errors.New("oci: the referrers listing does not end")
		}
		body, hdr, status, err := c.get(ctx, next, MediaTypeIndex)
		if err != nil {
			return nil, err
		}
		if status == http.StatusNotFound && page == 0 {
			return c.referrersByTag(ctx, repo, subject, artifactType)
		}
		if status != http.StatusOK {
			return nil, fmt.Errorf("oci: referrers: status %d", status)
		}
		ds, err := parseIndex(body, hdr.Get("Content-Type"))
		if err != nil {
			return nil, err
		}
		out = append(out, filter(ds, artifactType)...)
		if next, err = nextLink(next, hdr.Get("Link")); err != nil {
			return nil, err
		}
	}
	return out, nil
}

// referrersByTag reads the fallback tag of the OCI 1.1 distribution spec: an index tagged sha256-<hex>.
func (c *Client) referrersByTag(ctx context.Context, repo string, subject Digest, artifactType string) ([]Descriptor, error) {
	body, hdr, status, err := c.get(ctx, c.Base+"/v2/"+repo+"/manifests/sha256-"+subject.Hex(), MediaTypeIndex)
	if err != nil {
		return nil, err
	}
	switch status {
	case http.StatusNotFound:
		return nil, nil
	case http.StatusOK:
	default:
		return nil, fmt.Errorf("oci: referrers tag: status %d", status)
	}
	ds, err := parseIndex(body, hdr.Get("Content-Type"))
	if err != nil {
		return nil, err
	}
	return filter(ds, artifactType), nil
}

func filter(ds []Descriptor, artifactType string) []Descriptor {
	if artifactType == "" {
		return ds
	}
	var out []Descriptor
	for _, d := range ds {
		if d.ArtifactType == artifactType {
			out = append(out, d)
		}
	}
	return out
}

type index struct {
	MediaType    string       `json:"mediaType"`
	ArtifactType string       `json:"artifactType"`
	Manifests    []Descriptor `json:"manifests"`
	Config       *Descriptor  `json:"config"`
}

// parseIndex reads an image index and checks every media type in it.
func parseIndex(body []byte, contentType string) ([]Descriptor, error) {
	if err := checkMediaType(contentType); err != nil {
		return nil, err
	}
	var ix index
	if err := json.Unmarshal(body, &ix); err != nil {
		return nil, fmt.Errorf("oci: the index is not JSON: %w", err)
	}
	if ix.MediaType != "" && ix.MediaType != MediaTypeIndex && ix.MediaType != MediaTypeDockerList {
		if err := checkMediaType(ix.MediaType); err != nil {
			return nil, err
		}
		return nil, fmt.Errorf("oci: expected an image index, got %q", ix.MediaType)
	}
	for _, d := range ix.Manifests {
		if err := checkDescriptor(d); err != nil {
			return nil, err
		}
	}
	return ix.Manifests, nil
}

// checkMediaType refuses a media type with parameters (";version=..."), which Amazon ECR rejects (DATA.md 9.2).
func checkMediaType(mt string) error {
	if mt == "" || !strings.Contains(mt, ";") {
		return nil
	}
	e := refusal(CodeMediaTypeParameter, "a media type carries parameters",
		"write media types without parameters; Amazon ECR rejects manifests whose media types carry ;version= parameters")
	if base, _, err := mime.ParseMediaType(mt); err == nil {
		if n, untrusted := name(base); !untrusted {
			e.Finding.Subject = n
		}
	}
	return e
}

func checkDescriptor(d Descriptor) error {
	if err := checkMediaType(d.MediaType); err != nil {
		return err
	}
	if err := checkMediaType(d.ArtifactType); err != nil {
		return err
	}
	if d.Digest.Hex() == "" {
		return errors.New("oci: a descriptor without a sha256 digest")
	}
	return nil
}

// nextLink follows a Link header's rel="next" target, resolved against the current URL.
func nextLink(current, link string) (string, error) {
	for _, part := range strings.Split(link, ",") {
		part = strings.TrimSpace(part)
		if !strings.Contains(part, `rel="next"`) || !strings.HasPrefix(part, "<") {
			continue
		}
		end := strings.Index(part, ">")
		if end < 0 {
			return "", errors.New("oci: bad Link header")
		}
		base, err := url.Parse(current)
		if err != nil {
			return "", err
		}
		ref, err := url.Parse(part[1:end])
		if err != nil {
			return "", err
		}
		u := base.ResolveReference(ref)
		if u.Host != base.Host || u.Scheme != base.Scheme {
			return "", errors.New("oci: the next page is on another host")
		}
		return u.String(), nil
	}
	return "", nil
}

// ResolvePlatform returns the platform manifest's digest for p (DATA.md 9.5 #1): an image index resolves to its
// entry for p; a single manifest is itself, if its config says it is built for p. Anything else is refused as
// profile.digest_unresolvable. A running pod may report the index digest; comparisons of image identity are made
// between platform manifests only.
func (c *Client) ResolvePlatform(ctx context.Context, repo string, d Digest, p Platform) (Digest, error) {
	if !repoRE.MatchString(repo) || d.Hex() == "" || p.OS == "" || p.Arch == "" {
		return "", errors.New("oci: bad repository name, digest or platform")
	}
	body, ct, err := c.getVerified(ctx, repo, "manifests", d,
		strings.Join([]string{MediaTypeIndex, MediaTypeManifest, MediaTypeDockerList, MediaTypeDockerManifest}, ", "))
	if err != nil {
		return "", err
	}
	var doc index
	if err := json.Unmarshal(body, &doc); err != nil {
		return "", fmt.Errorf("oci: the manifest is not JSON: %w", err)
	}
	mt := doc.MediaType
	if mt == "" {
		mt, _, _ = mime.ParseMediaType(ct)
	}
	if err := checkMediaType(doc.MediaType); err != nil {
		return "", err
	}
	unresolvable := func(why string) error {
		return refusal(CodeDigestUnresolvable, why,
			"name the image by a digest built for the node's platform, or by its multi-platform index")
	}
	switch mt {
	case MediaTypeIndex, MediaTypeDockerList:
		for _, m := range doc.Manifests {
			if err := checkDescriptor(m); err != nil {
				return "", err
			}
			if m.Platform != nil && m.Platform.OS == p.OS && m.Platform.Architecture == p.Arch && variantMatches(p, m.Platform.Variant) {
				return m.Digest, nil
			}
		}
		return "", unresolvable(fmt.Sprintf("the image index has no manifest for %s/%s", p.OS, p.Arch))
	case MediaTypeManifest, MediaTypeDockerManifest:
		if doc.Config == nil {
			return "", unresolvable("the manifest has no config")
		}
		if err := checkDescriptor(*doc.Config); err != nil {
			return "", err
		}
		cfg, _, err := c.getVerified(ctx, repo, "blobs", doc.Config.Digest, "*/*")
		if err != nil {
			return "", err
		}
		var img struct{ OS, Architecture, Variant string }
		if json.Unmarshal(cfg, &img) != nil || img.OS == "" {
			return "", unresolvable("the manifest's config names no platform (an artifact, not an image)")
		}
		if img.OS != p.OS || img.Architecture != p.Arch || !variantMatches(p, img.Variant) {
			return "", unresolvable(fmt.Sprintf("the image is built for %s/%s, not %s/%s", img.OS, img.Architecture, p.OS, p.Arch))
		}
		return d, nil
	}
	return "", unresolvable("the digest names neither an image index nor an image manifest")
}

// variantMatches compares variants; an arm64 entry without a variant is v8.
func variantMatches(p Platform, v string) bool {
	if p.Variant == "" {
		return true
	}
	if v == "" && p.Arch == "arm64" {
		v = "v8"
	}
	return v == p.Variant
}

// getVerified reads a manifest or blob by digest and checks that its bytes are that digest.
func (c *Client) getVerified(ctx context.Context, repo, kind string, d Digest, accept string) ([]byte, string, error) {
	body, hdr, status, err := c.get(ctx, c.Base+"/v2/"+repo+"/"+kind+"/"+string(d), accept)
	if err != nil {
		return nil, "", err
	}
	if status == http.StatusNotFound {
		return nil, "", refusal(CodeDigestUnresolvable, "the registry does not have the digest",
			"name the image by a digest that is in the registry")
	}
	if status != http.StatusOK {
		return nil, "", fmt.Errorf("oci: %s: status %d", kind, status)
	}
	sum := sha256.Sum256(body)
	if hex.EncodeToString(sum[:]) != d.Hex() {
		return nil, "", errors.New("oci: the registry's content does not match its digest")
	}
	ct := hdr.Get("Content-Type")
	if kind == "manifests" {
		if err := checkMediaType(ct); err != nil {
			return nil, "", err
		}
	}
	return body, ct, nil
}

func (c *Client) get(ctx context.Context, at, accept string) ([]byte, http.Header, int, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, at, nil)
	if err != nil {
		return nil, nil, 0, err
	}
	req.Header.Set("Accept", accept)
	if c.Tokens != nil {
		tok, err := c.Tokens.Token(ctx, req.URL.Host)
		if err != nil {
			return nil, nil, 0, fmt.Errorf("oci: registry token: %w", err)
		}
		req.Header.Set("Authorization", tok)
	}
	hc := c.HTTP
	if hc == nil {
		hc = &http.Client{Timeout: 30 * time.Second}
	}
	resp, err := hc.Do(req)
	if err != nil {
		return nil, nil, 0, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxDocument+1))
	if err != nil {
		return nil, nil, 0, err
	}
	if len(body) > maxDocument {
		return nil, nil, 0, errors.New("oci: a registry document over 4 MiB")
	}
	return bytes.Clone(body), resp.Header, resp.StatusCode, nil
}
