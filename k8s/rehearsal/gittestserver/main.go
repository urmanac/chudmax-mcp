// Command gittestserver serves a directory of bare git repositories over
// Smart HTTP for the phase-5 rehearsal: the runner hosts the test repo, the
// cluster's source-controller fetches it over http://<gateway>:<port>/repo.git
// — the URL shape the GitRepository CRD accepts (its ^(http|https|ssh)://
// pattern rejects git:// at the API server, T-0037 phase 5).
//
// Each request is handled by git's own http-backend CGI, exec'd per request
// with GIT_PROJECT_ROOT / GIT_HTTP_EXPORT_ALL and bound on 0.0.0.0 so the
// cluster's pods can reach the runner through the docker/podman network
// gateway. Zero secrets, zero remote pushes: the script drives the bare repo
// over file:// and the cluster fetches over plain HTTP.
//
// Flux's own pkg/gittestserver was considered first (the review's preference)
// and is NOT usable here: its StartHTTP binds httptest's server on 127.0.0.1
// with an ephemeral port (server.go), which the cluster's pods cannot reach —
// this helper is the review's sanctioned alternative (a tiny server driving
// git-http-backend via subprocess), in Go with no module dependencies at all.
package main

import (
	"bufio"
	"flag"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

func main() {
	root := flag.String("root", "/srv/git", "directory of bare git repositories to serve")
	addr := flag.String("addr", "0.0.0.0:38080", "listen address (0.0.0.0 so the cluster reaches it)")
	backend := flag.String("backend", "", "path to git-http-backend (default: probed)")
	flag.Parse()

	if *backend == "" {
		for _, p := range []string{
			"/usr/lib/git-core/git-http-backend",     // Debian/Ubuntu
			"/usr/libexec/git-core/git-http-backend", // Fedora/RHEL/alpine
		} {
			if st, err := os.Stat(p); err == nil && !st.IsDir() {
				*backend = p
				break
			}
		}
	}
	if st, err := os.Stat(*backend); err != nil || st.IsDir() {
		log.Fatalf("git-http-backend not found at %q; pass -backend", *backend)
	}
	log.Printf("serving %s on %s via %s", *root, *addr, *backend)
	log.Fatal(http.ListenAndServe(*addr, &gitCGI{root: *root, backend: *backend}))
}

type gitCGI struct {
	root    string
	backend string
}

func (g *gitCGI) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	cmd := exec.Command(g.backend)
	cmd.Env = append(os.Environ(),
		"GIT_PROJECT_ROOT="+g.root,
		"GIT_HTTP_EXPORT_ALL=1",
		"PATH_INFO="+r.URL.Path,
		"QUERY_STRING="+r.URL.RawQuery,
		"REQUEST_METHOD="+r.Method,
		"CONTENT_TYPE="+r.Header.Get("Content-Type"),
	)
	if r.ContentLength > 0 {
		cmd.Env = append(cmd.Env, "CONTENT_LENGTH="+strconv.FormatInt(r.ContentLength, 10))
	}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		http.Error(w, "backend pipe failed", http.StatusInternalServerError)
		return
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		http.Error(w, "backend pipe failed", http.StatusInternalServerError)
		return
	}
	stderr, _ := cmd.StderrPipe()
	if err := cmd.Start(); err != nil {
		http.Error(w, "backend start failed", http.StatusInternalServerError)
		return
	}
	go func() {
		_, _ = io.Copy(stdin, r.Body)
		_ = stdin.Close()
	}()
	go func() {
		b, _ := io.ReadAll(stderr)
		if len(b) > 0 {
			log.Printf("backend stderr (%s %s): %s", r.Method, r.URL.Path, b)
		}
	}()

	// The CGI contract: headers, a blank line, then the body. Stream the body
	// through so large packs are not buffered whole.
	br := bufio.NewReaderSize(stdout, 32*1024)
	status := http.StatusOK
	for {
		line, err := br.ReadString('\n')
		if err != nil {
			break
		}
		line = strings.TrimRight(line, "\r\n")
		if line == "" {
			break
		}
		i := strings.Index(line, ":")
		if i < 0 {
			continue
		}
		key, val := strings.TrimSpace(line[:i]), strings.TrimSpace(line[i+1:])
		if strings.EqualFold(key, "Status") {
			if n, err := strconv.Atoi(strings.Fields(val)[0]); err == nil {
				status = n
			}
			continue
		}
		w.Header().Set(key, val)
	}
	w.WriteHeader(status)
	_, _ = io.Copy(w, br)
	_ = cmd.Wait()
}
