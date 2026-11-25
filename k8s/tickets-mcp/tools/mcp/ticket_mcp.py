#!/usr/bin/env python3
"""tools/mcp/ticket_mcp.py — chudmax's own MCP server, exposing tickets.md.

This is the one you asked for: not Strata's config server, not the fake test fixture.
It lets the Strata chat page (and any MCP client) discover what has been decided here
without a human re-explaining it.

Read-only by construction. There is no write path in this file at all.

Protocol: MCP over stdio, one JSON-RPC message per line (the same shape
serve/mcp_fake_server.py speaks, so serve/mcp.py's client can drive it) — or the same JSON-RPC
over HTTP with --http: POST one JSON-RPC object (a newline-delimited single line is also
accepted) to /mcp, get one JSON object back; a notification with no id is answered 202 with an
empty body; GET is refused 405; a malformed body is 400. With --bearer-token-file set, every
HTTP POST must carry "Authorization: Bearer <token>" (kubernetes/mcp.md): the token file is
read per request, so a Secret rotation needs no restart, and a missing, wrong, or unreadable
token is a fail-closed 401. stdio is a local pipe and stays auth-free. Whether the fork's hub accepts this
server by `url` is not verified from a node without the fork (`speculation`); the check happens
on the box, at T-0037 phase 12/14.

Run:
    python3 tools/mcp/ticket_mcp.py                     # stdio (the box's mode today)
    python3 tools/mcp/ticket_mcp.py --tickets tickets.md
    python3 tools/mcp/ticket_mcp.py --http 8081         # HTTP, the pod's mode (T-0037 phase 1)
    python3 tools/mcp/ticket_mcp.py --http 0            # HTTP on a port the OS picks (the selftest)
    python3 tools/mcp/ticket_mcp.py --http 8081 --revision main@sha1:... \
        --artifact-produced 2026-11-25T15:00:00Z --artifact-unpacked 2026-11-25T15:00:01Z
    python3 tools/mcp/ticket_mcp.py --data-root /data      # pod mode: rereads /data/current on every call

Wire into Strata by adding to the run config ("mcp_servers") or a --mcp-config file:
    {"mcpServers": {"chudmax-tickets": {"command": "python3",
      "args": ["/path/to/chudmax/tools/mcp/ticket_mcp.py"],
      "cwd": "/path/to/chudmax"}}}

Design constraints, and why they are what they are:
- Read-only. Core rule 5: do not invent capabilities. `wont-do` is the delete operation.
- Small payloads. A 15 KB ticket dump is a context tax paid by every turn. list_tickets returns
  one line per ticket; get_ticket returns one ticket, trimmed to max_chars from the middle:
  tickets are written as diaries, so the start (title, status, purpose) and the end (the latest
  entries) both matter, and a cut that keeps only the start reports a closed ticket as still
  blocked. read_doc trims from the end: docs read top-down.
- No free paths. The tickets file is fixed at launch, not per call. Same stance as
  tools/strata_mcp.py ("no tool takes a shell command or a free path").
- Statuses are data, not authority. A ticket's status is whatever the file says at the
  moment of the call. Nothing here can make a ticket "done"; only a commit can.
- Per call, through the symlink (fixed 2026-11-25, T-0037 phase 4b). The fetcher swaps
  <root>/current by rename(2) and prunes the revision dirs it no longer keeps. A store that
  resolved the symlink once at startup kept reading the stale tree (and died with it), and its
  repo_facts never saw new facts. Everything here now opens through `current` on every call, and
  repo_facts reads <root>/current/artifact.json per call - resolved ONCE at the start of
  each call, so one call never mixes two revisions and a mid-call swap waits for the next.
  The plain-file mode (--tickets) resolves its path ONCE at startup: no symlink churn behind
  a plain path, and a relative --tickets works from any cwd. The old flags
  (--revision/--artifact-produced/--artifact-unpacked) stay for a no-fetcher setup: fallbacks
  and overrides, not the pod mode.
"""

from __future__ import annotations

import argparse
import hmac
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

TICKET_RE = re.compile(r"^## (T-\d{4}) - (.+?)\s*$", re.MULTILINE)
FIELD_RE = re.compile(r"^\*\*(Status|Owner|Priority|Due|Tags|Depends on|Coordination):\*\*\s*(.*)$",
                      re.MULTILINE)
MAX_CHARS_DEFAULT = 3000
HEAD_SHARE = 0.4  # of a trimmed ticket, the share kept from the start; the rest comes from the end
DOC_MAX_DEFAULT = 1500
READABLE_TOP = ("README.md", "AGENTS.md", "tickets.md")
READABLE_DIRS = ("docs", "decisions", "plans")

def trim_middle(text: str, max_chars: int) -> str:
    """Keep about max_chars of text: its start and its end, cut at line breaks, with a note between."""
    if len(text) <= max_chars:
        return text
    head_n = int(max_chars * HEAD_SHARE)
    tail_n = max_chars - head_n
    head = text[:head_n]
    if "\n" in head:
        head = head[:head.rfind("\n")]
    tail = text[len(text) - tail_n:]
    if "\n" in tail:
        tail = tail[tail.find("\n") + 1:]
    omitted = len(text) - len(head) - len(tail)
    note = (f"\n[... {omitted} chars omitted from the middle; the start and the latest entries are kept. "
            f"max_chars={len(text)} returns all of it]\n")
    return head + note + tail


TOOLS = [
    {
        "name": "list_tickets",
        "description": "Every ticket as one line: id, title, status, priority. Cheap; call this first.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "get_ticket",
        "description": "One ticket, by id (e.g. 'T-0019'). A long one is trimmed from the middle: the "
                       "start (title, status, purpose) and the latest entries at the end are kept, and "
                       "a note says how much was left out and what max_chars returns all of it.",
        "inputSchema": {
            "type": "object",
            "properties": {"id": {"type": "string", "description": "ticket id, e.g. T-0019"},
                           "max_chars": {"type": "integer",
                                         "description": f"default {MAX_CHARS_DEFAULT}"}},
            "required": ["id"],
        },
    },
    {
        "name": "search_tickets",
        "description": "Substring search over ticket text. Returns matching ticket ids with a snippet.",
        "inputSchema": {
            "type": "object",
            "properties": {"query": {"type": "string"}},
            "required": ["query"],
        },
    },
    {
        "name": "repo_facts",
        "description": "What the repo contains, and how old this checkout is: branch, sha, last commit, ahead/behind vs its remote. In pod mode (the server was started with --revision) it reports the revision the Flux artifact carried instead, and says so. Read this before quoting anything as current.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "list_docs",
        "description": "The documentation index: docs/, decisions/, plans/, README, AGENTS. One line each with size.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "read_doc",
        "description": "Read one doc by name (e.g. 'docs/mcp-architecture.md'). Only files in docs/, decisions/, plans/, README.md, AGENTS.md, tickets.md are readable. Truncated by default so a chat context does not balloon.",
        "inputSchema": {
            "type": "object",
            "properties": {"name": {"type": "string"},
                           "max_chars": {"type": "integer",
                                         "description": f"default {DOC_MAX_DEFAULT}"}},
            "required": ["name"],
        },
    },
    {
        "name": "search_docs",
        "description": "Substring search across all docs. Returns file:line matches, capped.",
        "inputSchema": {
            "type": "object",
            "properties": {"query": {"type": "string"}, "max_hits": {"type": "integer"}},
            "required": ["query"],
        },
    },
]


class Tickets:
    """The ticket store. Reads are per call, and in pod mode they go through the symlink
    afresh - the fetcher's swap and retention are invisible to a serving process (T-0037
    phase 4b)."""

    def __init__(self, tickets_path: Path | None = None, data_root: Path | None = None,
                 revision: str | None = None,
                 artifact_produced: str | None = None, artifact_unpacked: str | None = None):
        # Plain-file mode: resolve ONCE at startup - no symlink churn behind a plain
        # path, and the startup resolve is what makes a relative --tickets (the
        # .pi/mcp.json launch shape) work from any cwd (Fable's second finding on the
        # phase-4b fix). Pod mode keeps the symlink path unresolved; the base is
        # resolved at the START of each call instead (the per-call snapshot).
        self.tickets_path = tickets_path.resolve() if tickets_path is not None else None
        self.data_root = data_root          # pod mode: DIR/current is the tree, reread per call
        self.root = self._find_root(self.tickets_path) if tickets_path is not None else None
        # No-fetcher fallback (T-0037 phase 1): where there is no working tree, the server
        # reports the revision it was handed on the command line instead of asking git.
        self.revision = revision
        self.artifact_produced = artifact_produced
        self.artifact_unpacked = artifact_unpacked

    @staticmethod
    def _find_root(path: Path) -> Path:
        """The tree the readable set lives in: walk up from the tickets file to the first
        directory that is a repo root (.git) or a complete chudmax-shaped tree (STATE.md
        beside tickets.md - the shape a published subtree carries, which is not its own
        git repo). The walk stops there, so a subtree published inside a bigger checkout
        is its own tree, and the private repo root is found exactly as before."""
        for parent in [path.parent, *path.parents]:
            if (parent / ".git").exists() or (parent / "STATE.md").exists():
                return parent
        return path.parent

    def base(self) -> Path:
        """The tree this call reads from - a per-call snapshot in pod mode. The symlink
        is resolved ONCE here, at the start of the call, and every read in the call goes
        through that resolved directory: a fetcher swap mid-call is invisible until the
        next call, and the next call picks the swap up. The doc reads must resolve too -
        an unresolved symlink base can never contain a resolved candidate, so every
        read_doc would refuse (Fable's first finding on the phase-4b fix)."""
        if self.data_root is not None:
            return (self.data_root / "current").resolve()
        return self.root

    def tickets_file(self) -> Path:
        if self.data_root is not None:
            return self.base() / "tickets.md"
        return self.tickets_path

    @property
    def label(self) -> str:
        """What error messages name as the place the tickets were read from."""
        if self.data_root is not None:
            return str(self.data_root / "current")
        return str(self.tickets_path)

    def readable(self) -> list[Path]:
        base = self.base()
        files = [base / name for name in READABLE_TOP if (base / name).is_file()]
        for d in READABLE_DIRS:
            if (base / d).is_dir():
                files.extend(sorted((base / d).rglob("*.md")))
        return files

    def text(self) -> str:
        try:
            return self.tickets_file().read_text(encoding="utf-8")
        except OSError:
            return ""

    def parse_text(self, body: str) -> list[dict]:
        """The parser over a given body - lets a call parse the ONE snapshot it resolved."""
        matches = list(TICKET_RE.finditer(body))
        out = []
        for i, m in enumerate(matches):
            end = matches[i + 1].start() if i + 1 < len(matches) else len(body)
            block = body[m.start():end]
            fields = {k.lower(): v.strip() for k, v in FIELD_RE.findall(block)}
            out.append({"id": m.group(1), "title": m.group(2), "fields": fields,
                       "purpose": self._purpose(block), "block": block})
        return out

    def parse(self) -> list[dict]:
        return self.parse_text(self.text())

    @staticmethod
    def _purpose(block: str) -> str:
        m = re.search(r"\*\*Purpose:\*\*\s*(.+?)(?=\n\*\*|\n---)", block, re.DOTALL)
        return " ".join(m.group(1).split()) if m else ""

    def list_tickets(self) -> str:
        tickets = self.parse()
        if not tickets:
            return f"no tickets found in {self.label}"
        lines = [f"{t['id']}  {t['fields'].get('status', '?'):12}  {t['fields'].get('priority', '?'):6}  {t['title']}"
                 for t in tickets]
        return "\n".join(lines)

    def get_ticket(self, tid: str, max_chars: int = MAX_CHARS_DEFAULT) -> str:
        for t in self.parse():
            if t["id"].lower() == tid.lower():
                block = t["block"]
                return trim_middle(block, max_chars)
        return f"no ticket {tid} in {self.label}"

    def search(self, query: str) -> str:
        q = query.lower()
        hits = []
        for t in self.parse():
            haystack = t["block"].lower()
            if q in haystack:
                snippet = next((" ".join(l.split())[:160] for l in t["block"].splitlines()
                                if q in l.lower()), "")
                hits.append(f"{t['id']}  {t['fields'].get('status', '?')}  {t['title']}\n    {snippet}")
        return "\n".join(hits) if hits else f"no ticket matches '{query}'"

    def repo_facts(self) -> str:
        if self.data_root is not None:
            # Pod mode (T-0037 phase 4b): the facts come from artifact.json beside the tree,
            # read through the current symlink - resolved ONCE at the start of the call, so
            # the facts and the counts are one snapshot and a mid-call swap waits for the
            # next call.
            base = self.base()
            try:
                body = (base / "tickets.md").read_text(encoding="utf-8")
            except OSError:
                body = ""
            counts = {}
            for t in self.parse_text(body):
                counts[t["fields"].get("status", "?")] = counts.get(t["fields"].get("status", "?"), 0) + 1
            by_status = f"tickets by status: {json.dumps(counts, sort_keys=True)}\n"
            try:
                meta = json.loads((base / "artifact.json").read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as e:
                return (f"artifact facts: none yet ({type(e).__name__} reading {self.label}/artifact.json)\n"
                        + by_status
                        + "source: the fetcher has not swapped an artifact beside this tree yet; no git was asked\n")
            lines = [f"url: {meta.get('url', 'unknown')}",
                     f"revision: {meta.get('revision', 'unknown')}",
                     f"digest: {meta.get('digest', 'unknown')}",
                     f"artifact produced: {meta.get('produced', 'unknown')}",
                     f"artifact unpacked: {meta.get('unpacked', 'unknown')}",
                     f"source: {meta.get('source', 'unknown')}"]
            if meta.get("origin_revision"):
                lines.append(f"origin revision: {meta['origin_revision']}")
            return ("\n".join(lines) + "\n" + by_status
                    + "source: artifact.json beside the tree, reread through the current symlink "
                      "on every call; no git was asked\n")
        if self.revision is not None:
            counts = {}
            for t in self.parse():
                counts[t["fields"].get("status", "?")] = counts.get(t["fields"].get("status", "?"), 0) + 1
            return (f"revision: {self.revision}\n"
                    f"artifact produced: {self.artifact_produced or 'unknown'}\n"
                    f"artifact unpacked: {self.artifact_unpacked or 'unknown'}\n"
                    f"tickets by status: {json.dumps(counts, sort_keys=True)}\n"
                    "source: the revision this server was given; no git was asked\n")
        import subprocess
        root = self.root
        def run(cmd):
            try:
                p = subprocess.run(cmd, cwd=root, capture_output=True, text=True, timeout=10)
                if p.returncode != 0:
                    return None
                return p.stdout.strip()
            except Exception:
                return None
        files = run(["git", "ls-files"])
        commits = run(["git", "log", "--oneline", "-8"])
        branch = run(["git", "rev-parse", "--abbrev-ref", "HEAD"])
        sha = run(["git", "rev-parse", "--short", "HEAD"])
        when = run(["git", "log", "-1", "--format=%ad", "--date=short"])
        counts = {}
        for t in self.parse():
            counts[t["fields"].get("status", "?")] = counts.get(t["fields"].get("status", "?"), 0) + 1
        out = (f"checkout: branch={branch or 'unknown'} sha={sha or 'unknown'} "
              f"last commit={when or 'unknown'}\n"
              f"tickets by status: {json.dumps(counts, sort_keys=True)}\n")
        if files is None:
            out += (f"note: {self.label} is not inside a git working tree, so repo facts are "
                    "unavailable here. Ticket counts still reflect the file as read.")
        else:
            out += f"tracked files: {len(files.splitlines())}\nrecent commits:\n{commits or '(none)'}"
            behind = run(["git", "rev-list", "--count", "HEAD..@{upstream}"])
            ahead = run(["git", "rev-list", "--count", "@{upstream}..HEAD"])
            if behind is not None and ahead is not None:
                out += f"\nvs its remote tracking branch: {behind} behind, {ahead} ahead"
                if behind != "0":
                    out += "  <- BEHIND: treat anything quoted here as stale"
            else:
                out += "\nno upstream tracking configured for this branch"
            others = run(["git", "rev-list", "--count", "--all", "^HEAD"])
            if others and others != "0":
                out += (f"\ncommits on other branches not in this checkout: {others} "
                        "- this mirror does not see work that lives on another branch")
            branches = run(["git", "branch", "-r", "--format=%(refname:short)"])
            if branches:
                out += "\nremote branches: " + ", ".join(branches.splitlines())
        return out

    def list_docs(self) -> str:
        docs = self.readable()
        if not docs:
            return "no readable docs under docs/, decisions/, plans/"
        lines = []
        for p in docs:
            rel = p.relative_to(self.base())
            try:
                size = p.stat().st_size
            except OSError:
                size = 0
            head = ""
            try:
                for line in p.read_text(errors="replace").splitlines():
                    if line.startswith("#"):
                        head = line.lstrip("# ")[:70]
                        break
            except OSError:
                pass
            lines.append(f"{rel}  ({size} B)  {head}")
        return "\n".join(lines)

    def read_doc(self, name: str, max_chars: int = DOC_MAX_DEFAULT) -> str:
        cand = (self.base() / name).resolve()
        allowed = {str(p.relative_to(self.base())) for p in self.readable()}
        try:
            rel = str(cand.relative_to(self.base()))
        except ValueError:
            return f"refused: {name} is outside the repo"
        if rel not in allowed:
            return (f"refused: {rel} is not in the readable set "
                    "(README.md, AGENTS.md, tickets.md, docs/, decisions/, plans/)")
        try:
            body = cand.read_text(errors="replace")
        except OSError as e:
            return f"cannot read {rel}: {e}"
        if len(body) > max_chars:
            body = body[:max_chars] + (
                f"\n[... {len(body) - max_chars} chars omitted; ask for a section or raise max_chars]")
        return body

    def search_docs(self, query: str, max_hits: int = 12) -> str:
        q = query.lower()
        hits = []
        for p in self.readable():
            rel = p.relative_to(self.base())
            try:
                for i, line in enumerate(p.read_text(errors="replace").splitlines(), 1):
                    if q in line.lower():
                        hits.append(f"{rel}:{i}: {' '.join(line.split())[:140]}")
                        if len(hits) >= max_hits:
                            return "\n".join(hits) + f"\n[... capped at {max_hits} hits]"
            except OSError:
                continue
        return "\n".join(hits) if hits else f"nothing in the docs matches '{query}'"


def handle(req: dict, store: Tickets) -> dict:
    method = req.get("method")
    params = req.get("params") or {}
    rid = req.get("id")

    if method == "initialize":
        return {"jsonrpc": "2.0", "id": rid, "result": {
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": "chudmax-tickets", "title": "chudmax ticket inventory", "version": "0.1.0"},
            "instructions": "Read-only view of chudmax's ticket inventory and repo facts. "
                            "Call list_tickets first, then get_ticket for detail. Nothing here can "
                            "change a ticket's status; only a commit can.",
        }}
    if method in ("tools/list", "resources/list"):
        return {"jsonrpc": "2.0", "id": rid, "result": {"tools": TOOLS}}
    if method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        try:
            if name == "list_tickets":
                text = store.list_tickets()
            elif name == "get_ticket":
                text = store.get_ticket(args.get("id", ""),
                                        int(args.get("max_chars", MAX_CHARS_DEFAULT)))
            elif name == "search_tickets":
                text = store.search(args.get("query", ""))
            elif name == "repo_facts":
                text = store.repo_facts()
            elif name == "list_docs":
                text = store.list_docs()
            elif name == "read_doc":
                text = store.read_doc(args.get("name", ""), int(args.get("max_chars", DOC_MAX_DEFAULT)))
            elif name == "search_docs":
                text = store.search_docs(args.get("query", ""), int(args.get("max_hits", 12)))
            else:
                return {"jsonrpc": "2.0", "id": rid, "result": {
                    "content": [{"type": "text", "text": f"unknown tool: {name}"}], "isError": True}}
        except Exception as e:  # never kill the pipe; report the failure
            text = f"error: {type(e).__name__}: {e}"
        return {"jsonrpc": "2.0", "id": rid, "result": {"content": [{"type": "text", "text": text}]}}
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": f"method not supported: {method}"}}


def bearer_token(path: str) -> str | None:
    """Read the token file fresh on every request, so a Secret rotation needs no restart."""
    try:
        return Path(path).read_text(encoding="utf-8").strip()
    except OSError:
        return None


def serve_http(store: Tickets, host: str, port: int, token_file: str | None) -> int:
    """MCP over HTTP: the same dispatch as stdio, one request object per POST to /mcp."""

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _authorized(self) -> bool:
            if token_file is None:
                return True
            expected = bearer_token(token_file)
            got = (self.headers.get("Authorization") or "").removeprefix("Bearer ").strip()
            # Fail closed: an unreadable token file rejects everything; the compare is
            # constant-time so a timing side channel cannot walk the token space.
            return (expected is not None and expected != ""
                    and hmac.compare_digest(got.encode("utf-8"), expected.encode("utf-8")))

        def do_POST(self):
            if not self._authorized():
                self._json(401, {"jsonrpc": "2.0", "id": None,
                                 "error": {"code": -32001, "message": "unauthorized"}})
                return
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
            text = body.strip()
            req = None
            if text:
                first = text.splitlines()[0].strip()
                for cand in (first, text):  # one line as the stdio wire speaks it, else the whole body
                    try:
                        parsed = json.loads(cand)
                    except json.JSONDecodeError:
                        continue
                    if isinstance(parsed, dict):
                        req = parsed
                        break
            if req is None:
                self._json(400, {"jsonrpc": "2.0", "id": None,
                                 "error": {"code": -32700, "message": "parse error"}})
                return
            if "id" not in req:  # a notification: take it, answer nothing (streamable HTTP)
                # An empty body still needs framing: without Content-Length a keep-alive
                # HTTP/1.1 client reads until close and waits forever (curl hangs; the
                # selftest's urllib only escaped because it sends Connection: close).
                self.send_response(202)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            self._json(200, handle(req, store))

        def do_GET(self):
            data = b"MCP over HTTP: POST a JSON-RPC request to /mcp\n"
            self.send_response(405)
            self.send_header("Allow", "POST")
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _json(self, code: int, obj: dict):
            data = (json.dumps(obj) + "\n").encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *args):  # keep stdout to the one port line the selftest reads
            pass

    server = ThreadingHTTPServer((host, port), Handler)
    print(f"listening on {server.server_address[0]}:{server.server_address[1]}", flush=True)
    server.serve_forever()
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Read-only MCP server over chudmax's tickets.md")
    ap.add_argument("--tickets", default="tickets.md", help="path to the ticket file")
    ap.add_argument("--http", type=int, default=None, metavar="PORT",
                    help="serve MCP over HTTP on this port (0: pick a free port); "
                         "default: stdio only")
    ap.add_argument("--host", default="127.0.0.1", help="HTTP bind address")
    ap.add_argument("--data-root", default=None, metavar="DIR",
                    help="pod mode: reread DIR/current (tickets, docs, artifact.json) on every "
                         "call - the fetcher's volume contract; per call, no restarts")
    ap.add_argument("--bearer-token-file", default=None, metavar="PATH",
                    help="HTTP only: require 'Authorization: Bearer <token>' with the token "
                         "read from this file per request (rotation needs no restart); "
                         "fail-closed 401; stdio is unaffected")
    ap.add_argument("--revision", default=None,
                    help="pod mode: report this revision instead of asking git")
    ap.add_argument("--artifact-produced", default=None,
                    help="pod mode: when the artifact was produced")
    ap.add_argument("--artifact-unpacked", default=None,
                    help="pod mode: when the fetcher unpacked it")
    a = ap.parse_args()
    store = Tickets(tickets_path=None if a.data_root else Path(a.tickets),
                    data_root=Path(a.data_root) if a.data_root else None,
                    revision=a.revision,
                    artifact_produced=a.artifact_produced,
                    artifact_unpacked=a.artifact_unpacked)
    if a.http is not None:
        return serve_http(store, a.host, a.http, a.bearer_token_file)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        sys.stdout.write(json.dumps(handle(req, store)) + "\n")
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
