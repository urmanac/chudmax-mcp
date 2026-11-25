#!/usr/bin/env python3
"""Self-test for tools/mcp/ticket_mcp.py.

This is the "test" required before a merge to main (decisions/0006). It is a dry run in the
GitOps sense: it spawns the server as a real subprocess, sends real JSON-RPC over stdin, and
asserts on what comes back. Run it before merging anything that touches the MCP server.

Since T-0038 (T-0037 phase 1) it covers both transports: the stdio checks below, then the same
server started with --http and --revision, driven over a loopback HTTP POST per request.

Usage: python3 tools/mcp/selftest.py
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
SERVER = ROOT / "tools" / "mcp" / "ticket_mcp.py"

# Each call has its own key. Results are looked up by key, never by tool name, because the
# same tool is called several times and a by-name lookup silently keeps only the last answer.
CALLS = [
    {"key": "list_tickets", "name": "list_tickets", "args": {}},
    {"key": "get_ticket", "name": "get_ticket", "args": {"id": "T-0019"}},
    {"key": "search_tickets", "name": "search_tickets", "args": {"query": "measure"}},
    {"key": "repo_facts", "name": "repo_facts", "args": {}},
    {"key": "list_docs", "name": "list_docs", "args": {}},
    {"key": "read_agents", "name": "read_doc", "args": {"name": "AGENTS.md"}},
    {"key": "read_readme_200", "name": "read_doc", "args": {"name": "README.md", "max_chars": 200}},
    {"key": "read_source", "name": "read_doc", "args": {"name": "tools/mcp/ticket_mcp.py"}},
    {"key": "search_docs", "name": "search_docs", "args": {"query": "verified-here"}},
    # T-0018 and tickets.md are both far longer than any default cap, so they must come back trimmed.
    {"key": "ticket_default", "name": "get_ticket", "args": {"id": "T-0018"}},
    {"key": "ticket_300", "name": "get_ticket", "args": {"id": "T-0018", "max_chars": 300}},
    {"key": "ticket_all", "name": "get_ticket", "args": {"id": "T-0018", "max_chars": 1000000}},
    {"key": "doc_default", "name": "read_doc", "args": {"name": "tickets.md"}},
]
LIST_ID = len(CALLS) + 1
# The server's trim note: at the end for read_doc, in the middle for get_ticket.
TRIM_NOTE = re.compile(r"\n\[\.\.\. [^\]]*\]\n?")


def payload():
    out = []
    for i, c in enumerate(CALLS, 1):
        out.append(json.dumps({"jsonrpc": "2.0", "id": i, "method": "tools/call",
                               "params": {"name": c["name"], "arguments": c["args"]}}))
    out.append(json.dumps({"jsonrpc": "2.0", "id": LIST_ID, "method": "tools/list"}))
    return "\n".join(out) + "\n"


def advertised_default(schema, tool):
    """The number a tool's schema tells the model is the max_chars default, or None."""
    for t in schema:
        if t.get("name") == tool:
            desc = t["inputSchema"]["properties"].get("max_chars", {}).get("description", "")
            m = re.search(r"default (\d+)", desc)
            return int(m.group(1)) if m else None
    return None


def kept(text):
    """Characters of real content around the server's trim note, or None if it was not trimmed."""
    m = TRIM_NOTE.search(text)
    return len(text) - len(m.group(0)) if m else None


def ticket_block(tid):
    """The ticket's text as it is on disk, for checking which lines the server kept."""
    text = (ROOT / "tickets.md").read_text()
    start = text.index(f"## {tid} - ")
    nxt = text.find("\n## ", start + 1)
    return text[start:nxt if nxt != -1 else len(text)]


FAKE_REVISION = "main@sha1:" + "0" * 40


def http_checks(checks: list) -> None:
    """T-0038: the server in pod mode over HTTP — what a fetcher sidecar's world looks like."""
    import socket
    import urllib.error
    import urllib.request
    proc = subprocess.Popen(
        [sys.executable, str(SERVER), "--tickets", str(ROOT / "tickets.md"),
         "--http", "0", "--revision", FAKE_REVISION,
         "--artifact-produced", "2026-11-25T15:00:00Z", "--artifact-unpacked", "2026-11-25T15:00:01Z"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    try:
        line = proc.stdout.readline().strip()
        m = re.match(r"listening on (\S+):(\d+)$", line)
        checks.append(("http server announces its port", m is not None, line[:60]))
        if m is None:
            return
        url = f"http://{m.group(1)}:{m.group(2)}/mcp"

        def post(body: str):
            req = urllib.request.Request(url, data=body.encode(),
                                         headers={"Content-Type": "application/json"},
                                         method="POST")
            try:
                with urllib.request.urlopen(req, timeout=10) as r:
                    return r.status, r.read()
            except urllib.error.HTTPError as e:
                return e.code, e.read()

        status, body = post(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                        "params": {}}))
        name = json.loads(body).get("result", {}).get("serverInfo", {}).get("name") if status == 200 else None
        checks.append(("http initialize answers as chudmax-tickets",
                       status == 200 and name == "chudmax-tickets", f"HTTP {status}"))

        status, body = post(json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}))
        n = len(json.loads(body).get("result", {}).get("tools", [])) if status == 200 else 0
        checks.append(("http tools/list advertises seven tools", status == 200 and n == 7,
                       f"HTTP {status}, {n} tools"))

        status, body = post(json.dumps({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                        "params": {"name": "repo_facts", "arguments": {}}}))
        facts = "\n".join(c.get("text", "") for c in json.loads(body).get("result", {}).get("content", []))
        checks.append(("http repo_facts reports the revision it was given, not git's",
                       "revision: " + FAKE_REVISION in facts and "no git was asked" in facts
                       and "artifact unpacked: 2026-11-25T15:00:01Z" in facts,
                       facts.splitlines()[0] if facts else "empty"))

        status, body = post(json.dumps({"jsonrpc": "2.0", "id": 4, "method": "tools/call",
                                        "params": {"name": "list_tickets", "arguments": {}}}))
        first = (json.loads(body).get("result", {}).get("content", [{}])[0]
                 .get("text", "").splitlines() or [""])[0]
        checks.append(("http list_tickets answers from tickets.md",
                       status == 200 and first.startswith("T-"), f"HTTP {status}, {first[:40]}"))

        status, _ = post("{not json")
        checks.append(("http refuses a malformed body with 400", status == 400, f"HTTP {status}"))

        req = urllib.request.Request(url, method="POST",
                                     data=json.dumps({"jsonrpc": "2.0",
                                                      "method": "notifications/initialized"}).encode(),
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=10) as r:
            note_ok = r.status == 202 and r.read() == b""
        checks.append(("http takes a notification with 202 and an empty body", note_ok, "HTTP 202"))

        try:
            with urllib.request.urlopen(urllib.request.Request(url, method="GET"), timeout=10) as r:
                gstatus = r.status
        except urllib.error.HTTPError as e:
            gstatus = e.code
        checks.append(("http refuses GET with 405", gstatus == 405, f"HTTP {gstatus}"))

        # The 202's framing, as a keep-alive client sees it: urllib sends
        # Connection: close and cannot tell framing from luck. http.client speaks
        # HTTP/1.1 keep-alive - it hangs on an unframed empty body (the exact bug
        # a curl-shaped client hit), so this probe is the regression test.
        import http.client
        conn = http.client.HTTPConnection(m.group(1), int(m.group(2)), timeout=10)
        try:
            conn.request("POST", "/mcp",
                         body=json.dumps({"jsonrpc": "2.0",
                                          "method": "notifications/initialized"}),
                         headers={"Content-Type": "application/json"})
            r = conn.getresponse()
            framed = r.status == 202 and r.getheader("Content-Length") == "0" \
                and r.read() == b""
        except (socket.timeout, OSError):
            framed = False
        finally:
            conn.close()
        checks.append(("http 202 carries Content-Length: 0 for keep-alive clients",
                       framed, "framed" if framed else "unframed or hung"))
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()



def pod_tickets(status2: str) -> str:
    return f"""## T-9001 - Example: the volume contract, first revision

**Status:** in-progress
**Owner:** shared
**Priority:** next

**Purpose:**
A two-ticket fixture the selftest unpacks into a fake fetcher volume: revisions/ dirs, the
`current` symlink, artifact.json beside the tree.

---

## T-9002 - Example: a second ticket so counts are non-trivial

**Status:** {status2}
**Owner:** shared
**Priority:** someday

**Purpose:**
Present so `tickets by status` has two keys, and so the content swap is visible.

---
"""


def pod_checks(checks: list) -> None:
    """T-0037 phase 4b: the fetcher's volume contract. The server rereads through `current` on
    every call and takes repo_facts from artifact.json per call - a swap shows up without a
    restart, and pruning the revision the server started on changes nothing."""
    import shutil
    import tempfile
    import urllib.error
    import urllib.request

    tag1, tag2 = "a" * 12, "b" * 12
    root = Path(tempfile.mkdtemp(prefix="selftest-pod-"))
    revs = {}
    for tag, status2 in ((tag1, "open"), (tag2, "done")):
        d = root / "revisions" / tag
        (d / "docs").mkdir(parents=True)
        (d / "tickets.md").write_text(pod_tickets(status2))
        (d / "docs" / "note.md").write_text(f"# a mock doc\nthe {tag} revision's doc\n")
        meta = {"url": "http://example.test/artifact.tar.gz",
                "revision": f"latest@sha256:{tag * 5}", "digest": f"sha256:{tag * 5}",
                "produced": "2026-11-25T15:00:00Z", "unpacked": "2026-11-25T15:00:01Z",
                "source": f"selftest fixture {tag}"}
        if tag == tag2:
            meta["origin_revision"] = "main@sha1:" + "c" * 40
        (d / "artifact.json").write_text(json.dumps(meta))
        revs[tag] = d
    (root / "current").symlink_to(Path("revisions") / tag1)

    proc = subprocess.Popen(
        [sys.executable, str(SERVER), "--http", "0", "--data-root", str(root)],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    try:
        line = proc.stdout.readline().strip()
        m = re.match(r"listening on (\S+):(\d+)$", line)
        checks.append(("pod server announces its port", m is not None, line[:60]))
        if m is None:
            return
        url = f"http://{m.group(1)}:{m.group(2)}/mcp"

        def text_of(body: str) -> str:
            content = json.loads(body).get("result", {}).get("content", [])
            return "\n".join(c.get("text", "") for c in content if isinstance(c, dict))

        def call(tool: str, args: dict | None = None):
            body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                               "params": {"name": tool, "arguments": args or {}}})
            req = urllib.request.Request(url, data=body.encode(), method="POST",
                                         headers={"Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req, timeout=10) as r:
                    return r.status, text_of(r.read().decode())
            except urllib.error.HTTPError as e:
                return e.code, e.read().decode()

        status, facts = call("repo_facts")
        checks.append(("pod repo_facts reports artifact.json of v1", status == 200
                       and f"digest: sha256:{tag1 * 5}" in facts and "no git was asked" in facts,
                       facts.splitlines()[0] if facts else "empty"))
        status, doc = call("read_doc", {"name": "docs/note.md"})
        v1_doc = status == 200 and "refused" not in doc and f"the {tag1} revision's doc" in doc
        tmp = root / ".current.tmp"
        tmp.symlink_to(Path("revisions") / tag2)
        os.replace(tmp, root / "current")  # the fetcher's rename(2)
        _, listing = call("list_tickets")
        status, doc = call("read_doc", {"name": "docs/note.md"})
        v2_doc = status == 200 and "refused" not in doc and f"the {tag2} revision's doc" in doc
        status, facts = call("repo_facts")
        checks.append(("pod sees v2 after a swap, no restart (facts, tickets, and docs)", status == 200
                       and f"digest: sha256:{tag2 * 5}" in facts
                       and "origin revision: main@sha1:" + "c" * 40 in facts
                       and " done " in listing and " open " not in listing
                       and v1_doc and v2_doc,
                       f"HTTP {status}, doc v1: {v1_doc}, doc v2: {v2_doc}"))
        shutil.rmtree(revs[tag1])  # retention prunes the tree the server started on
        status, doc = call("read_doc", {"name": "docs/note.md"})
        ok_doc = status == 200 and "refused" not in doc and f"the {tag2} revision's doc" in doc
        status, text = call("repo_facts")
        checks.append(("pod still answers after v1 is pruned (facts and docs)", status == 200
                       and ok_doc and f"digest: sha256:{tag2 * 5}" in text, f"HTTP {status}"))
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        shutil.rmtree(root, ignore_errors=True)


def relative_launch_checks(checks: list) -> None:
    """The .pi/mcp.json launch shape, locked forever: cwd = the repo root, a RELATIVE
    --tickets tickets.md - exactly how pi launches this server. Fable's regression: the
    phase-4b fix dropped the startup resolve, and read_doc AGENTS.md refused everything
    for exactly this launch."""
    reqs = [
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "read_doc", "arguments": {"name": "AGENTS.md"}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "list_docs", "arguments": {}}},
    ]
    proc = subprocess.run([sys.executable, str(SERVER), "--tickets", "tickets.md"],
                          input="\n".join(json.dumps(r) for r in reqs) + "\n",
                          capture_output=True, text=True, timeout=30, cwd=str(ROOT))
    keyed = {}
    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        msg = json.loads(line)
        keyed[msg.get("id")] = msg
    doc = "\n".join(c.get("text", "") for c in keyed[1]["result"]["content"])
    checks.append(("relative launch: read_doc AGENTS.md answers, not refused",
                   "refused" not in doc and len(doc) > 0, doc[:60]))
    docs = "\n".join(c.get("text", "") for c in keyed[2]["result"]["content"])
    checks.append(("relative launch: list_docs indexes the repo",
                   len(docs.splitlines()) > 5, f"{len(docs.splitlines())} entries"))


def bearer_checks(checks: list) -> None:
    """The bearer-token option over HTTP (kubernetes/mcp.md): fail-closed 401, the token
    file read per request so a Secret rotation needs no restart, stdio unaffected."""
    import urllib.error
    import urllib.request
    token_file = Path(tempfile.mkstemp(prefix="selftest-token-")[1])
    token_file.write_text("first-secret\n")
    proc = subprocess.Popen(
        [sys.executable, str(SERVER), "--tickets", str(ROOT / "tickets.md"),
         "--http", "0", "--bearer-token-file", str(token_file)],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    try:
        line = proc.stdout.readline().strip()
        m = re.match(r"listening on (\S+):(\d+)$", line)
        checks.append(("bearer server announces its port", m is not None, line[:60]))
        if m is None:
            return
        url = f"http://{m.group(1)}:{m.group(2)}/mcp"

        def post(body: str, headers=None):
            req = urllib.request.Request(url, data=body.encode(),
                                         headers={"Content-Type": "application/json",
                                                  **(headers or {})},
                                         method="POST")
            try:
                with urllib.request.urlopen(req, timeout=10) as r:
                    return r.status, r.read()
            except urllib.error.HTTPError as e:
                return e.code, e.read()

        init = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
        status, _ = post(init)
        checks.append(("bearer: a POST without the header is 401", status == 401,
                       f"HTTP {status}"))
        status, _ = post(init, headers={"Authorization": "Bearer wrong-secret"})
        checks.append(("bearer: a wrong token is 401", status == 401, f"HTTP {status}"))
        status, body = post(init, headers={"Authorization": "Bearer first-secret"})
        name = json.loads(body).get("result", {}).get("serverInfo", {}).get("name") \
            if status == 200 else None
        checks.append(("bearer: the right token passes",
                       status == 200 and name == "chudmax-tickets", f"HTTP {status}"))
        token_file.write_text("second-secret\n")  # rotation: no restart
        status, _ = post(json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}),
                         headers={"Authorization": "Bearer first-secret"})
        checks.append(("bearer: the old token is refused after rotation", status == 401,
                       f"HTTP {status}"))
        status, body = post(json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}),
                            headers={"Authorization": "Bearer second-secret"})
        n = len(json.loads(body).get("result", {}).get("tools", [])) if status == 200 else 0
        checks.append(("bearer: the new token passes, seven tools",
                       status == 200 and n == 7, f"HTTP {status}, {n} tools"))
        status, raw = post(json.dumps({"jsonrpc": "2.0",
                                       "method": "notifications/initialized"}),
                           headers={"Authorization": "Bearer second-secret"})
        checks.append(("bearer: notifications still answer 202 with an empty body",
                       status == 202 and raw == b"", f"HTTP {status}"))
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        token_file.unlink()


def main() -> int:
    if not SERVER.exists():
        print(f"FAIL: {SERVER} not found")
        return 1
    proc = subprocess.run([sys.executable, str(SERVER), "--tickets", str(ROOT / "tickets.md")],
                         input=payload(),
                         capture_output=True, text=True, timeout=30)
    if proc.returncode != 0:
        print(f"FAIL: server exited {proc.returncode}: {proc.stderr[:200]}")
        return 1

    results = {}
    schema = []
    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            print(f"FAIL: non-JSON output: {line[:120]}")
            return 1
        if "result" not in msg:
            continue
        if msg.get("id") == LIST_ID:
            schema = msg["result"].get("tools", [])
            continue
        content = msg["result"].get("content", [])
        results[CALLS[msg["id"] - 1]["key"]] = \
            "\n".join(c.get("text", "") for c in content if isinstance(c, dict))

    checks = []

    tools = results.get("list_tickets", "")
    ticket_lines = [l for l in tools.splitlines() if l.startswith("T-")]
    on_disk = len([l for l in (ROOT / "tickets.md").read_text().splitlines()
                   if l.startswith("## T-")])
    checks.append(("ticket count matches tickets.md", len(ticket_lines) == on_disk,
                   f"{len(ticket_lines)} vs {on_disk}"))

    facts = results.get("repo_facts", "")
    checks.append(("repo_facts reports its own state", "branch=" in facts and "last commit=" in facts,
                   facts.splitlines()[0] if facts else "empty"))

    refused = results.get("read_source", "")
    checks.append(("source code is not readable through the doc door",
                   "refused" in refused, refused[:80]))

    docs = results.get("list_docs", "")
    checks.append(("docs index is non-empty", len(docs.splitlines()) > 5,
                   f"{len(docs.splitlines())} entries"))

    hits = results.get("search_docs", "")
    checks.append(("search finds the epistemic rule", "verified-here" in hits, hits[:60]))

    checks.append(("tools/list advertises seven tools", len(schema) == 7,
                   ", ".join(t.get("name", "?") for t in schema) or "empty"))

    # Trims cut at line breaks, so a cap is an upper bound that is nearly reached, not an exact count.
    got = kept(results.get("ticket_300", ""))
    checks.append(("get_ticket honours a caller's max_chars", got is not None and 200 < got <= 300,
                   f"asked for 300, kept {got}"))

    for tool, key in (("get_ticket", "ticket_default"), ("read_doc", "doc_default")):
        said = advertised_default(schema, tool)
        got = kept(results.get(key, ""))
        checks.append((f"{tool} default cap is the one its schema advertises",
                       said is not None and got is not None and 0.8 * said < got <= said,
                       f"advertised {said}, kept {got}"))

    # A long ticket keeps its start and its latest entries: a start-only cut once reported a
    # done ticket as blocked, because its resolution was at the end (T-0023, 2026-11-24).
    full = ticket_block("T-0018")  # this file's own reading, not the server's parser
    trimmed = results.get("ticket_default", "")
    title = full.splitlines()[0]
    last = [l for l in full.splitlines() if l.strip() and l.strip() != "---"][-1]
    checks.append(("a trimmed ticket keeps its title and its last line",
                   trimmed.startswith(title) and last in trimmed, f"last line: {last[:50]}"))
    whole = results.get("ticket_all", "")
    said_all = re.search(r"max_chars=(\d+) returns all", trimmed)
    checks.append(("the trim note gives the max_chars that returns it all",
                   said_all is not None and int(said_all.group(1)) == len(whole) and kept(whole) is None,
                   f"note says {said_all.group(1) if said_all else None}, whole ticket is {len(whole)}"))

    http_checks(checks)
    pod_checks(checks)
    relative_launch_checks(checks)
    bearer_checks(checks)

    ok = True
    for label, passed, detail in checks:
        print(f"{'PASS' if passed else 'FAIL'}  {label}  ({detail})")
        ok = ok and passed
    print("\nself-test:", "OK" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
