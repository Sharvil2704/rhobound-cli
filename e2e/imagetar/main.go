// SPDX-License-Identifier: Apache-2.0

// Command imagetar writes the cluster test's image (the demo services and the load generator, the same files as
// e2e/Dockerfile: a scratch image holding /demoapp and /loadgen, entry point /demoapp) as a docker-archive tar,
// for any architecture and without docker or emulation: it cross-compiles both programs as static Go binaries
// (CGO_ENABLED=0) and writes the image's layer, config and manifest itself.
//
//	go run ./e2e/imagetar -arch amd64 -o rhobound-demo-amd64.tar
//
// The tar is what `docker save` writes, so `docker load`, `ctr images import` (k3s: `k3s ctr images import`),
// `kind load image-archive` and k3s's agent/images folder all take it; it names the image rhobound-demo:e2e,
// which containerd stores as docker.io/library/rhobound-demo:e2e, the name the test's pods ask for. The same
// sources give the same tar (fixed time stamps, -trimpath).
package main

import (
	"archive/tar"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// epoch is the time stamp of every file and of the image: the tar depends on the binaries only.
var epoch = time.Unix(0, 0).UTC()

// file is one file of the image's single layer.
type file struct {
	name string // path in the image, without the leading slash
	data []byte
}

func main() {
	arch := flag.String("arch", "amd64", "GOARCH of the image (amd64, arm64, ...)")
	tag := flag.String("tag", "rhobound-demo:e2e", "the image's name")
	out := flag.String("o", "", "the tar to write (required)")
	flag.Parse()
	if *out == "" || flag.NArg() > 0 {
		fmt.Fprintln(os.Stderr, "usage: go run ./e2e/imagetar [-arch amd64] [-tag rhobound-demo:e2e] -o FILE.tar")
		os.Exit(2)
	}
	if err := run(*arch, *tag, *out); err != nil {
		fmt.Fprintln(os.Stderr, "imagetar:", err)
		os.Exit(1)
	}
}

func run(arch, tag, out string) error {
	root, err := moduleRoot()
	if err != nil {
		return err
	}
	tmp, err := os.MkdirTemp("", "imagetar-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)
	var files []file
	for _, b := range []string{"demoapp", "loadgen"} {
		bin := filepath.Join(tmp, b)
		cmd := exec.Command("go", "build", "-trimpath", "-o", bin, "./e2e/"+b)
		cmd.Dir = root
		cmd.Env = append(os.Environ(), "CGO_ENABLED=0", "GOOS=linux", "GOARCH="+arch)
		if msg, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("go build %s for linux/%s: %v\n%s", b, arch, err, msg)
		}
		data, err := os.ReadFile(bin)
		if err != nil {
			return err
		}
		files = append(files, file{b, data})
	}
	var buf bytes.Buffer
	if err := writeArchive(&buf, files, arch, tag); err != nil {
		return err
	}
	if err := os.WriteFile(out, buf.Bytes(), 0o644); err != nil {
		return err
	}
	fmt.Printf("wrote %s: %s for linux/%s, %.1f MiB\n", out, tag, arch, float64(buf.Len())/(1<<20))
	return nil
}

// moduleRoot is the folder of the go.mod this command is built in.
func moduleRoot() (string, error) {
	out, err := exec.Command("go", "env", "GOMOD").Output()
	if err != nil {
		return "", fmt.Errorf("go env GOMOD: %v", err)
	}
	mod := strings.TrimSpace(string(out))
	if mod == "" || mod == os.DevNull {
		return "", fmt.Errorf("not inside the module: run it from the repository")
	}
	return filepath.Dir(mod), nil
}

// imageConfig is the part of the image configuration this image sets (the OCI and docker formats share it).
type imageConfig struct {
	Architecture string    `json:"architecture"`
	OS           string    `json:"os"`
	Created      time.Time `json:"created"`
	Config       struct {
		Entrypoint   []string            `json:"Entrypoint"`
		ExposedPorts map[string]struct{} `json:"ExposedPorts"`
	} `json:"config"`
	RootFS struct {
		Type    string   `json:"type"`
		DiffIDs []string `json:"diff_ids"`
	} `json:"rootfs"`
	History []struct {
		Created   time.Time `json:"created"`
		CreatedBy string    `json:"created_by"`
	} `json:"history"`
}

// manifestEntry is one image of a docker-archive's manifest.json.
type manifestEntry struct {
	Config   string   `json:"Config"`
	RepoTags []string `json:"RepoTags"`
	Layers   []string `json:"Layers"`
}

// writeArchive writes a docker-archive (the `docker save` layout): blobs/sha256/<digest> for the layer and the
// config, and manifest.json naming them with the image's tag.
func writeArchive(w io.Writer, files []file, arch, tag string) error {
	var layer bytes.Buffer
	lt := tar.NewWriter(&layer)
	for _, f := range files {
		h := &tar.Header{Name: f.name, Mode: 0o755, Size: int64(len(f.data)), ModTime: epoch, Typeflag: tar.TypeReg}
		if err := lt.WriteHeader(h); err != nil {
			return err
		}
		if _, err := lt.Write(f.data); err != nil {
			return err
		}
	}
	if err := lt.Close(); err != nil {
		return err
	}
	layerDigest := digest(layer.Bytes())

	var cfg imageConfig
	cfg.Architecture, cfg.OS, cfg.Created = arch, "linux", epoch
	cfg.Config.Entrypoint = []string{"/demoapp"}
	cfg.Config.ExposedPorts = map[string]struct{}{"8080/tcp": {}}
	cfg.RootFS.Type, cfg.RootFS.DiffIDs = "layers", []string{"sha256:" + layerDigest}
	cfg.History = append(cfg.History, struct {
		Created   time.Time `json:"created"`
		CreatedBy string    `json:"created_by"`
	}{epoch, "go run ./e2e/imagetar (COPY demoapp loadgen /)"})
	cfgJSON, err := json.Marshal(cfg)
	if err != nil {
		return err
	}
	cfgDigest := digest(cfgJSON)

	man, err := json.Marshal([]manifestEntry{{Config: "blobs/sha256/" + cfgDigest, RepoTags: []string{tag},
		Layers: []string{"blobs/sha256/" + layerDigest}}})
	if err != nil {
		return err
	}
	tw := tar.NewWriter(w)
	for _, d := range []string{"blobs/", "blobs/sha256/"} {
		if err := tw.WriteHeader(&tar.Header{Name: d, Mode: 0o755, ModTime: epoch, Typeflag: tar.TypeDir}); err != nil {
			return err
		}
	}
	for _, f := range []file{{"blobs/sha256/" + layerDigest, layer.Bytes()}, {"blobs/sha256/" + cfgDigest, cfgJSON},
		{"manifest.json", man}} {
		if err := tw.WriteHeader(&tar.Header{Name: f.name, Mode: 0o644, Size: int64(len(f.data)), ModTime: epoch,
			Typeflag: tar.TypeReg}); err != nil {
			return err
		}
		if _, err := tw.Write(f.data); err != nil {
			return err
		}
	}
	return tw.Close()
}

func digest(b []byte) string {
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}
