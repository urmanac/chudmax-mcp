package main

import (
	"flag"
	"testing"
)

// TestCoreFlagsParse is the regression test for the bug Fable's review found
// (T-0037 phase 4b): coreFlags used to dereference the flag value pointers
// before fs.Parse ran, so --retries/--keep/--max-download-bytes/
// --max-untar-bytes were all silent no-ops. Parsing must happen first.
func TestCoreFlagsParse(t *testing.T) {
	fs := flag.NewFlagSet("fetch", flag.ContinueOnError)
	o := coreFlags(fs, []string{
		"--retries", "5", "--keep", "2",
		"--max-download-bytes", "1234", "--max-untar-bytes", "5678",
	})
	if o.Retries != 5 || o.Keep != 2 || o.MaxDownloadSz != 1234 || o.MaxUntarSz != 5678 {
		t.Fatalf("parsed flags did not reach CoreOpts: %+v", o)
	}
}

func TestCoreFlagsDefaults(t *testing.T) {
	fs := flag.NewFlagSet("fetch", flag.ContinueOnError)
	o := coreFlags(fs, nil)
	if o.Retries != defaultRetries || o.Keep != defaultKeep ||
		o.MaxDownloadSz != defaultMaxDownloadSz || o.MaxUntarSz != defaultMaxUntarSz {
		t.Fatalf("defaults did not survive the parse: %+v", o)
	}
}
