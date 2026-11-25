# Requirements: Evaluate MR 17 Kubernetes Plan Spike

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

MR !17 on `the private source-of-truth repo` (source branch `plan/kubernetes-home`, `verified-here` from the Helix mirror; the MR number itself is `handoff-reported` from the request — this node has no GitLab credentials) is a docs-only proposal: six plan files under `kubernetes/` (README, repo-sync, architecture, mcp, phases, personas), a proposed epic ticket T-0037, and one STATE.md count line. 561 insertions, no code. This task fetches it, evaluates it, runs the selftest, and produces a SPIKE — a plan about the plan. Nothing is built.

## User stories

1. **As the human**, I want MR !17 evaluated against the repo's own rules (selftest, epistemic labels, box-untouched, privacy) so I can decide whether to merge it.
2. **As the human**, I want a SPIKE that says how many separate tickets the plan needs (one per agent-sized part) so T-0037 can be carved up without re-deriving it later.
3. **As the human**, I want the execution order written down so the parts are made before they are put somewhere, per `phases.md`.
4. **As the human**, I want the human-only milestones listed (cluster access, keys, decisions) so I know where I am the blocker.
5. **As the human**, I want a high-level breakdown so I can read the whole shape of the work in one page.

## Acceptance criteria

- [ ] The six plan files and T-0037 are read and summarised with the repo's three labels (`verified-here`, `handoff-reported`, `speculation`).
- [ ] `python3 tools/mcp/selftest.py` is run and its result recorded — on `main` and on the MR branch.
- [ ] The spike states a ticket count, the execution order, the human milestones, and a high-level breakdown.
- [ ] The spike and the evaluation live in `design.md` in this task directory; pushed to `helix-specs`.
- [ ] Nothing is built: no manifests, no images, no tickets added to `chudmax/tickets.md`, no changes to the chudmax repo.

## Open Questions

1. **Ticket granularity:** I assumed one ticket per phase (1–18) plus one conditional the fork ticket for the web/engine split (18–19 total). The plan says "each phase gets its own ticket when it starts". Do you want any phase split further (phase 7 canary rehearsal is the largest), or merged (4+5 could be one)?
2. **Pre-creating tickets:** the plan creates each phase's ticket only when that phase starts. Should the spike's ticket list be pre-registered in `chudmax/tickets.md` after this task, or stay in the spike until each phase begins?
4. **CI capability:** the plan rehearses sync and canary on kind clusters inside CI (phases 5, 7, 8). The repo's `.gitlab-ci.yml` currently only includes the secret-detection template; whether the GitLab runners are privileged (able to run kind) is not addressed anywhere in the plan. Is that already known?
