package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"time"

	"github.com/fluxcd/pkg/http/fetch"
	flxtar "github.com/fluxcd/pkg/tar"
	"github.com/opencontainers/go-digest"
)

// CoreOpts are the tunables shared by the fetch and watch modes. The defaults
// the spec review adopted: 3 retries, retention 3, caps 100 MiB downloaded /
// 200 MiB unpacked, all flag-overridable.
type CoreOpts struct {
	Retries       int    // download retries inside ArchiveFetcher
	Keep          int    // revision dirs to keep after a swap (current included)
	MaxDownloadSz int    // tarball size cap
	MaxUntarSz    int    // unpacked size cap
	Revision      string // the artifact revision, when the caller knows it (watch mode)
	Produced      string // when the producer made the artifact (watch mode), RFC3339
	Source        string // what handed us the artifact, recorded in artifact.json
	Now           func() time.Time
}

// ArtifactMeta is what artifact.json records beside every unpacked tree. The
// ticket server's repo_facts reads it through the current symlink on every
// call (phase 3 wiring), so the facts swap atomically with the content.
type ArtifactMeta struct {
	URL      string `json:"url"`
	Revision string `json:"revision,omitempty"`
	Digest   string `json:"digest"`
	Produced string `json:"produced,omitempty"`
	Unpacked string `json:"unpacked"`
	Source   string `json:"source,omitempty"`
}

// FetchAndSwap is the whole sidecar in one call: download the tarball at url,
// verify it against digest, unpack it into <root>/revisions/<hex>/ beside the
// previous copies, write artifact.json into the new dir, then swap the
// <root>/current symlink onto it with a rename (atomic: a reader opening
// through current sees the whole old tree or the whole new tree, never half).
//
// It is idempotent: if current already points at digest, or the digest's dir
// is already unpacked and complete, nothing is downloaded and current is left
// alone (the restart case; also the rollback case, which keeps the first
// unpack's artifact.json).
//
// On any failure (bad digest, network) it returns an error and leaves the
// previous tree serving untouched.
func FetchAndSwap(ctx context.Context, url, dgst, root string, o CoreOpts) (bool, error) {
	if o.Now == nil {
		o.Now = time.Now
	}
	if o.Keep < 1 {
		o.Keep = 1
	}
	if dgst == "" {
		return false, fmt.Errorf("refusing to fetch without a digest")
	}
	d, err := digest.Parse(dgst)
	if err != nil {
		return false, fmt.Errorf("bad digest %q: %w", dgst, err)
	}
	if d.Algorithm() != digest.SHA256 {
		return false, fmt.Errorf("unsupported digest algorithm %q: only sha256 is handled", d.Algorithm())
	}
	hex := d.Encoded()
	if url == "" {
		return false, fmt.Errorf("refusing to fetch without a url")
	}

	revisions := filepath.Join(root, "revisions")
	if err := os.MkdirAll(revisions, 0o755); err != nil {
		return false, err
	}
	current := filepath.Join(root, "current")

	// No-op when current already serves this digest (idempotent, and what a
	// restart or a resync sees).
	if tgt, err := os.Readlink(current); err == nil {
		if filepath.Base(tgt) != hex {
			// A symlink that is not ours would be clobbered below; the volume
			// layout is the sidecar's contract, so refuse loudly instead.
			if !isRevisionLink(tgt) {
				return false, fmt.Errorf("%s exists but does not point into revisions/: refusing to manage it", current)
			}
		} else {
			retain(revisions, hex, o.Keep)
			return false, nil
		}
	} else if !os.IsNotExist(err) {
		return false, fmt.Errorf("%s exists but is not a symlink: refusing to manage it", current)
	}

	// Unpack unless the digest's dir is already there and complete (rollback
	// and retry reuse the first unpack, artifact.json included).
	target := filepath.Join(revisions, hex)
	if !dirComplete(target) {
		tmp := filepath.Join(revisions, ".tmp-"+hex)
		if err := os.RemoveAll(tmp); err != nil {
			return false, err
		}
		if err := unpack(ctx, url, dgst, tmp, o); err != nil {
			os.RemoveAll(tmp)
			return false, err
		}
		if err := os.RemoveAll(target); err != nil {
			return false, err
		}
		if err := os.Rename(tmp, target); err != nil {
			return false, err
		}
	}

	// Atomic swap: build the symlink under a temp name, then rename it over
	// current. rename(2) is atomic on one filesystem; a reader either sees
	// the old link or the new one.
	tmpLink := filepath.Join(root, ".current.tmp")
	if err := os.Remove(tmpLink); err != nil && !os.IsNotExist(err) {
		return false, err
	}
	if err := os.Symlink(filepath.Join("revisions", hex), tmpLink); err != nil {
		return false, err
	}
	if err := os.Rename(tmpLink, current); err != nil {
		return false, err
	}

	retain(revisions, hex, o.Keep)
	return true, nil
}

func unpack(ctx context.Context, url, dgst, dir string, o CoreOpts) error {
	f := fetch.New(
		fetch.WithRetries(o.Retries),
		fetch.WithMaxDownloadSize(o.MaxDownloadSz),
		fetch.WithUntar(flxtar.WithMaxUntarSize(o.MaxUntarSz)),
	)
	if err := f.FetchWithContext(ctx, url, dgst, dir); err != nil {
		return err
	}
	meta := ArtifactMeta{
		URL:      url,
		Revision: o.Revision,
		Digest:   dgst,
		Produced: o.Produced,
		Unpacked: o.Now().UTC().Format(time.RFC3339),
		Source:   o.Source,
	}
	b, err := json.MarshalIndent(meta, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, "artifact.json"), append(b, '\n'), 0o644)
}

// dirComplete says whether dir is a fully unpacked revision: it exists and
// carries the artifact.json the sidecar writes last.
func dirComplete(dir string) bool {
	st, err := os.Stat(filepath.Join(dir, "artifact.json"))
	return err == nil && !st.IsDir()
}

// isRevisionLink says whether a symlink target is the sidecar's own layout.
func isRevisionLink(tgt string) bool {
	return filepath.Dir(filepath.Clean(tgt)) == "revisions"
}

// retain keeps the newest Keep revision dirs, always including the one current
// points at, and removes the rest plus any leftover .tmp-* dirs from an
// interrupted run.
func retain(revisions, hex string, keep int) {
	entries, err := os.ReadDir(revisions)
	if err != nil {
		return
	}
	type rev struct {
		name string
		mod  time.Time
	}
	var dirs []rev
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		if filepath.Base(e.Name()) == hex { // the one being served now
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		dirs = append(dirs, rev{e.Name(), info.ModTime()})
	}
	sort.Slice(dirs, func(i, j int) bool { return dirs[i].mod.After(dirs[j].mod) })
	for i, d := range dirs {
		if i < keep-1 {
			continue
		}
		os.RemoveAll(filepath.Join(revisions, d.name))
	}
	// .tmp-* leftovers only ever come from an interrupted unpack of this
	// process's own predecessors; nothing concurrent writes here.
	for _, e := range entries {
		if e.IsDir() && len(e.Name()) > 5 && e.Name()[:5] == ".tmp-" {
			os.RemoveAll(filepath.Join(revisions, e.Name()))
		}
	}
}
