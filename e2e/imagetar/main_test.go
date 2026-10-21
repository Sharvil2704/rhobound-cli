// SPDX-License-Identifier: Apache-2.0

package main

import (
	"archive/tar"
	"bytes"
	"encoding/json"
	"io"
	"strings"
	"testing"
)

// readTar returns a tar's regular files by name.
func readTar(t *testing.T, b []byte) map[string][]byte {
	t.Helper()
	out := map[string][]byte{}
	tr := tar.NewReader(bytes.NewReader(b))
	for {
		h, err := tr.Next()
		if err == io.EOF {
			return out
		}
		if err != nil {
			t.Fatal(err)
		}
		if h.Typeflag != tar.TypeReg {
			continue
		}
		data, err := io.ReadAll(tr)
		if err != nil {
			t.Fatal(err)
		}
		out[h.Name] = data
		if h.Mode != 0o644 && h.Mode != 0o755 {
			t.Errorf("%s: mode %o", h.Name, h.Mode)
		}
	}
}

// TestArchive reads back what writeArchive wrote, as an importer does: manifest.json names the config and the
// layer by digest, the config's diff_id is the layer's digest, and the layer holds the two programs, executable.
func TestArchive(t *testing.T) {
	var buf bytes.Buffer
	files := []file{{"demoapp", []byte("demo binary")}, {"loadgen", []byte("load binary")}}
	if err := writeArchive(&buf, files, "amd64", "rhobound-demo:e2e"); err != nil {
		t.Fatal(err)
	}
	all := readTar(t, buf.Bytes())
	var man []manifestEntry
	if err := json.Unmarshal(all["manifest.json"], &man); err != nil || len(man) != 1 {
		t.Fatalf("manifest.json: %v %s", err, all["manifest.json"])
	}
	m := man[0]
	if len(m.RepoTags) != 1 || m.RepoTags[0] != "rhobound-demo:e2e" || len(m.Layers) != 1 {
		t.Fatalf("manifest: %+v", m)
	}
	cfgData, layerData := all[m.Config], all[m.Layers[0]]
	if cfgData == nil || layerData == nil {
		t.Fatalf("manifest names files the tar does not hold: %+v (has %d files)", m, len(all))
	}
	if want := "blobs/sha256/" + digest(cfgData); m.Config != want {
		t.Errorf("config at %s, its digest says %s", m.Config, want)
	}
	if want := "blobs/sha256/" + digest(layerData); m.Layers[0] != want {
		t.Errorf("layer at %s, its digest says %s", m.Layers[0], want)
	}
	var cfg imageConfig
	if err := json.Unmarshal(cfgData, &cfg); err != nil {
		t.Fatal(err)
	}
	if cfg.Architecture != "amd64" || cfg.OS != "linux" || strings.Join(cfg.Config.Entrypoint, " ") != "/demoapp" {
		t.Errorf("config: %s", cfgData)
	}
	if _, ok := cfg.Config.ExposedPorts["8080/tcp"]; !ok {
		t.Errorf("config does not expose 8080/tcp: %s", cfgData)
	}
	if len(cfg.RootFS.DiffIDs) != 1 || cfg.RootFS.DiffIDs[0] != "sha256:"+digest(layerData) {
		t.Errorf("diff_ids %v, the layer's digest is %s", cfg.RootFS.DiffIDs, digest(layerData))
	}
	layer := readTar(t, layerData)
	for _, f := range files {
		if !bytes.Equal(layer[f.name], f.data) {
			t.Errorf("layer file %s: %q, want %q", f.name, layer[f.name], f.data)
		}
	}
	tr := tar.NewReader(bytes.NewReader(layerData))
	for h, err := tr.Next(); err == nil; h, err = tr.Next() {
		if h.Mode != 0o755 || h.Uid != 0 || h.Gid != 0 {
			t.Errorf("layer file %s: mode %o, owner %d:%d", h.Name, h.Mode, h.Uid, h.Gid)
		}
	}
	// the same input gives the same bytes
	var again bytes.Buffer
	if err := writeArchive(&again, files, "amd64", "rhobound-demo:e2e"); err != nil || !bytes.Equal(again.Bytes(), buf.Bytes()) {
		t.Errorf("a second archive of the same files differs (%v)", err)
	}
}
