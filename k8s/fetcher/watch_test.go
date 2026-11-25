package main

import (
	"context"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/fluxcd/pkg/apis/meta"
	sourcev1 "github.com/fluxcd/source-controller/api/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/watch"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func testScheme(t *testing.T) *runtime.Scheme {
	t.Helper()
	s := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(s); err != nil {
		t.Fatal(err)
	}
	if err := sourcev1.AddToScheme(s); err != nil {
		t.Fatal(err)
	}
	return s
}

func artifactFor(url, revision, dgst string) *meta.Artifact {
	return &meta.Artifact{
		URL:            url,
		Revision:       revision,
		Digest:         dgst,
		LastUpdateTime: metav1.Now(),
	}
}

// waitCurrent polls until current serves the given content of the given file.
func waitCurrent(t *testing.T, root, rel, want string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if b, err := os.ReadFile(filepath.Join(root, "current", rel)); err == nil && string(b) == want {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	b, _ := os.ReadFile(filepath.Join(root, "current", rel))
	t.Fatalf("current/%s = %q, want %q", rel, string(b), want)
}

// TestWatchStartupGetAndEventChange is the no-cluster proof of watch mode: the
// startup read acts on the artifact that is already there (the restart case),
// and a status.artifact change on the watched object swaps to the new tree.
func TestWatchStartupGetAndEventChange(t *testing.T) {
	v1 := makeTarball(t, map[string]string{"tickets.md": "v1\n"})
	v2 := makeTarball(t, map[string]string{"tickets.md": "v2\n"})
	url1, count1 := serveTarball(t, v1)
	url2, count2 := serveTarball(t, v2)

	ea := &sourcev1.ExternalArtifact{
		ObjectMeta: metav1.ObjectMeta{Name: "chudmax-tickets", Namespace: "chudmax", Generation: 1},
	}
	ea.Status.Artifact = artifactFor(url1, "main@sha1:aaa", shaOf(v1))
	c := fake.NewClientBuilder().
		WithScheme(testScheme(t)).
		WithStatusSubresource(&sourcev1.ExternalArtifact{}).
		WithObjects(ea).
		Build()

	root := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	done := make(chan error, 1)
	go func() {
		o := testOpts()
		o.Source = "externalartifact chudmax/chudmax-tickets"
		done <- runWatch(ctx, c, nil, "chudmax", "chudmax-tickets", root, o, time.Minute,
			client.InNamespace("chudmax"))
	}()

	// Startup read: the artifact that was already there gets fetched.
	waitCurrent(t, root, "tickets.md", "v1\n")
	if n := count1(); n != 1 {
		t.Fatalf("startup fetch downloaded %d times", n)
	}
	m := readMeta(t, filepath.Join(root, "current", "artifact.json"))
	if m.Revision != "main@sha1:aaa" || m.Source != "externalartifact chudmax/chudmax-tickets" {
		t.Fatalf("artifact.json = %+v", m)
	}

	// The producer records a new artifact (status subresource, as in the real
	// API); the watcher must swap to it.
	ea.Status.Artifact = artifactFor(url2, "main@sha1:bbb", shaOf(v2))
	if err := c.Status().Update(context.Background(), ea); err != nil {
		t.Fatal(err)
	}
	waitCurrent(t, root, "tickets.md", "v2\n")
	if n := count2(); n != 1 {
		t.Fatalf("event fetch downloaded %d times", n)
	}
	if currentPointsAt(t, root) != shaOf(v2)[len("sha256:"):] {
		t.Fatal("current does not point at v2")
	}

	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("runWatch returned: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("runWatch did not stop on context cancel")
	}
}

// closedStreamClient wraps a client whose watch stream ends immediately, as a
// dropped connection does: nothing is ever delivered on it.
type closedStreamClient struct{ client.WithWatch }

func (c closedStreamClient) Watch(ctx context.Context, obj client.ObjectList, opts ...client.ListOption) (watch.Interface, error) {
	w := watch.NewFake()
	w.Stop()
	return w, nil
}

// silentStreamClient wraps a client whose watch stream stays open but never
// delivers: the case the periodic resync read exists for.
type silentStreamClient struct{ client.WithWatch }

func (c silentStreamClient) Watch(ctx context.Context, obj client.ObjectList, opts ...client.ListOption) (watch.Interface, error) {
	return watch.NewFake(), nil
}

// TestWatchResyncCatchesMissedEvent proves the resync read (here at 50ms): the
// stream is alive but silent, so only the periodic re-read brings the new
// artifact in.
func TestWatchResyncCatchesMissedEvent(t *testing.T) {
	v1 := makeTarball(t, map[string]string{"tickets.md": "v1\n"})
	v2 := makeTarball(t, map[string]string{"tickets.md": "v2\n"})
	url1, _ := serveTarball(t, v1)
	url2, _ := serveTarball(t, v2)

	ea := &sourcev1.ExternalArtifact{
		ObjectMeta: metav1.ObjectMeta{Name: "chudmax-tickets", Namespace: "chudmax", Generation: 1},
	}
	ea.Status.Artifact = artifactFor(url1, "main@sha1:aaa", shaOf(v1))
	c := fake.NewClientBuilder().
		WithScheme(testScheme(t)).
		WithStatusSubresource(&sourcev1.ExternalArtifact{}).
		WithObjects(ea).
		Build()

	root := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go func() {
		o := testOpts()
		o.Source = "externalartifact chudmax/chudmax-tickets"
		runWatch(ctx, silentStreamClient{c}, nil, "chudmax", "chudmax-tickets", root, o,
			50*time.Millisecond, client.InNamespace("chudmax"))
	}()

	waitCurrent(t, root, "tickets.md", "v1\n")
	ea.Status.Artifact = artifactFor(url2, "main@sha1:bbb", shaOf(v2))
	if err := c.Status().Update(context.Background(), ea); err != nil {
		t.Fatal(err)
	}
	waitCurrent(t, root, "tickets.md", "v2\n")
}

// TestWatchReconnectCatchesMissedEvent proves the reconnect read: the stream
// ends at once (a drop), so the periodic re-read after the backoff brings the
// new artifact in.
func TestWatchReconnectCatchesMissedEvent(t *testing.T) {
	v1 := makeTarball(t, map[string]string{"tickets.md": "v1\n"})
	v2 := makeTarball(t, map[string]string{"tickets.md": "v2\n"})
	url1, _ := serveTarball(t, v1)
	url2, _ := serveTarball(t, v2)

	ea := &sourcev1.ExternalArtifact{
		ObjectMeta: metav1.ObjectMeta{Name: "chudmax-tickets", Namespace: "chudmax", Generation: 1},
	}
	ea.Status.Artifact = artifactFor(url1, "main@sha1:aaa", shaOf(v1))
	c := fake.NewClientBuilder().
		WithScheme(testScheme(t)).
		WithStatusSubresource(&sourcev1.ExternalArtifact{}).
		WithObjects(ea).
		Build()

	root := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go func() {
		o := testOpts()
		o.Source = "externalartifact chudmax/chudmax-tickets"
		runWatch(ctx, closedStreamClient{c}, nil, "chudmax", "chudmax-tickets", root, o,
			50*time.Millisecond, client.InNamespace("chudmax"))
	}()

	waitCurrent(t, root, "tickets.md", "v1\n")
	ea.Status.Artifact = artifactFor(url2, "main@sha1:bbb", shaOf(v2))
	if err := c.Status().Update(context.Background(), ea); err != nil {
		t.Fatal(err)
	}
	waitCurrent(t, root, "tickets.md", "v2\n")
}

// TestWatchFetchFailureKeepsPreviousTree: a new artifact whose bytes do not
// match its digest must not disturb the tree being served.
func TestWatchFetchFailureKeepsPreviousTree(t *testing.T) {
	v1 := makeTarball(t, map[string]string{"tickets.md": "v1\n"})
	url1, _ := serveTarball(t, v1)
	badURL := "http://127.0.0.1:1/artifact/never.tar.gz" // nothing listens there

	ea := &sourcev1.ExternalArtifact{
		ObjectMeta: metav1.ObjectMeta{Name: "chudmax-tickets", Namespace: "chudmax", Generation: 1},
	}
	ea.Status.Artifact = artifactFor(url1, "main@sha1:aaa", shaOf(v1))
	c := fake.NewClientBuilder().
		WithScheme(testScheme(t)).
		WithStatusSubresource(&sourcev1.ExternalArtifact{}).
		WithObjects(ea).
		Build()

	root := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go func() {
		o := testOpts()
		o.Source = "externalartifact chudmax/chudmax-tickets"
		runWatch(ctx, c, nil, "chudmax", "chudmax-tickets", root, o, time.Hour,
			client.InNamespace("chudmax"))
	}()
	waitCurrent(t, root, "tickets.md", "v1\n")

	ea.Status.Artifact = artifactFor(badURL, "main@sha1:bbb", "sha256:"+fmt.Sprintf("%x", sha256.Sum256([]byte("nope"))))
	if err := c.Status().Update(context.Background(), ea); err != nil {
		t.Fatal(err)
	}
	// Give the watcher a moment to fail fetching, then check it kept serving.
	time.Sleep(300 * time.Millisecond)
	if got := readCurrent(t, root, "tickets.md"); got != "v1\n" {
		t.Fatalf("previous tree disturbed: %q", got)
	}
}

// TestWatchStartupNotFoundWaits is the phase-4b "kinder startup": a fresh
// install has no ExternalArtifact yet; the fetcher must wait with backoff and
// stay up (the old behavior was a fatal startup read), and self-heal when the
// artifact appears.
func TestWatchStartupNotFoundWaits(t *testing.T) {
	v1 := makeTarball(t, map[string]string{"tickets.md": "v1\n"})
	url1, count1 := serveTarball(t, v1)

	// No object exists at all.
	c := fake.NewClientBuilder().
		WithScheme(testScheme(t)).
		WithStatusSubresource(&sourcev1.ExternalArtifact{}).
		Build()

	root := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	done := make(chan error, 1)
	go func() {
		o := testOpts()
		o.Source = "externalartifact chudmax/chudmax-tickets"
		done <- runWatch(ctx, c, nil, "chudmax", "chudmax-tickets", root, o, 50*time.Millisecond,
			client.InNamespace("chudmax"))
	}()

	// Still waiting well past the first retry; nothing was fetched, nothing exited.
	select {
	case err := <-done:
		t.Fatalf("runWatch exited before the artifact existed: %v", err)
	case <-time.After(300 * time.Millisecond):
	}
	if n := count1(); n != 0 {
		t.Fatalf("fetched %d times with no artifact around", n)
	}

	// The repo-sync work creates the artifact (spec first, then the status
	// subresource, as the real API behaves); the next re-read must pick it up.
	ea := &sourcev1.ExternalArtifact{
		ObjectMeta: metav1.ObjectMeta{Name: "chudmax-tickets", Namespace: "chudmax"},
	}
	if err := c.Create(context.Background(), ea); err != nil {
		t.Fatal(err)
	}
	ea.Status.Artifact = artifactFor(url1, "main@sha1:aaa", shaOf(v1))
	if err := c.Status().Update(context.Background(), ea); err != nil {
		t.Fatal(err)
	}
	waitCurrent(t, root, "tickets.md", "v1\n")

	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("runWatch returned: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("runWatch did not stop on context cancel")
	}
}

// TestWatchRecordsOriginRevision proves the phase-4b artifact.json addition:
// the git-side revision the generator recorded beside the artifact lands in
// origin_revision, read from the object the watcher already holds.
func TestWatchRecordsOriginRevision(t *testing.T) {
	v1 := makeTarball(t, map[string]string{"tickets.md": "v1\n"})
	url1, _ := serveTarball(t, v1)

	ea := &sourcev1.ExternalArtifact{
		ObjectMeta: metav1.ObjectMeta{Name: "chudmax-tickets", Namespace: "chudmax"},
	}
	ea.Status.Artifact = artifactFor(url1, "latest@sha256:aaa", shaOf(v1))
	ea.Status.Artifact.Metadata = map[string]string{originRevisionAnnotation: "main@sha1:abc123"}
	c := fake.NewClientBuilder().
		WithScheme(testScheme(t)).
		WithStatusSubresource(&sourcev1.ExternalArtifact{}).
		WithObjects(ea).
		Build()

	root := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	done := make(chan error, 1)
	go func() {
		o := testOpts()
		o.Source = "externalartifact chudmax/chudmax-tickets"
		done <- runWatch(ctx, c, nil, "chudmax", "chudmax-tickets", root, o, time.Minute,
			client.InNamespace("chudmax"))
	}()

	waitCurrent(t, root, "tickets.md", "v1\n")
	m := readMeta(t, filepath.Join(root, "current", "artifact.json"))
	if m.OriginRevision != "main@sha1:abc123" {
		t.Fatalf("origin_revision = %q, want main@sha1:abc123", m.OriginRevision)
	}
	cancel()
	<-done
}
