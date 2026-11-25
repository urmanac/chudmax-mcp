# Design: Evaluate MR 17 Kubernetes Plan Spike

This document is the SPIKE itself: the evaluation of MR !17 and the plan-about-the-plan for T-0037. Nothing here is built. Labels follow `chudmax/AGENTS.md`.

## 1. What MR !17 is (`verified-here` from the mirror branch, re-verified against GitLab)

- **MR !17 confirmed via the GitLab API** (2026-11-25, project secret `GITLAB_SECRET_TOKEN`, Maintainer): iid 17, "Plan: chudmax's home, with Flux keeping the repo current (T-0037)", state `opened`, not draft, `source_branch: plan/kubernetes-home` → `main`, head `d156ed0`, `can_be_merged`, no conflicts. A fresh clone of `gitlab.com/kingdonb/chudmax` has `main` at `70c397e` and `plan/kubernetes-home` at `d156ed0` — byte-identical to what the mirror served before it was detached. Selftest re-run on the MR head from the fresh clone: all checks PASS, exit 0.

- Source branch `plan/kubernetes-home`, three commits ending at `d156ed0` "Kubernetes plan, third pass: no cluster now, parts first, MetalLB address (T-0037)".
- Diff vs `main`: six new files in `kubernetes/` (README 107, repo-sync 98, architecture 158, mcp 79, phases 57, personas 32 lines), T-0037 appended to `tickets.md` (+29, making 37 tickets), one STATE.md count line. Docs only — `tools/` untouched.
- The plan's own spine: the reason for Kubernetes is that Flux fetches and caches the repo so the ticket server stops depending on a hand-run `git pull` (settles T-0023's "until Flux does it", T-0024 freshness, T-0027 scheduled sync). Around it: web/engine/mcp three-way split, Flagger canary on the web harness, image automation, our own Hermes chart, MetalLB floating address, and `personas.md` so chudmax runs his own deployment afterwards.
- Hard constraints the plan commits to: no cluster now; the box is untouched (engine stays on the host; the one exception is phase 14's single edit + restart by the human); Flux syncs `main` only; every image arm64+amd64 from the first build; `k8s/` here is a workbench, publishing happens elsewhere (repos `urmanac/chudmax-engine|web|mcp`, packages `ghcr.io/urmanac/chudmax/*`); the ticket server is published as a credential-free-pullable image, nothing more; the repo stays private (`decisions/0007`).

## 2. Selftest result

- `python3 tools/mcp/selftest.py` on `main` (`70c397e`): **all 11 checks PASS**, exit 0 (`verified-here`, run on this node 2026-11-25).
- Same command in a throwaway worktree of the MR branch (`d156ed0`): **all 11 checks PASS**, exit 0, ticket count 37 vs 37 (`verified-here`). The MR cannot break the server because it does not touch `tools/`.

## 3. Evaluation

**Recommendation: merge after your review.** Reasons:

- Docs-only, selftest-clean, and it does not touch the box or the tool surface.
- It follows the repo's epistemic rule line by line; every design guess is labeled `speculation` and is assigned to a phase that will answer it.
- The phasing is honest: "make the parts" needs no cluster of ours, and nothing is put somewhere until the human names a cluster. The plan cannot strand work halfway.
- Privacy is respected: publishing happens in the `urmanac` repos; the tickets and this repo stay private.

**Weak spots to watch (none blocks the plan; each is a phase's homework):**

| Weak spot | Where the plan answers it | My note |
|---|---|---|
| `ArtifactGenerator` copy rules may not fit the narrowed-artifact idea (`speculation` in `repo-sync.md`) | Phase 4; fallback is `ignore`-rule narrowing | Sound fallback, no dead end |
| Cozystack's Flux version/controllers unknown; mTLS needs Flux 2.10 + k8s 1.35 | Phase 12 answers; phase 17 defers mTLS | Correctly deferred, not assumed |
| Webhook ingress path (DMZ vs Tailscale Funnel vs relay vs 1-minute interval) | Open item 2, `repo-sync.md` table | Deliberately loose; fine for now |
| Web/engine split route (fork change vs fork's `app/host` vs thin front) | Phase 15; `architecture.md` lists three ways | The one real engineering risk; route choice is a human decision |
| Secrets mechanism (SOPS / External Secrets) | Open item 6 | Human decision |
| CI must run kind clusters for rehearsals (phases 5, 7, 8) | **Not addressed in the plan** (`speculation`, mine) | Privileged GitLab runners or self-hosted k3d needed; check before phase 5 |

## 4. SPIKE part 1 — how many tickets

**19 tickets: 10 for the parts, 8 for placement, 1 conditional Strata-fork ticket.** One per phase, created when the phase starts (the plan's own rule); T-0037 stays the epic until the last phase closes.

**Make the parts (10, no cluster needed):**

| # | Phase | Ticket subject | Depends on |
|---|---|---|---|
| A | 1 | `ticket_mcp.py` serves MCP over HTTP + revision reporting; selftest covers both modes | — |
| B | 2 | Fetcher sidecar (verify, unpack, symlink-swap); tarball test in CI | — |
| C | 3 | mcp image (arm64+amd64) + chart (Deployment, Role, NetworkPolicies) | A, B |
| D | 4 | `k8s/repo-sync/` manifests (GitRepository, ArtifactGenerator, Receiver, Alerts) | C |
| E | 5 | Kind rehearsal of the sync in CI: commit → `list_tickets`; policy denial proof | C, D |
| F | 6 | Engine + web charts, umbrella; installs on kind | C |
| G | 7 | Canary rehearsal: promote + forced-rollback recorded in CI | F |
| H | 8 | Image automation rehearsal: tag → review-branch commit | F |
| I | 9 | Hermes chart; volume survives pod delete; restore works | F |
| J | 10 | Publishing handoff: repos, CI build/sign/push, `flux mirror` config | A–I |

**Put them somewhere (8, each gated on the human's cluster):**

| # | Phase | Ticket subject | Depends on |
|---|---|---|---|
| K | 11 | Pod reaches the engine through the engine Service | J, cluster named |
| L | 12 | Flux syncs this repo's `main` for real; platform inventory | K |
| M | 13 | Gateway holds a MetalLB floating IP; survives pod move and node loss | L |
| N | 14 | Cutover: engine registers `chudmax-tickets` by `url` (human's one edit) | M |
| O | 15 | Canary against the real engine | N, and S or the chosen route |
| P | 16 | Hermes beside it, answering from chudmax's model | M |
| Q | 17 | mTLS when the platform's Flux is 2.10 | L |
| R | 18 | Handover: chudmax carries one release; he proposes tickets thereafter | all |

**Conditional:** **S — web/engine split in the Strata fork** (the harness attaches to an engine at a URL instead of starting one; a brief for the fork's agent). Only created if route A is chosen at phase 15; routes B (`app/host`) or C (thin front) would spawn their own single ticket instead.

## 5. SPIKE part 2 — execution order

`phases.md`'s two halves, in order; nothing from the second half starts before the first is done:

```
Make the parts:   A ∥ B → C → D → E → F → G → H  (I parallel with G/H) → J
Put them somewhere (human names a cluster):
                  K → L → M → N → O → P → Q → R
```

- A and B are independent; start both together.
- C is the join point; D, E, F fan out after it.
- I (Hermes) can run in parallel with G/H — it touches neither.
- J last of the parts; it publishes what the others made.
- On the cluster side the numbers are the order: 11 reach the engine, 12 live sync, 13 stable address, 14 cutover (the box's single change), 15 canary, 16 Hermes (can parallel O after M), 17 mTLS (waits on the platform's Flux), 18 handover.

## 6. SPIKE part 3 — milestones that need the human

| Milestone | Where | What the human does |
|---|---|---|
| Approve the plan | merge of MR !17 | The decision that starts everything |
| Gate to the second half | before K (11) | Name the first cluster; grant access (kubeconfig); walk the platform inventory (Cozystack's Flux version, controllers, MetalLB) |
| CI capability | before E (5) | Provide privileged runners (or self-hosted k3d) able to run kind — not addressed in the plan |
| Publishing | J (10) | Create `urmanac/chudmax-engine`, `-web`, `-mcp` and the Hermes repo; ghcr.io write rights; cosign keyless workflow; name the hermes repo (plan leaves it "the human's to name") |
| Keys and tokens | L (12) | Read-only GitLab deploy key with pinned host key; Receiver webhook token |
| Webhook path decision | L (12) | DMZ address vs Tailscale Funnel vs relay vs interval-only; OIDC-webhook idea |
| The one box change | N (14) | Edit the engine's install record to register the ticket server by `url`; restart the engine |
| Web/engine split route | O (15) | Choose A (fork change), B (`app/host`), or C (thin front) |
| Secrets mechanism | before first real deploy | SOPS vs External Secrets vs Cozystack's offering (open item 6) |
| Every release | ongoing | Merge the image-update review branch Flux opens (automation never pushes `main`) |
| mTLS turn-on | Q (17) | Approve when the platform's Flux is 2.10 |
| Handover | R (18) | Accept: chudmax carries one release; he proposes tickets from then on |

## 7. SPIKE part 4 — high-level breakdown

- **Half 1 — make the parts (no cluster):** ticket server gains HTTP mode + Flux revision reporting; a small fetcher sidecar; one mcp image + chart; repo-sync Flux manifests; then three rehearsals in CI (sync, canary, image automation); Hermes chart; publishing handoff.
- **Half 2 — put them somewhere (human names a cluster):** reach the host engine through a pointer Service; Flux syncs `main` for real; MetalLB floating address; cutover of the ticket server (the box's single edit); canary against the real engine (needs the split route); Hermes beside it; mTLS when the platform allows; chudmax takes over.
- **Cross-cutting rules:** box untouched except phase 14; podman before cluster; nothing compiled on the box; CI builds both architectures; `main` only, everything reviewed; proof recorded with the three labels.
- **Two problems the plan deliberately leaves loose:** the webhook's way in, and the web/engine split. Everything else has a decided answer or a phase that will answer it.

## 8. Notes for future agents (learnings)

- **Access changed on 2026-11-25 (mid-task):** the GitLab connector was disabled and the repo detached from Helix metadata — the Helix mirror (`origin` at `helix-api.internal:18080`) now answers `403 Access denied` (`verified-here`). Direct GitLab is the path now: a project secret `GITLAB_SECRET_TOKEN` (scopes per the `helix cloud` token: `api, self_rotate, write_repository`, Maintainer) is registered on project `prj_01m69kzv94q3kvr5tpqts2bsda` and is injected into sessions at container creation. **A session started before the secret exists never sees it** — if `printenv GITLAB_SECRET_TOKEN` is empty, a fresh session is required. Use it per-command (`oauth2:$GITLAB_SECRET_TOKEN@gitlab.com/...` for git, `PRIVATE-TOKEN:` header for the API); never write it to disk or into a doc.
- The evaluation's evidence base predates the detach and is intact in the local checkout: `origin/plan/kubernetes-home` at `d156ed0` and `main` at `70c397e`, fetched from the mirror before it closed. The next session with GitLab access should re-verify MR !17's head against GitLab itself (`GET /api/v4/projects/kingdonb%2Fchudmax/merge_requests/17`).
- `selftest.py` derives both ticket counts from `tickets.md` itself, so a docs-only MR that adds a ticket still passes; run it against the MR branch in a `git worktree` to prove it without touching the checkout.
- The plan's phase list in `phases.md` is already ticket-sized (one agent ticket per phase, with A/B parallelizable and I parallelizable); only the conditional fork ticket is an addition the plan implies but does not number.

### The working GitLab recipe (learned 2026-11-25, `verified-here`)

- The credential is the project secret `GITLAB_SECRET_TOKEN` = the rotated `helix cloud` project access token (scopes `api, self_rotate, write_repository`, Maintainer, expires 2026-12-25; the superseded one expires 2026-11-30). It is **injected at container creation only** — a session started before the secret existed never sees it; check `printenv GITLAB_SECRET_TOKEN`, and if empty, restart the session.
- **API:** `curl -s -H "PRIVATE-TOKEN: $GITLAB_SECRET_TOKEN" https://gitlab.com/api/v4/projects/kingdonb%2Fchudmax/...` — project, MRs, access-token metadata (names/scopes only, values are write-only) all work.
- **Git over HTTPS** needs the token as the password with **any** username, via a runtime credential helper (keeps the token out of argv-at-rest and off disk entirely):
  ```
  git -c "credential.helper=!f() { echo username=oauth2; printf 'password=%s\n' \"\$GITLAB_SECRET_TOKEN\"; }; f" \
      clone https://gitlab.com/kingdonb/chudmax.git <dir>
  ```
  The same `-c` prefix works for `push` to an explicit GitLab URL. The `!f() { ... }; f` wrapper is required — a bare `!echo` helper fails (git gets no `username=` line and reports a misleading auth error).
- **The Helix mirror is dead** since the detach (`origin` → `403 Access denied` for fetch and push). Push `helix-specs` and feature branches directly to `https://gitlab.com/kingdonb/chudmax.git`. After the detach, `chudmax` also stopped registering as a project worktree: file tools (`read_file`/`edit_file`/`write_file`) only reach `helix-specs` and `incoming`; operate on the code repos with `git -C` and terminal commands, staging file edits through `incoming` scripts if needed.
- A GitLab-wide commit-msg hook in this container enforces conventional commits (`feat(mcp): ...`) on **every** repo, including chudmax, whose own history predates the hook and does not follow it.
- **Phase 1 was delivered from this session** (`verified-here`): branch `feat/t0038-ticket-mcp-http` (stacked on MR !17's head), pushed and opened as **MR !18** — `ticket_mcp.py --http` (MCP over HTTP: JSON object per POST to `/mcp`, 202/405/400 semantics) plus pod mode (`--revision`, `--artifact-produced`, `--artifact-unpacked`; `repo_facts` stops asking git), selftest covering both transports (19 checks, all PASS), ticket T-0038 marked done in `tickets.md`, STATE.md count line 38/22-done. **The Chief of Staff's list is therefore 18 tickets, not 19** — phase 1 is already merged-adjacent; only its review/merge remains. Whether the fork's hub accepts the server by `url` is still `speculation` — it is checked on the box at phase 12/14.
- The plan uses "the box" = the Ubuntu host with the RTX GPU (Strata engine on `:8080`), "the cluster" = wherever Flux runs; the engine chart is a selectorless Service + EndpointSlice pointing at `10.17.12.202:8080`.
