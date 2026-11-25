#!/usr/bin/env python3
"""ticket_mcp_mock.py - the mock of chudmax's ticket server (T-0037 phase 4b).

The canonical server lives in the private repo (kingdonb/chudmax,
tools/mcp/ticket_mcp.py) with the real data. This mock is the public stand-in:
a fresh implementation of the same signatures, carrying none of the real data.
What "same signatures" means here, concretely:

- The seven read-only tools, with the same names, the same inputSchemas (the
  "default N" wording in the max_chars descriptions is part of the contract),
  and the same response shapes (text content blocks; an unknown tool is an
  isError result; a failed tool call becomes an "error: ..." text; an unknown
  method is JSON-RPC -32601; a notification gets no stdio reply).
- stdio transport: one JSON-RPC object per line in, one per line out; blank
  lines and unparsable lines are skipped with no reply.
- HTTP transport (--http PORT): POST (the documented path is /mcp) with one
  JSON-RPC object -> one JSON object back (200); a body that is not an object
  or not JSON -> 400 with -32700; a request without an id (a notification) ->
  202 with an empty body; GET -> 405 with Allow: POST. The process prints
  "listening on <host>:<port>" on stdout when it is up.
- The per-call volume contract: with --data-root DIR, every call rereads
  DIR/current (the fetcher sidecar's symlink) - tickets, docs, and the
  artifact.json that repo_facts reports. The fetcher swaps the symlink and
  prunes old revisions; a server that resolved the symlink once at startup
  would serve a stale (and eventually deleted) tree, so nothing is resolved
  ahead of a call here.
- The old flags (--tickets FILE, --revision R, --artifact-produced T,
  --artifact-unpacked T) stay accepted: fallbacks and overrides for a
  no-fetcher setup. --data-root wins when both are given.
- Optional bearer auth for the HTTP transport (--bearer-token-file PATH): the
  token file is read per request, so a Secret rotation needs no restart. With
  the flag set, every POST must carry "Authorization: Bearer <token>"; a
  missing, wrong, or unreadable token is a fail-closed 401. stdio is a local
  pipe and stays auth-free.

The fixture data bundled beside this file is invented for the mock; nothing
from the private repo's tickets is here. See fixture/README.md and the dir
README for what that means in practice.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SERVER_INFO_NAME = "chudmax-tickets"
SERVER_INFO_TITLE = "chudmax ticket inventory (mock)"
SERVER_VERSION = "0.1.0"
PROTOCOL_VERSION = "2024-11-05"

TICKET_RE = re.compile(r"^## (T-\d{4}) - (.+?)\s*$", re.MULTILINE)
FIELD_RE = re.compile(
    r"^\*\*(Status|Owner|Priority|Due|Tags|Depends on|Coordination):\*\*\s*(.*)$",
    re.MULTILINE,
)
PURPOSE_RE = re.compile(r"\*\*Purpose:\*\*\s*(.+?)(?=\n\*\*|\n---)", re.DOTALL)

MAX_CHARS_DEFAULT = 3000
HEAD_SHARE = 0.4  # of a trimmed ticket, the share kept from its start; the rest from its end
DOC_MAX_DEFAULT = 1500
SEARCH_HIT_DEFAULT = 12

READABLE_TOP = ("README.md", "AGENTS.md", "tickets.md")
READABLE_DIRS = ("docs", "decisions", "plans")


def trim_middle(text: str, max_chars: int) -> str:
    """Keep ~max_chars of a ticket: its start and its end, cut at line breaks, with a note.

    Tickets are diaries: the head carries title/status/purpose, the tail carries the
    latest entries - a cut that kept only the head once reported a closed ticket as
    still blocked. The note names the max_chars that returns everything.
    """
    if len(text) <= max_chars:
        return text
    head_n = int(max_chars * HEAD_SHARE)
    tail_n = max_chars - head_n
    head = text[:head_n]
    if "\n" in head:
        head = head[: head.rfind("\n")]
    tail = text[len(text) - tail_n:]
    if "\n" in tail:
        tail = tail[tail.find("\n") + 1:]
    omitted = len(text) - len(head) - len(tail)
    note = (
        f"\n[... {omitted} chars omitted from the middle; the start and the latest entries are kept. "
        f"max_chars={len(text)} returns all of it]\n"
    )
    return head + note + tail


def trim_tail(text: str, max_chars: int) -> str:
    """Keep the first max_chars of a doc, cut with a note. Docs read top-down."""
    if len(text) <= max_chars:
        return text
    return text[:max_chars] + (
        f"\n[... {len(text) - max_chars} chars omitted; ask for a section or raise max_chars]"
    )


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
        "description": "What the repo contains, and how old this checkout is: branch, sha, last commit, ahead/behind vs its remote. In pod mode (the server was started with --data-root) it reports the facts the fetcher recorded in artifact.json, reread through the current symlink on every call. Read this before quoting anything as current.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "list_docs",
        "description": "The documentation index: docs/, decisions/, plans/, README, AGENTS. One line each with size.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "read_doc",
        "description": "Read one doc by name (e.g. 'docs/example-architecture.md'). Only files in docs/, decisions/, plans/, README.md, AGENTS.md, tickets.md are readable. Truncated by default so a chat context does not balloon.",
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


class MockStore:
    """Reads the ticket file and the docs per call; never caches a path it resolved."""

    def __init__(self, tickets_path: Path, data_root: Path | None = None,
                 revision: str | None = None, artifact_produced: str | None = None,
                 artifact_unpacked: str | None = None):
        self.tickets_path = tickets_path  # opened per call; never resolved at startup
        self.data_root = data_root        # pod mode: <root>/current is the tree
        self.revision = revision          # fallback facts, when no fetcher handed us a volume
        self.artifact_produced = artifact_produced
        self.artifact_unpacked = artifact_unpacked
        self.git_root = self._find_git_root(tickets_path)

    @staticmethod
    def _find_git_root(path: Path) -> Path | None:
        for parent in [path.parent, *path.parents]:
            if (parent / ".git").exists():
                return parent
        return None

    def base(self) -> Path:
        """The tree a call reads from. In pod mode the symlink path itself - a swap is
        picked up on the very next call."""
        if self.data_root is not None:
            return self.data_root / "current"
        return self.tickets_path.parent

    def label(self) -> str:
        if self.data_root is not None:
            return str(self.data_root / "current")
        return str(self.tickets_path)

    def readable(self) -> list[Path]:
        base = self.base()
        found = [base / name for name in READABLE_TOP if (base / name).is_file()]
        for sub in READABLE_DIRS:
            if (base / sub).is_dir():
                found.extend(sorted((base / sub).rglob("*.md")))
        return found

    def ticket_text(self) -> str:
        # Pod mode reads <current>/tickets.md; the bundled file is the no-fetcher mode.
        path = (self.base() / "tickets.md") if self.data_root is not None else self.tickets_path
        try:
            return path.read_text(encoding="utf-8")
        except OSError:
            return ""

    def parse_tickets(self) -> list[dict]:
        body = self.ticket_text()
        heads = list(TICKET_RE.finditer(body))
        out = []
        for i, m in enumerate(heads):
            end = heads[i + 1].start() if i + 1 < len(heads) else len(body)
            block = body[m.start():end]
            fields = {k.lower(): v.strip() for k, v in FIELD_RE.findall(block)}
            purpose = PURPOSE_RE.search(block)
            out.append({"id": m.group(1), "title": m.group(2), "fields": fields,
                        "block": block,
                        "purpose": " ".join(purpose.group(1).split()) if purpose else ""})
        return out

    def count_by_status(self) -> dict:
        counts: dict = {}
        for t in self.parse_tickets():
            key = t["fields"].get("status", "?")
            counts[key] = counts.get(key, 0) + 1
        return counts

    # --- the seven tools -----------------------------------------------------

    def list_tickets(self) -> str:
        tickets = self.parse_tickets()
        if not tickets:
            return f"no tickets found in {self.label()}"
        lines = [f"{t['id']}  {t['fields'].get('status', '?'):12}  "
                 f"{t['fields'].get('priority', '?'):6}  {t['title']}" for t in tickets]
        return "\n".join(lines)

    def get_ticket(self, tid: str, max_chars: int = MAX_CHARS_DEFAULT) -> str:
        for t in self.parse_tickets():
            if t["id"].lower() == tid.lower():
                return trim_middle(t["block"], max_chars)
        return f"no ticket {tid} in {self.label()}"

    def search_tickets(self, query: str) -> str:
        needle = query.lower()
        hits = []
        for t in self.parse_tickets():
            if needle in t["block"].lower():
                snippet = next((" ".join(line.split())[:160] for line in t["block"].splitlines()
                                if needle in line.lower()), "")
                hits.append(f"{t['id']}  {t['fields'].get('status', '?')}  {t['title']}\n    {snippet}")
        return "\n".join(hits) if hits else f"no ticket matches '{query}'"

    def repo_facts(self) -> str:
        by_status = f"tickets by status: {json.dumps(self.count_by_status(), sort_keys=True)}\n"
        if self.data_root is not None:
            try:
                meta = json.loads(
                    (self.data_root / "current" / "artifact.json").read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as e:
                return (f"artifact facts: none yet ({type(e).__name__} reading "
                        f"{self.label()}/artifact.json)\n" + by_status +
                        "source: the fetcher has not swapped an artifact beside this tree yet; "
                        "no git was asked\n")
            lines = [f"url: {meta.get('url', 'unknown')}",
                     f"revision: {meta.get('revision', 'unknown')}",
                     f"digest: {meta.get('digest', 'unknown')}",
                     f"artifact produced: {meta.get('produced', 'unknown')}",
                     f"artifact unpacked: {meta.get('unpacked', 'unknown')}",
                     f"source: {meta.get('source', 'unknown')}"]
            if meta.get("origin_revision"):
                lines.append(f"origin revision: {meta['origin_revision']}")
            return ("\n".join(lines) + "\n" + by_status +
                    "source: artifact.json beside the tree, reread through the current symlink "
                    "on every call; no git was asked\n")
        if self.revision is not None:
            return (f"revision: {self.revision}\n"
                    f"artifact produced: {self.artifact_produced or 'unknown'}\n"
                    f"artifact unpacked: {self.artifact_unpacked or 'unknown'}\n"
                    + by_status +
                    "source: the revision this server was given; no git was asked\n")

        # No fetcher, no handed revision: ask git about the checkout (the box's mode).
        def run(cmd: list) -> str | None:
            if self.git_root is None:
                return None
            try:
                p = subprocess.run(cmd, cwd=self.git_root, capture_output=True, text=True,
                                   timeout=10)
                return p.stdout.strip() if p.returncode == 0 else None
            except Exception:
                return None

        out = (f"checkout: branch={run(['git', 'rev-parse', '--abbrev-ref', 'HEAD']) or 'unknown'} "
               f"sha={run(['git', 'rev-parse', '--short', 'HEAD']) or 'unknown'} "
               f"last commit={run(['git', 'log', '-1', '--format=%ad', '--date=short']) or 'unknown'}\n"
               + by_status)
        files = run(["git", "ls-files"])
        if files is None:
            out += (f"note: {self.label()} is not inside a git working tree, so repo facts are "
                    "unavailable here. Ticket counts still reflect the file as read.")
            return out
        out += (f"tracked files: {len(files.splitlines())}\n"
                f"recent commits:\n{run(['git', 'log', '--oneline', '-8']) or '(none)'}")
        behind = run(["git", "rev-list", "--count", "HEAD..@{upstream}"])
        ahead = run(["git", "rev-list", "--count", "@{upstream}..HEAD"])
        if behind is not None and ahead is not None:
            out += f"\nvs its remote tracking branch: {behind} behind, {ahead} ahead"
            if behind != "0":
                out += "  <- BEHIND: treat anything quoted here as stale"
        else:
            out += "\nno upstream tracking configured for this branch"
        return out

    def list_docs(self) -> str:
        docs = self.readable()
        if not docs:
            return "no readable docs under docs/, decisions/, plans/"
        lines = []
        base = self.base()
        for p in docs:
            try:
                rel = str(p.relative_to(base))
            except ValueError:
                continue
            try:
                size = p.stat().st_size
            except OSError:
                size = 0
            heading = ""
            try:
                for line in p.read_text(errors="replace").splitlines():
                    if line.startswith("#"):
                        heading = line.lstrip("# ")[:70]
                        break
            except OSError:
                pass
            lines.append(f"{rel}  ({size} B)  {heading}")
        return "\n".join(lines)

    def read_doc(self, name: str, max_chars: int = DOC_MAX_DEFAULT) -> str:
        base = self.base()
        candidate = (base / name).resolve()
        allowed = {str(p.relative_to(base)) for p in self.readable()}
        try:
            rel = str(candidate.relative_to(base))
        except ValueError:
            return f"refused: {name} is outside the readable tree"
        if rel not in allowed:
            return (f"refused: {rel} is not in the readable set "
                    "(README.md, AGENTS.md, tickets.md, docs/, decisions/, plans/)")
        try:
            body = candidate.read_text(errors="replace")
        except OSError as e:
            return f"cannot read {rel}: {e}"
        return trim_tail(body, max_chars)

    def search_docs(self, query: str, max_hits: int = SEARCH_HIT_DEFAULT) -> str:
        needle = query.lower()
        hits = []
        base = self.base()
        for p in self.readable():
            try:
                rel = str(p.relative_to(base))
            except ValueError:
                continue
            try:
                for i, line in enumerate(p.read_text(errors="replace").splitlines(), 1):
                    if needle in line.lower():
                        hits.append(f"{rel}:{i}: {' '.join(line.split())[:140]}")
                        if len(hits) >= max_hits:
                            return "\n".join(hits) + f"\n[... capped at {max_hits} hits]"
            except OSError:
                continue
        return "\n".join(hits) if hits else f"nothing in the docs matches '{query}'"


def call_tool(store: MockStore, name: str, args: dict) -> str:
    """The one place tool names meet implementations; unknown names raise KeyError."""
    if name == "list_tickets":
        return store.list_tickets()
    if name == "get_ticket":
        return store.get_ticket(args.get("id", ""), int(args.get("max_chars", MAX_CHARS_DEFAULT)))
    if name == "search_tickets":
        return store.search_tickets(args.get("query", ""))
    if name == "repo_facts":
        return store.repo_facts()
    if name == "list_docs":
        return store.list_docs()
    if name == "read_doc":
        return store.read_doc(args.get("name", ""), int(args.get("max_chars", DOC_MAX_DEFAULT)))
    if name == "search_docs":
        return store.search_docs(args.get("query", ""), int(args.get("max_hits", SEARCH_HIT_DEFAULT)))
    raise KeyError(name)


def dispatch(req: dict, store: MockStore) -> dict:
    """One JSON-RPC object in, one out. Shared by the stdio and HTTP transports."""
    method = req.get("method")
    params = req.get("params") or {}
    rid = req.get("id")

    if method == "initialize":
        return {"jsonrpc": "2.0", "id": rid, "result": {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": SERVER_INFO_NAME, "title": SERVER_INFO_TITLE,
                           "version": SERVER_VERSION},
            "instructions": "Read-only view of the chudmax ticket inventory and repo facts; this "
                            "instance serves the mock fixture. Call list_tickets first, then "
                            "get_ticket for detail. Nothing here can change a ticket's status; "
                            "only a commit can.",
        }}
    if method in ("tools/list", "resources/list"):
        return {"jsonrpc": "2.0", "id": rid, "result": {"tools": TOOLS}}
    if method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        try:
            text = call_tool(store, name, args)
        except KeyError:
            return {"jsonrpc": "2.0", "id": rid, "result": {
                "content": [{"type": "text", "text": f"unknown tool: {name}"}], "isError": True}}
        except Exception as e:  # a broken tool call must never kill the pipe
            text = f"error: {type(e).__name__}: {e}"
        return {"jsonrpc": "2.0", "id": rid, "result": {"content": [{"type": "text", "text": text}]}}
    return {"jsonrpc": "2.0", "id": rid,
            "error": {"code": -32601, "message": f"method not supported: {method}"}}


def parse_request_line(line: str) -> dict | None:
    """The stdio wire is one object per line; anything else is not a request."""
    line = line.strip()
    if not line:
        return None
    try:
        parsed = json.loads(line)
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, dict) else None


def serve_stdio(store: MockStore) -> int:
    for line in sys.stdin:
        req = parse_request_line(line)
        if req is None:
            continue
        sys.stdout.write(json.dumps(dispatch(req, store)) + "\n")
        sys.stdout.flush()
    return 0


def bearer_token(path: str) -> str | None:
    """Read the token file fresh on every request, so rotation needs no restart."""
    try:
        return Path(path).read_text(encoding="utf-8").strip()
    except OSError:
        return None


def serve_http(store: MockStore, host: str, port: int, token_file: str | None) -> int:
    """MCP over HTTP: one JSON-RPC object per POST (the documented path is /mcp)."""

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _reply(self, code: int, body: bytes, content_type: str) -> None:
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _json(self, code: int, obj: dict) -> None:
            self._reply(code, (json.dumps(obj) + "\n").encode(), "application/json")

        def _authorized(self) -> bool:
            if token_file is None:
                return True
            expected = bearer_token(token_file)
            got = (self.headers.get("Authorization") or "").removeprefix("Bearer ").strip()
            # Fail closed: an unreadable token file rejects everything.
            return expected is not None and expected != "" and got == expected

        def do_POST(self) -> None:
            if not self._authorized():
                self._json(401, {"jsonrpc": "2.0", "id": None,
                                 "error": {"code": -32001, "message": "unauthorized"}})
                return
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
            text = body.strip()
            req = None
            if text:
                for candidate in (text.splitlines()[0].strip(), text):
                    try:
                        parsed = json.loads(candidate)
                    except json.JSONDecodeError:
                        continue
                    if isinstance(parsed, dict):
                        req = parsed
                        break
            if req is None:
                self._json(400, {"jsonrpc": "2.0", "id": None,
                                 "error": {"code": -32700, "message": "parse error"}})
                return
            if "id" not in req:  # a notification: taken, answered with nothing
                self._reply(202, b"", "application/json")
                return
            self._json(200, dispatch(req, store))

        def do_GET(self) -> None:
            self.send_response(405)
            self.send_header("Allow", "POST")
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", "46")
            self.end_headers()
            self.wfile.write(b"MCP over HTTP: POST a JSON-RPC request to /mcp\n")

        def log_message(self, *args) -> None:  # stdout stays to the port line
            pass

    server = ThreadingHTTPServer((host, port), Handler)
    print(f"listening on {server.server_address[0]}:{server.server_address[1]}", flush=True)
    server.serve_forever()
    return 0


def main() -> int:
    here = Path(__file__).resolve().parent
    ap = argparse.ArgumentParser(description="Mock of chudmax's read-only ticket MCP server")
    ap.add_argument("--tickets", default=str(here / "fixture" / "tickets.md"),
                    help="path to the ticket file (default: the bundled mock fixture)")
    ap.add_argument("--http", type=int, default=None, metavar="PORT",
                    help="serve MCP over HTTP on this port (0: pick a free port); default: stdio")
    ap.add_argument("--host", default="127.0.0.1", help="HTTP bind address")
    ap.add_argument("--data-root", default=None, metavar="DIR",
                    help="pod mode: reread DIR/current (tickets, docs, artifact.json) on every "
                         "call - the fetcher's volume contract; per call, no restarts")
    ap.add_argument("--bearer-token-file", default=None, metavar="PATH",
                    help="HTTP only: require 'Authorization: Bearer <token>' with the token read "
                         "from this file per request (rotation needs no restart); fail-closed")
    ap.add_argument("--revision", default=None,
                    help="no-fetcher fallback: report this revision instead of asking git")
    ap.add_argument("--artifact-produced", default=None,
                    help="no-fetcher fallback: when the artifact was produced")
    ap.add_argument("--artifact-unpacked", default=None,
                    help="no-fetcher fallback: when it was unpacked")
    a = ap.parse_args()
    store = MockStore(tickets_path=Path(a.tickets),
                      data_root=Path(a.data_root) if a.data_root else None,
                      revision=a.revision, artifact_produced=a.artifact_produced,
                      artifact_unpacked=a.artifact_unpacked)
    if a.http is not None:
        return serve_http(store, a.host, a.http, a.bearer_token_file)
    return serve_stdio(store)


if __name__ == "__main__":
    sys.exit(main())
