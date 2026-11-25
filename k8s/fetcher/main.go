// fetcher is chudmax's artifact sidecar (T-0037 phase 2): the only new code in
// the k8s plan, and it is not git code. Flux (source-controller) fetches and
// packs the repo; fetcher consumes what Flux serves. It takes an artifact URL
// and digest, verifies, unpacks beside the previous copy, and swaps a symlink
// so a reader never sees half a tree.
//
// Two modes:
//
//	fetch  --url URL --digest sha256:... --root DIR
//	       one-shot: download, verify, unpack, swap. What CI proves.
//	watch  --namespace NS --name NAME --root DIR
//	       pod mode: read the one ExternalArtifact this sidecar is allowed to
//	       read (namespaced Role: get, watch) at startup — which covers a
//	       missed event after a restart — then watch it and repeat the core
//	       on every artifact change, re-checking every --resync.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"time"

	"sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	defaultRetries       = 3
	defaultKeep          = 3
	defaultMaxDownloadSz = 100 << 20 // 100 MiB tarball
	defaultMaxUntarSz    = 200 << 20 // 200 MiB unpacked
	defaultResync        = time.Minute
)

func main() {
	log.SetPrefix("fetcher: ")
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	switch os.Args[1] {
	case "fetch":
		fs := flag.NewFlagSet("fetch", flag.ExitOnError)
		url := fs.String("url", "", "artifact URL (required)")
		dgst := fs.String("digest", "", "artifact digest, sha256:<hex> (required)")
		root := fs.String("root", "", "volume root for revisions/ and current (required)")
		o := coreFlags(fs)
		fs.Parse(os.Args[2:])
		must(*url != "", "--url is required")
		must(*dgst != "", "--digest is required")
		must(*root != "", "--root is required")
		o.Source = "flag"
		swapped, err := FetchAndSwap(ctx, *url, *dgst, *root, o)
		exitOn(err)
		log.Printf("fetch: digest=%s swapped=%v", shortDigest(*dgst), swapped)

	case "watch":
		fs := flag.NewFlagSet("watch", flag.ExitOnError)
		ns := fs.String("namespace", "", "namespace of the one ExternalArtifact (required)")
		name := fs.String("name", "", "name of the one ExternalArtifact (required)")
		root := fs.String("root", "", "volume root for revisions/ and current (required)")
		resync := fs.Duration("resync", defaultResync, "re-read the ExternalArtifact this often as a fallback")
		o := coreFlags(fs)
		fs.Parse(os.Args[2:])
		must(*ns != "", "--namespace is required")
		must(*name != "", "--name is required")
		must(*root != "", "--root is required")
		c, scheme, err := newClient()
		exitOn(err)
		log.Printf("watch: externalartifact %s/%s root=%s resync=%s", *ns, *name, *root, *resync)
		opts := []client.ListOption{client.InNamespace(*ns), client.MatchingFields{"metadata.name": *name}}
		exitOn(runWatch(ctx, c, scheme, *ns, *name, *root, o, *resync, opts...))

	default:
		usage()
		os.Exit(2)
	}
}

func coreFlags(fs *flag.FlagSet) CoreOpts {
	return CoreOpts{
		Retries:       *fs.Int("retries", defaultRetries, "download retries"),
		Keep:          *fs.Int("keep", defaultKeep, "revision dirs to keep"),
		MaxDownloadSz: *fs.Int("max-download-bytes", defaultMaxDownloadSz, "tarball size cap"),
		MaxUntarSz:    *fs.Int("max-untar-bytes", defaultMaxUntarSz, "unpacked size cap"),
	}
}

func usage() {
	fmt.Fprint(os.Stderr, "usage: fetcher fetch --url URL --digest sha256:... --root DIR\n"+
		"       fetcher watch --namespace NS --name NAME --root DIR\n")
}

func must(ok bool, msg string) {
	if !ok {
		fmt.Fprintln(os.Stderr, "fetcher:", msg)
		os.Exit(2)
	}
}

func exitOn(err error) {
	if err != nil {
		log.Fatal(err)
	}
}

func shortDigest(dgst string) string {
	if len(dgst) > 19 {
		return dgst[:19] + "…"
	}
	return dgst
}
