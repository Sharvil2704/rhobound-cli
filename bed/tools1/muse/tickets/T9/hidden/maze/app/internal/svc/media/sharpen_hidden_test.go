//go:build hidden

package media

import (
	"bytes"
	"fmt"
	"io"
	"math/rand/v2"
	"net"
	"net/http"
	"os"
	"sync"
	"testing"
	"time"

	"maze/internal/rt"
)

// the ticket's definitions, written independently of the change under test
var hidG = [7]int{1, 6, 15, 20, 15, 6, 1}

func hidClamp(v int) int { return min(127, max(0, v)) }

func hidRefSharpen(img []byte) []byte {
	out := make([]byte, len(img))
	for y := range 128 {
		for x := range 128 {
			s := 0
			for dy := -3; dy <= 3; dy++ {
				for dx := -3; dx <= 3; dx++ {
					s += hidG[dy+3] * hidG[dx+3] * int(img[hidClamp(y+dy)*128+hidClamp(x+dx)])
				}
			}
			p := int(img[y*128+x])
			v := 20480*p - 3*s + 4096
			q := v / 8192
			if v < 0 && v%8192 != 0 {
				q-- // floor
			}
			out[y*128+x] = byte(min(255, max(0, q)))
		}
	}
	return out
}

// Thumb as it was before the ticket
func hidRefThumb(seed uint64) []byte {
	out := make([]byte, 16<<10)
	for i := range out {
		s := 0
		for k := range 4 {
			s += int((seed + uint64(i*4+k)*2654435761) >> 24 & 0xff)
		}
		out[i] = byte(s / 4)
	}
	return out
}

func hidCheck(t *testing.T, what string, img []byte) {
	t.Helper()
	in := append([]byte(nil), img...)
	got, want := Sharpen(img), hidRefSharpen(in)
	if !bytes.Equal(img, in) {
		t.Fatalf("Sharpen(%s) modified its input", what)
	}
	if len(got) != len(want) {
		t.Fatalf("Sharpen(%s): %d bytes, want %d", what, len(got), len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("Sharpen(%s): pixel (%d, %d) is %d, want %d", what, i%128, i/128, got[i], want[i])
		}
	}
}

func TestHiddenSharpenExact(t *testing.T) {
	r := rand.New(rand.NewPCG(11, 12))
	for i := range 12 {
		img := make([]byte, 16<<10)
		for j := range img {
			img[j] = byte(r.IntN(256))
		}
		hidCheck(t, fmt.Sprintf("random image %d", i), img)
	}
	for _, s := range []uint64{1, 2, 3, 77, 4096, 1 << 33} {
		hidCheck(t, fmt.Sprintf("Thumb(%d)", s), hidRefThumb(s))
	}
}

func TestHiddenSharpenEdgesAndExtremes(t *testing.T) {
	flat := bytes.Repeat([]byte{137}, 16<<10)
	hidCheck(t, "a flat image", flat)
	if got := Sharpen(flat); !bytes.Equal(got, flat) {
		t.Fatalf("a flat image changed")
	}
	stripes := make([]byte, 16<<10)
	for j := range stripes {
		if (j%128)/4%2 == 0 {
			stripes[j] = 255
		}
	}
	hidCheck(t, "black and white stripes (clamped at 0 and 255)", stripes)
	corner := make([]byte, 16<<10)
	corner[0], corner[127], corner[127*128], corner[16<<10-1] = 255, 200, 100, 50
	hidCheck(t, "four bright corners (edge clamping)", corner)
}

func TestHiddenThumbUnchanged(t *testing.T) {
	for _, s := range []uint64{0, 1, 99, 1 << 40} {
		if !bytes.Equal(Thumb(s), hidRefThumb(s)) {
			t.Fatalf("Thumb(%d) changed", s)
		}
	}
}

func TestHiddenSharpenConcurrent(t *testing.T) {
	imgs := make([][]byte, 8)
	want := make([][]byte, 8)
	for i := range imgs {
		imgs[i] = hidRefThumb(uint64(i + 1))
		want[i] = hidRefSharpen(imgs[i])
	}
	var wg sync.WaitGroup
	errs := make(chan string, 8)
	for g := range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range 16 {
				j := (g + i) % 8
				if !bytes.Equal(Sharpen(imgs[j]), want[j]) {
					errs <- fmt.Sprintf("image %d differs under concurrent calls", j)
					return
				}
			}
		}()
	}
	wg.Wait()
	close(errs)
	for e := range errs {
		t.Fatal(e)
	}
}

// TestHiddenHookServesSharpened runs the media service (rt.Main) with only its /thumb code hook and reads three
// answers: each is Sharpen(Thumb(seed)) for consecutive seeds (found by the first row, then checked whole; the
// package's own tests may have called the hook first).
func TestHiddenHookServesSharpened(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("no loopback listener (this check serves the hook on 127.0.0.1): %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()
	os.Setenv("MAZE_CONFIG", `{"service":"media","workers":4,"routes":{"/thumb":{"work":{"mean_ms":0,"cs2":0},"code":"media.thumb"}}}`)
	os.Setenv("MAZE_LISTEN", addr)
	os.Setenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "http://127.0.0.1:9/v1/traces")
	go rt.Main()
	cl := &http.Client{Timeout: 30 * time.Second}
	get := func(path string) ([]byte, error) {
		resp, err := cl.Get("http://" + addr + path)
		if err != nil {
			return nil, err
		}
		defer resp.Body.Close()
		b, err := io.ReadAll(resp.Body)
		if resp.StatusCode != http.StatusOK {
			return nil, fmt.Errorf("%s: %s", path, resp.Status)
		}
		return b, err
	}
	deadline := time.Now().Add(15 * time.Second)
	for {
		if _, err := get("/healthz"); err == nil {
			break
		} else if time.Now().After(deadline) {
			t.Fatalf("the service did not come up: %v", err)
		}
		time.Sleep(50 * time.Millisecond)
	}
	var got [][]byte
	for range 3 {
		b, err := get("/thumb")
		if err != nil {
			t.Fatal(err)
		}
		if len(b) != 16<<10 {
			t.Fatalf("/thumb answered %d bytes, want %d", len(b), 16<<10)
		}
		got = append(got, b)
	}
	// the first row of Sharpen(Thumb(s)) needs only Thumb's first four rows: cheap to scan many seeds
	row0 := func(s uint64) []byte {
		th := hidRefThumb(s)
		return hidRefSharpen(th)[:128]
	}
	for s0 := uint64(1); s0 <= 4000; s0++ {
		if !bytes.Equal(got[0][:128], row0(s0)) {
			continue
		}
		ok := true
		for i, b := range got {
			ok = ok && bytes.Equal(b, hidRefSharpen(hidRefThumb(s0+uint64(i))))
		}
		if ok {
			return
		}
	}
	t.Fatalf("/thumb's answers are not Sharpen(Thumb(seed)) for three consecutive seeds among the first 4000")
}
