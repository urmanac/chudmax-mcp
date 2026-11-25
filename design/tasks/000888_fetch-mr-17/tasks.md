# Implementation Tasks: Evaluate MR 17 Kubernetes Plan Spike

- [x] Fetch MR !17 and read the six plan files (README, repo-sync, architecture, mcp, phases, personas) and T-0037
- [x] Run `python3 tools/mcp/selftest.py` on `main` and on the MR branch (both PASS, exit 0)
- [x] Write the spike (ticket count, execution order, human milestones, breakdown) and the evaluation into `design.md`
- [ ] Re-check the spike against the latest state of `origin/plan/kubernetes-home` before closing (re-fetch; if the plan moved, update `design.md`)
- [ ] Do NOT build anything: no manifests, no images, no changes to `chudmax/` — the deliverable is this spike only
- [ ] Call `mark_task_complete` with the spike summary so the human can review
