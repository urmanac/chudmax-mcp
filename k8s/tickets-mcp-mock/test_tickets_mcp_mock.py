#!/usr/bin/env python3
"""test_tickets_mcp_mock.py - the mock ticket server's selftest.

The canonical repo's rule is that its own selftest passes before anything merges; this suite
is the mock's version of that: it spawns the mock as a real subprocess, drives it over BOTH
transports (one JSON object per stdio line; real loopback HTTP), and asserts on what comes
back. Results are keyed per call, never by tool name, because the same tool is called several
times. It also carries this card's per-call contract proof: with --data-root, a symlink swap
is visible on the next call without a restart, and pruning the revision the server started on
changes nothing.

Run: python3 k8s/tickets-mcp-mock/test_tickets_mcp_mock.py
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
SERVER = HERE / "ticket_mcp_mock.py"
FIXTURE = HERE / "fixture"

# The trim note: at the end for read_doc, in the middle for get_ticket.
TRIM_NOTE = re.compile(r"\n\[\.\.\. [^\]]*\]\n?")


def text_of(body: str) -> str:
    """The text content of a JSON-RPC response, flattened."""
    content = json.loads(body).get("result", {}).get("content", [])
    return "\n".join(c.get("text", "") for c in content if isinstance(c, dict))


class StdioSession:
    """The mock over stdio: send lines, get one reply per valid line, keyed by id."""

    def __init__(self, extra_args: list | None = None):
        self.proc = subprocess.Popen(
            [sys.executable, str(SERVER), *(extra_args or [])],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def ask(self, reqs: list) -> dict:
        """Send one JSON object per line; return replies keyed by their id."""
        payload = "\n".join(json.dumps(r) for r in reqs) + "\n"
        out, _ = self.proc.communicate(payload, timeout=30)
        keyed = {}
        for line in out.splitlines():
            line = line.strip()
            if not line:
                continue
            msg = json.loads(line)
            if msg.get("id") is not None:
                keyed[msg["id"]] = msg
        return keyed

    def close(self) -> None:
        if self.proc.poll() is None:
            self.proc.kill()


class HttpServer:
    """The mock over HTTP on a port the OS picks; posts and reports."""

    def __init__(self, extra_args: list):
        self.proc = subprocess.Popen(
            [sys.executable, str(SERVER), "--http", "0", *extra_args],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        line = self.proc.stdout.readline().strip()
        m = re.match(r"listening on (\S+):(\d+)$", line)
        if m is None:
            self.close()
            raise RuntimeError(f"no port line: {line!r}")
        self.url = f"http://{m.group(1)}:{m.group(2)}/mcp"

    def post(self, body: str, headers: dict | None = None):
        req = urllib.request.Request(self.url, data=body.encode(), method="POST",
                                     headers={"Content-Type": "application/json",
                                              **(headers or {})})
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()

    def call(self, tool: str, args: dict | None = None, headers: dict | None = None):
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                           "params": {"name": tool, "arguments": args or {}}})
        status, raw = self.post(body, headers)
        return status, text_of(raw.decode()) if status == 200 else raw.decode()

    def close(self) -> None:
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def advertised_default(schema: list, tool: str) -> int | None:
    """The max_chars default a tool's schema description advertises ('default N'), or None."""
    for t in schema:
        if t.get("name") == tool:
            desc = t["inputSchema"]["properties"].get("max_chars", {}).get("description", "")
            m = re.search(r"default (\d+)", desc)
            return int(m.group(1)) if m else None
    return None


def kept(text: str) -> int | None:
    """Characters of real content around the trim note, or None if it was not trimmed."""
    m = TRIM_NOTE.search(text)
    return len(text) - len(m.group(0)) if m else None


def fixture_ticket_block(tid: str) -> str:
    """A fixture ticket as the server parses it: through the next heading's line start."""
    text = (FIXTURE / "tickets.md").read_text()
    start = text.index(f"## {tid} - ")
    nxt = text.find("\n## ", start + 1)
    # The parser's block ends at the next heading's line START, so it keeps the newline
    # this helper's find() would otherwise cut; keep it too and the lengths agree.
    return text[start:nxt + 1] if nxt != -1 else text[start:]


def stdio_checks(checks: list) -> None:
    s = StdioSession()
    try:
        reqs = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 3, "method": "resources/list"},
            {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
             "params": {"name": "list_tickets", "arguments": {}}},
            # A long ticket must come back trimmed at the default cap.
            {"jsonrpc": "2.0", "id": 5, "method": "tools/call",
             "params": {"name": "get_ticket", "arguments": {"id": "T-0002"}}},
            {"jsonrpc": "2.0", "id": 6, "method": "tools/call",
             "params": {"name": "get_ticket", "arguments": {"id": "T-0002", "max_chars": 300}}},
            {"jsonrpc": "2.0", "id": 7, "method": "tools/call",
             "params": {"name": "get_ticket", "arguments": {"id": "T-0002", "max_chars": 1000000}}},
            {"jsonrpc": "2.0", "id": 8, "method": "tools/call",
             "params": {"name": "search_tickets", "arguments": {"query": "frobnicator"}}},
            {"jsonrpc": "2.0", "id": 9, "method": "tools/call",
             "params": {"name": "list_docs", "arguments": {}}},
            {"jsonrpc": "2.0", "id": 10, "method": "tools/call",
             "params": {"name": "read_doc", "arguments": {"name": "docs/example-queue-wiring.md"}}},
            {"jsonrpc": "2.0", "id": 11, "method": "tools/call",
             "params": {"name": "read_doc", "arguments": {"name": "tickets.md", "max_chars": 200}}},
            {"jsonrpc": "2.0", "id": 17, "method": "tools/call",
             "params": {"name": "read_doc", "arguments": {"name": "tickets.md"}}},
            {"jsonrpc": "2.0", "id": 12, "method": "tools/call",
             "params": {"name": "read_doc",
                        "arguments": {"name": "ticket_mcp_mock.py"}}},
            {"jsonrpc": "2.0", "id": 13, "method": "tools/call",
             "params": {"name": "search_docs", "arguments": {"query": "queue"}}},
            {"jsonrpc": "2.0", "id": 14, "method": "tools/call",
             "params": {"name": "search_docs", "arguments": {"query": "the", "max_hits": 2}}},
            {"jsonrpc": "2.0", "id": 15, "method": "tools/call",
             "params": {"name": "nonexistent_tool", "arguments": {}}},
            {"jsonrpc": "2.0", "id": 16, "method": "tickets/propose"},
            # Malformed stdio lines are skipped silently: they must not shift the replies.
        ]
        payload = ("{not json at all\n\n   \n{also broken\n"
                   + "\n".join(json.dumps(r) for r in reqs) + "\n"
                   + "{trailing garbage\n")
        out, _ = s.proc.communicate(payload, timeout=30)
        keyed = {}
        lines = [l.strip() for l in out.splitlines() if l.strip()]
        for line in lines:
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                checks.append(("stdio replies are all valid JSON", False, line[:60]))
                return
            keyed[msg.get("id")] = msg
        checks.append(("stdio replies are all valid JSON", True, f"{len(lines)} lines"))
        checks.append(("stdio skips blank and unparsable lines silently",
                       set(keyed) == set(range(1, 18)), f"ids: {sorted(keyed)}"))

        init = keyed[1]["result"]
        checks.append(("stdio initialize shape",
                       init["protocolVersion"] == "2024-11-05"
                       and init["serverInfo"]["name"] == "chudmax-tickets"
                       and init["capabilities"]["tools"]["listChanged"] is False,
                       init["serverInfo"]["name"]))

        schema = keyed[2]["result"]["tools"]
        names = [t["name"] for t in schema]
        checks.append(("stdio tools/list advertises the seven tools, in order",
                       names == ["list_tickets", "get_ticket", "search_tickets", "repo_facts",
                                 "list_docs", "read_doc", "search_docs"], ", ".join(names)))
        checks.append(("stdio resources/list answers with the same tools",
                       [t["name"] for t in keyed[3]["result"]["tools"]] == names, "the quirk"))

        listing = keyed[4]["result"]["content"][0]["text"]
        on_disk = len([l for l in (FIXTURE / "tickets.md").read_text().splitlines()
                       if l.startswith("## T-")])
        fixture_lines = [l for l in listing.splitlines() if l.startswith("T-")]
        checks.append(("stdio list_tickets answers one line per fixture ticket",
                       len(fixture_lines) == on_disk == 6
                       and all(l.split()[0].startswith("T-") for l in fixture_lines),
                       f"{len(fixture_lines)} vs {on_disk}"))

        long_block = fixture_ticket_block("T-0002")
        trimmed = keyed[5]["result"]["content"][0]["text"]
        last_line = [l for l in long_block.splitlines() if l.strip() and l.strip() != "---"][-1]
        got = kept(trimmed)
        said_all = re.search(r"max_chars=(\d+) returns all", trimmed)
        checks.append(("stdio get_ticket default trims the middle, keeping title and last line",
                       got is not None and 0.8 * 3000 < got <= 3000
                       and trimmed.startswith(long_block.splitlines()[0])
                       and last_line in trimmed
                       and said_all is not None and int(said_all.group(1)) == len(long_block),
                       f"kept {got}, full {len(long_block)}"))

        got300 = kept(keyed[6]["result"]["content"][0]["text"])
        checks.append(("stdio get_ticket honours a caller's max_chars",
                       got300 is not None and 200 < got300 <= 300, f"asked 300, kept {got300}"))
        whole = keyed[7]["result"]["content"][0]["text"]
        checks.append(("stdio get_ticket with a huge cap returns everything, no note",
                       kept(whole) is None and whole == long_block, f"{len(whole)} chars"))

        said = advertised_default(schema, "get_ticket")
        checks.append(("get_ticket's advertised default matches its behaviour",
                       said == 3000 and got is not None and 0.8 * said < got <= said,
                       f"advertised {said}, kept {got}"))
        said_doc = advertised_default(schema, "read_doc")
        got_doc = kept(keyed[17]["result"]["content"][0]["text"])
        checks.append(("read_doc's advertised default matches its behaviour",
                       said_doc == 1500 and got_doc is not None and 0.8 * said_doc < got_doc <= said_doc,
                       f"advertised {said_doc}, kept {got_doc}"))

        checks.append(("stdio search_tickets finds the fixture's queue ticket",
                       "T-0002" in keyed[8]["result"]["content"][0]["text"], "query: frobnicator"))
        checks.append(("stdio list_docs indexes the fixture",
                       len(keyed[9]["result"]["content"][0]["text"].splitlines()) >= 6,
                       "6 fixture files"))
        full_doc = keyed[10]["result"]["content"][0]["text"]
        checks.append(("stdio read_doc returns a short doc whole",
                       kept(full_doc) is None
                       and full_doc == (FIXTURE / "docs" / "example-queue-wiring.md").read_text(),
                       f"{len(full_doc)} chars"))
        refused = keyed[12]["result"]["content"][0]["text"]
        checks.append(("stdio read_doc refuses what is outside the readable set",
                       "refused" in refused, refused[:70]))
        hits = keyed[13]["result"]["content"][0]["text"]
        checks.append(("stdio search_docs answers in file:line form",
                       re.search(r"^[a-z/.-]+\.md:\d+: ", hits, re.MULTILINE) is not None,
                       hits.splitlines()[0][:60] if hits else "empty"))
        capped = keyed[14]["result"]["content"][0]["text"]
        checks.append(("stdio search_docs honours max_hits with a note",
                       len(capped.splitlines()) == 3 and "capped at 2" in capped,
                       f"{len(capped.splitlines())} lines"))

        unknown = keyed[15]
        checks.append(("stdio unknown tool is an isError result",
                       unknown["result"].get("isError") is True
                       and "unknown tool: nonexistent_tool" in text_of(json.dumps(unknown)),
                       "isError"))
        bad_method = keyed[16]
        checks.append(("stdio unknown method is -32601",
                       bad_method.get("error", {}).get("code") == -32601, "error code"))
    finally:
        s.close()


def http_checks(checks: list) -> None:
    h = HttpServer([])
    try:
        status, body = h.post(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                          "params": {}}))
        name = json.loads(body).get("result", {}).get("serverInfo", {}).get("name") \
            if status == 200 else None
        checks.append(("http initialize answers as chudmax-tickets",
                       status == 200 and name == "chudmax-tickets", f"HTTP {status}"))

        status, body = h.post(json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}))
        n = len(json.loads(body).get("result", {}).get("tools", [])) if status == 200 else 0
        checks.append(("http tools/list advertises seven tools", status == 200 and n == 7,
                       f"HTTP {status}, {n} tools"))

        status, listing = h.call("list_tickets")
        checks.append(("http list_tickets answers from the fixture",
                       status == 200 and listing.splitlines()[0].startswith("T-"),
                       f"HTTP {status}, {listing[:40]}"))

        status, facts = h.call("repo_facts")
        checks.append(("http repo_facts answers (fixture standalone mode)",
                       status == 200 and "tickets by status" in facts, f"HTTP {status}"))

        status, _ = h.post("{not json")
        checks.append(("http refuses a malformed body with 400", status == 400, f"HTTP {status}"))

        status, raw = h.post(json.dumps({"jsonrpc": "2.0",
                                         "method": "notifications/initialized"}))
        checks.append(("http takes a notification with 202 and an empty body",
                       status == 202 and raw == b"", f"HTTP {status}"))

        try:
            with urllib.request.urlopen(urllib.request.Request(h.url, method="GET"),
                                        timeout=10) as r:
                gstatus = r.status
        except urllib.error.HTTPError as e:
            gstatus = e.code
        checks.append(("http refuses GET with 405", gstatus == 405, f"HTTP {gstatus}"))
    finally:
        h.close()


def pod_volume(dest: Path, status2: str, origin: bool) -> dict:
    """One revision dir + its artifact.json, as the fetcher unpacks them."""
    (dest / "docs").mkdir(parents=True)
    shutil.copy(FIXTURE / "tickets.md", dest / "tickets.md")
    shutil.copy(FIXTURE / "AGENTS.md", dest / "AGENTS.md")
    shutil.copy(FIXTURE / "README.md", dest / "README.md")
    shutil.copy(FIXTURE / "docs" / "example-queue-wiring.md",
                dest / "docs" / "example-queue-wiring.md")
    # The revision's own edit: the status the swap should make visible.
    tickets = (dest / "tickets.md").read_text().replace("**Status:** open", f"**Status:** {status2}")
    (dest / "tickets.md").write_text(tickets)
    tag = dest.name
    meta = {"url": "https://artifact-server.example/chudmax-tickets.tar.gz",
            "revision": f"latest@sha256:{tag * 8}", "digest": f"sha256:{tag * 8}",
            "produced": "2026-11-25T15:00:00Z", "unpacked": "2026-11-25T15:00:01Z",
            "source": f"selftest fixture {tag}"}
    if origin:
        meta["origin_revision"] = "main@sha1:" + "c" * 40
    (dest / "artifact.json").write_text(json.dumps(meta) + "\n")
    return meta


def pod_checks(checks: list) -> None:
    """The per-call contract, proven: v1 -> swap to v2 without a restart -> prune v1 -> still answers."""
    tag1, tag2 = "a" * 8, "b" * 8
    root = Path(tempfile.mkdtemp(prefix="mock-selftest-pod-"))
    (root / "revisions").mkdir()
    pod_volume(root / "revisions" / tag1, "open", origin=False)
    pod_volume(root / "revisions" / tag2, "done", origin=True)
    h = None
    try:
        h = HttpServer(["--data-root", str(root)])
        status, facts = h.call("repo_facts")
        checks.append(("pod repo_facts answers honestly when nothing is swapped yet",
                       status == 200 and "artifact facts: none yet" in facts,
                       f"HTTP {status}, {facts.splitlines()[0] if facts else 'empty'}"))

        # v1 is in place; swap current onto it the way the fetcher does (symlink + rename).
        tmp = root / ".current.tmp"
        tmp.symlink_to(Path("revisions") / tag1)
        os.replace(tmp, root / "current")

        status, facts = h.call("repo_facts")
        checks.append(("pod repo_facts reports artifact.json of v1",
                       status == 200 and f"digest: sha256:{tag1 * 8}" in facts
                       and "no git was asked" in facts,
                       facts.splitlines()[0] if facts else "empty"))
        status, listing = h.call("list_tickets")
        v1_open = " open " in listing

        tmp = root / ".current.tmp"
        tmp.symlink_to(Path("revisions") / tag2)
        os.replace(tmp, root / "current")  # the fetcher's rename(2); no restart anywhere

        status, listing = h.call("list_tickets")
        v2_content = " done " in listing and " open " not in listing
        status, facts = h.call("repo_facts")
        checks.append(("pod sees v2 after a swap, no restart",
                       status == 200 and f"digest: sha256:{tag2 * 8}" in facts
                       and "origin revision: main@sha1:" + "c" * 40 in facts
                       and v1_open and v2_content,
                       f"HTTP {status}; open before: {v1_open}, done after: {v2_content}"))

        shutil.rmtree(root / "revisions" / tag1)  # retention prunes the starting revision
        status, listing = h.call("list_tickets")
        ok_list = status == 200 and "T-0002" in listing
        status, facts = h.call("repo_facts")
        checks.append(("pod still answers after v1 is pruned",
                       ok_list and status == 200 and f"digest: sha256:{tag2 * 8}" in facts,
                       f"HTTP {status}"))
    finally:
        if h is not None:
            h.close()
        shutil.rmtree(root, ignore_errors=True)


def fallback_flags_checks(checks: list) -> None:
    h = HttpServer(["--revision", "main@sha1:" + "0" * 40,
                    "--artifact-produced", "2026-11-25T15:00:00Z",
                    "--artifact-unpacked", "2026-11-25T15:00:01Z"])
    try:
        status, facts = h.call("repo_facts")
        checks.append(("fallback flags: repo_facts reports what it was given",
                       status == 200 and "revision: main@sha1:" + "0" * 40 in facts
                       and "no git was asked" in facts,
                       facts.splitlines()[0] if facts else "empty"))
    finally:
        h.close()


def bearer_checks(checks: list) -> None:
    token_file = Path(tempfile.mkstemp(prefix="mock-selftest-token-")[1])
    token_file.write_text("first-secret\n")
    h = HttpServer(["--bearer-token-file", str(token_file)])
    auth = {"Authorization": "Bearer first-secret"}
    try:
        status, body = h.post(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                          "params": {}}))
        checks.append(("bearer: a POST without the header is 401", status == 401,
                       f"HTTP {status}"))
        status, body = h.post(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                          "params": {}}),
                              headers={"Authorization": "Bearer wrong-secret"})
        checks.append(("bearer: a wrong token is 401", status == 401, f"HTTP {status}"))
        status, body = h.post(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                          "params": {}}), headers=auth)
        name = json.loads(body).get("result", {}).get("serverInfo", {}).get("name") \
            if status == 200 else None
        checks.append(("bearer: the right token passes",
                       status == 200 and name == "chudmax-tickets", f"HTTP {status}"))
        token_file.write_text("second-secret\n")  # rotation: no restart
        status, _ = h.post(json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}),
                           headers=auth)
        checks.append(("bearer: the old token is refused after rotation", status == 401,
                       f"HTTP {status}"))
        status, body = h.post(json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}),
                              headers={"Authorization": "Bearer second-secret"})
        n = len(json.loads(body).get("result", {}).get("tools", [])) if status == 200 else 0
        checks.append(("bearer: the new token passes, seven tools",
                       status == 200 and n == 7, f"HTTP {status}, {n} tools"))
        status, raw = h.post(json.dumps({"jsonrpc": "2.0",
                                         "method": "notifications/initialized"}),
                             headers={"Authorization": "Bearer second-secret"})
        checks.append(("bearer: notifications still answer 202 with an empty body",
                       status == 202 and raw == b"", f"HTTP {status}"))
    finally:
        h.close()
        os.unlink(token_file)


def hygiene_checks(checks: list) -> None:
    """Public-safe by construction: the fixture carries nothing private-shaped."""
    denylist = [
        (re.compile(r"\b(?:10|172|192)\.\d+\.\d+\.\d+\b"), "LAN-shaped address"),
        (re.compile(r"\b169\.254\.\d+\.\d+\b"), "link-local address"),
        (re.compile(r"gitlab\.com|github\.com"), "real hostnames"),
        (re.compile(r"PRIVATE-TOKEN|AKIA[A-Z0-9]{8,}|BEGIN [A-Z ]*PRIVATE KEY"), "credential shapes"),
    ]
    clean = True
    where = ""
    for p in sorted(FIXTURE.rglob("*")):
        if not p.is_file():
            continue
        body = p.read_text(errors="replace").lower()
        for pattern, what in denylist:
            if pattern.search(p.read_text(errors="replace")) or pattern.search(body):
                clean, where = False, f"{p.name}: {what}"
    checks.append(("fixture hygiene: the denylist is clean", clean, where or "all fixture files"))


def main() -> int:
    if not SERVER.exists():
        print(f"FAIL: {SERVER} not found")
        return 1
    checks: list = []
    stdio_checks(checks)
    http_checks(checks)
    pod_checks(checks)
    fallback_flags_checks(checks)
    bearer_checks(checks)
    hygiene_checks(checks)

    ok = True
    for label, passed, detail in checks:
        print(f"{'PASS' if passed else 'FAIL'}  {label}  ({detail})")
        ok = ok and passed
    print(f"\nmock selftest: {'OK' if ok else 'FAILED'} ({len(checks)} checks)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
