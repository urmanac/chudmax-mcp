// Command gittestserver serves a directory of bare git repositories over
// Smart HTTP for the phase-8 rehearsal: the runner hosts the test repo, the
// cluster's source-controller fetches it and the image-automation-controller
// commits and pushes to it over http://<gateway>:<port>/repo.git — the URL
// shape the GitRepository CRD accepts (its ^(http|https|ssh):// pattern
// rejects git:// at the API server, T-0037 phase 5).
//
// This is phase-8's own module: a duplicate of phase-5's helper
// (k8s/rehearsal/gittestserver — merged main, not to be extended by an active
// branch) plus exactly two additions the one-branch credential story needs:
//
//   - -auth "user:pass": REQUIRE HTTP basic auth on every request (401 +
//     WWW-Authenticate challenge otherwise). Empty keeps the phase-5
//     no-auth behavior. The credentials never appear in logs.
//   - the authenticated identity flows to the git-http-backend environment
//     (GIT_TESTSERVER_IDENTITY + REMOTE_USER) so receive-pack's hooks can
//     see who is pushing.
//
// Each request is handled by git's own http-backend CGI, exec'd per request
// with GIT_PROJECT_ROOT / GIT_HTTP_EXPORT_ALL and bound on 0.0.0.0 so the
// cluster's pods can reach the runner through the docker/podman network
// gateway. Zero module dependencies, like the phase-5 helper.
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
	auth := flag.String("auth", "", "require HTTP basic auth 'user:pass' (empty = no auth)")
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

	var user, pass string
	if *auth != "" {
		i := strings.Index(*auth, ":")
		if i < 0 {
			log.Fatal("-auth wants the shape user:pass")
		}
		user, pass = (*auth)[:i], (*auth)[i+1:]
	}
	log.Printf("serving %s on %s via %s (auth %s)", *root, *addr, *backend,
		map[bool]string{true: "required", false: "off"}[*auth != ""])
	log.Fatal(http.ListenAndServe(*addr, &gitCGI{root: *root, backend: *backend, user: user, pass: pass}))
}

type gitCGI struct {
	root    string
	backend string
	user    string
	pass    string
}

func (g *gitCGI) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	identity := ""
	if g.user != "" {
		u, p, ok := r.BasicAuth()
		if !ok || u != g.user || p != g.pass {
			// The user name is safe to log; the password never is.
			if u != "" {
				log.Printf("rejected credentials for user %q on %s", u, r.URL.Path)
			}
			w.Header().Set("WWW-Authenticate", `Basic realm="chudmax-rehearsal"`)
			http.Error(w, "credentials required or rejected", http.StatusUnauthorized)
			return
		}
		identity = u
		log.Printf("request %s %s (identity %s)", r.Method, r.URL.Path, identity)
	}

	cmd := exec.Command(g.backend)
	cmd.Env = append(os.Environ(),
		"GIT_PROJECT_ROOT="+g.root,
		"GIT_HTTP_EXPORT_ALL=1",
		"PATH_INFO="+r.URL.Path,
		"QUERY_STRING="+r.URL.RawQuery,
		"REQUEST_METHOD="+r.Method,
		"CONTENT_TYPE="+r.Header.Get("Content-Type"),
	)
	if identity != "" {
		// The hook-visible identity (both spellings, so whichever survives
		// the http-backend -> receive-pack -> hook env chain is present).
		cmd.Env = append(cmd.Env,
			"GIT_TESTSERVER_IDENTITY="+identity,
			"REMOTE_USER="+identity,
		)
	}
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
