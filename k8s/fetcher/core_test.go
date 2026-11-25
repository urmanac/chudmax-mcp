package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// makeTarball returns the gzipped tar bytes for the given files; paths are
// relative to the artifact root, exactly how Flux packs an artifact.
func makeTarball(t *testing.T, files map[string]string) []byte {
	t.Helper()
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	for name, content := range files {
		hdr := &tar.Header{Name: name, Mode: 0o644, Size: int64(len(content))}
		if err := tw.WriteHeader(hdr); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write([]byte(content)); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

// serveTarball stands in for source-controller: one tarball over plain HTTP.
// The returned count counts downloads, to prove a no-op does not fetch.
func serveTarball(t *testing.T, b []byte) (url string, count func() int) {
	t.Helper()
	var downloads int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		downloads++
		w.Header().Set("Content-Type", "application/gzip")
		w.Write(b)
	}))
	t.Cleanup(srv.Close)
	return srv.URL + "/artifact/test.tar.gz", func() int { return downloads }
}

func testOpts() CoreOpts {
	return CoreOpts{
		Retries:       1,
		Keep:          3,
		MaxDownloadSz: 10 << 20,
		MaxUntarSz:    20 << 20,
		Now:           func() time.Time { return time.Date(2026, 11, 25, 15, 0, 0, 0, time.UTC) },
	}
}

func shaOf(b []byte) string { return fmt.Sprintf("sha256:%x", sha256.Sum256(b)) }

func readMeta(t *testing.T, path string) ArtifactMeta {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var m ArtifactMeta
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func readCurrent(t *testing.T, root, rel string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(root, "current", rel))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func currentPointsAt(t *testing.T, root string) string {
	t.Helper()
	tgt, err := os.Readlink(filepath.Join(root, "current"))
	if err != nil {
		t.Fatal(err)
	}
	return filepath.Base(tgt)
}

func revisionDirs(t *testing.T, root string) []string {
	t.Helper()
	entries, err := os.ReadDir(filepath.Join(root, "revisions"))
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, e := range entries {
		if e.IsDir() && e.Name()[0] != '.' {
			names = append(names, e.Name())
		}
	}
	return names
}

func TestFetchHappyPath(t *testing.T) {
	b := makeTarball(t, map[string]string{"tickets.md": "v1\n", "sub/STATE.md": "state\n"})
	url, _ := serveTarball(t, b)
	root := t.TempDir()
	o := testOpts()
	o.Source = "flag" // as the fetch subcommand does

	swapped, err := FetchAndSwap(context.Background(), url, shaOf(b), root, o)
	if err != nil || !swapped {
		t.Fatalf("swapped=%v err=%v", swapped, err)
	}
	if got := readCurrent(t, root, "tickets.md"); got != "v1\n" {
		t.Fatalf("tickets.md = %q", got)
	}
	if got := readCurrent(t, root, "sub/STATE.md"); got != "state\n" {
		t.Fatalf("sub/STATE.md = %q", got)
	}
	if want := shaOf(b)[len("sha256:"):]; currentPointsAt(t, root) != want {
		t.Fatalf("current -> %s, want %s", currentPointsAt(t, root), want)
	}
	meta := readMeta(t, filepath.Join(root, "current", "artifact.json"))
	if meta.Digest != shaOf(b) || meta.URL != url || meta.Source != "flag" {
		t.Fatalf("artifact.json = %+v", meta)
	}
	if meta.Unpacked != "2026-11-25T15:00:00Z" {
		t.Fatalf("artifact.json unpacked = %q", meta.Unpacked)
	}
}

func TestDigestMismatchKeepsPreviousTree(t *testing.T) {
	b := makeTarball(t, map[string]string{"tickets.md": "v1\n"})
	url, _ := serveTarball(t, b)
	root := t.TempDir()
	if _, err := FetchAndSwap(context.Background(), url, shaOf(b), root, testOpts()); err != nil {
		t.Fatal(err)
	}

	wrong := "sha256:" + "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
	if _, err := FetchAndSwap(context.Background(), url, wrong, root, testOpts()); err == nil {
		t.Fatal("expected a digest-mismatch error")
	}
	if got := readCurrent(t, root, "tickets.md"); got != "v1\n" {
		t.Fatalf("previous tree not kept: %q", got)
	}
	for _, e := range revisionDirs(t, root) {
		if e[0] == '.' {
			t.Fatalf("leftover temp dir %q after failure", e)
		}
	}
}

func TestSecondRevisionSwapAndRetention(t *testing.T) {
	v1 := makeTarball(t, map[string]string{"tickets.md": "v1\n"})
	v2 := makeTarball(t, map[string]string{"tickets.md": "v2\n"})
	v3 := makeTarball(t, map[string]string{"tickets.md": "v3\n"})
	v4 := makeTarball(t, map[string]string{"tickets.md": "v4\n"})
	// One artifact path per revision, the way source-controller serves them:
	// the URL is revision-specific, so fetch(url_i, digest_i) always matches.
	urls := map[string]string{}
	for _, b := range [][]byte{v1, v2, v3, v4} {
		urls[shaOf(b)] = serveFixed(t, b)
	}
	root := t.TempDir()
	o := testOpts()

	for _, b := range [][]byte{v1, v2, v3, v4} {
		if _, err := FetchAndSwap(context.Background(), urls[shaOf(b)], shaOf(b), root, o); err != nil {
			t.Fatal(err)
		}
	}
	if got := readCurrent(t, root, "tickets.md"); got != "v4\n" {
		t.Fatalf("current content = %q, want v4", got)
	}
	if dirs := revisionDirs(t, root); len(dirs) != 3 {
		t.Fatalf("retention kept %d dirs (%v), want 3", len(dirs), dirs)
	}
	if currentPointsAt(t, root) != shaOf(v4)[len("sha256:"):] {
		t.Fatal("current does not point at v4")
	}
}

// serveFixed serves the given bytes at a fixed, revision-specific path.
func serveFixed(t *testing.T, b []byte) string {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/gzip")
		w.Write(b)
	}))
	t.Cleanup(srv.Close)
	return srv.URL + "/artifact/test.tar.gz"
}

func TestSameDigestNoOpAndRollback(t *testing.T) {
	v1 := makeTarball(t, map[string]string{"tickets.md": "v1\n"})
	v2 := makeTarball(t, map[string]string{"tickets.md": "v2\n"})
	// One URL per revision, like source-controller (each artifact has its own
	// path); the digest always matches what its URL serves.
	serve := func(b []byte) (string, func() int) { return serveTarball(t, b) }
	url1, count1 := serve(v1)
	url2, count2 := serve(v2)
	root := t.TempDir()
	o := testOpts()

	if _, err := FetchAndSwap(context.Background(), url1, shaOf(v1), root, o); err != nil {
		t.Fatal(err)
	}
	if n := count1(); n != 1 {
		t.Fatalf("first fetch downloaded %d times", n)
	}
	// Same digest again: no download, no change (restart case).
	if swapped, err := FetchAndSwap(context.Background(), url1, shaOf(v1), root, o); err != nil || swapped {
		t.Fatalf("no-op fetch: swapped=%v err=%v", swapped, err)
	}
	if n := count1(); n != 1 {
		t.Fatalf("no-op fetched again (%d downloads)", n)
	}
	// A new revision.
	if _, err := FetchAndSwap(context.Background(), url2, shaOf(v2), root, o); err != nil {
		t.Fatal(err)
	}
	if got := readCurrent(t, root, "tickets.md"); got != "v2\n" {
		t.Fatalf("v2 not served: %q", got)
	}
	// Rollback to v1: its dir is already unpacked and complete, so no
	// download, and the original artifact.json stays.
	v1meta := filepath.Join(root, "revisions", shaOf(v1)[len("sha256:"):], "artifact.json")
	metaBeforeRaw, err := os.ReadFile(v1meta)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := FetchAndSwap(context.Background(), url1, shaOf(v1), root, o); err != nil {
		t.Fatal(err)
	}
	if n := count1(); n != 1 {
		t.Fatalf("rollback downloaded again (%d)", n)
	}
	if got := readCurrent(t, root, "tickets.md"); got != "v1\n" {
		t.Fatalf("rollback content = %q", got)
	}
	metaAfterRaw, err := os.ReadFile(v1meta)
	if err != nil {
		t.Fatal(err)
	}
	if string(metaAfterRaw) != string(metaBeforeRaw) {
		t.Fatalf("rollback rewrote artifact.json:\nbefore %s\nafter  %s", metaBeforeRaw, metaAfterRaw)
	}
	if n := count2(); n != 1 {
		t.Fatalf("v2 fetched more than once (%d)", n)
	}
}

func TestRefusesUnsafeInputs(t *testing.T) {
	root := t.TempDir()
	if _, err := FetchAndSwap(context.Background(), "http://x/artifact.tar.gz", "", root, testOpts()); err == nil {
		t.Fatal("empty digest must be refused")
	}
	if _, err := FetchAndSwap(context.Background(), "", "sha256:abc", root, testOpts()); err == nil {
		t.Fatal("empty url must be refused")
	}
	if _, err := FetchAndSwap(context.Background(), "http://x/a.tar.gz", "sha1:abc", root, testOpts()); err == nil {
		t.Fatal("non-sha256 digest must be refused")
	}
	if _, err := FetchAndSwap(context.Background(), "http://x/a.tar.gz", "not-a-digest", root, testOpts()); err == nil {
		t.Fatal("malformed digest must be refused")
	}
}

func TestRefusesForeignCurrentSymlink(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "elsewhere"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("elsewhere", filepath.Join(root, "current")); err != nil {
		t.Fatal(err)
	}
	b := makeTarball(t, map[string]string{"tickets.md": "v1\n"})
	url, _ := serveTarball(t, b)
	if _, err := FetchAndSwap(context.Background(), url, shaOf(b), root, testOpts()); err == nil {
		t.Fatal("a current symlink outside revisions/ must be refused")
	}
}

// TestOriginRevisionRecorded covers the phase-4b addition: watch mode hands the
// CoreOpts the git-side revision the generator recorded, and artifact.json
// carries it as origin_revision; the one-shot fetch mode (no object read)
// leaves the field out entirely.
func TestOriginRevisionRecorded(t *testing.T) {
	b := makeTarball(t, map[string]string{"tickets.md": "origin\n"})
	url, _ := serveTarball(t, b)
	digest := shaOf(b)

	root := t.TempDir()
	o := testOpts()
	o.OriginRevision = "main@sha1:abc"
	if _, err := FetchAndSwap(context.Background(), url, digest, root, o); err != nil {
		t.Fatal(err)
	}
	m := readMeta(t, filepath.Join(root, "current", "artifact.json"))
	if m.OriginRevision != "main@sha1:abc" {
		t.Fatalf("origin_revision = %q, want main@sha1:abc", m.OriginRevision)
	}

	root = t.TempDir()
	o = testOpts()
	if _, err := FetchAndSwap(context.Background(), url, digest, root, o); err != nil {
		t.Fatal(err)
	}
	m = readMeta(t, filepath.Join(root, "current", "artifact.json"))
	if m.OriginRevision != "" {
		t.Fatalf("origin_revision = %q, want absent", m.OriginRevision)
	}
}
