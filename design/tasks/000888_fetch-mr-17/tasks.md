# Implementation Tasks: Evaluate MR 17 Kubernetes Plan Spike

> **Public mirror** — the full-fidelity record (including deployment specifics) lives in the private source-of-truth repo.

- [x] Fetch MR !17 and read the six plan files (README, repo-sync, architecture, mcp, phases, personas) and T-0037
- [x] Run `python3 tools/mcp/selftest.py` on `main` and on the MR branch (both PASS, exit 0)
- [x] Write the spike (ticket count, execution order, human milestones, breakdown) and the evaluation into `design.md`
- [x] Re-check the spike against GitLab directly once `a project-scoped credential` is in env (fresh session): MR !17 confirmed (opened, `plan/kubernetes-home` @ `d156ed0`, can be merged), fresh clone selftest PASS — Open Question 1 closed
- [ ] Do NOT build anything: no manifests, no images, no changes to `chudmax/` — the deliverable is this spike only
- [x] Deliver one part ahead of the ticket breakdown, per the human's request: **phase 1** — branch `feat/t0038-ticket-mcp-http` pushed to GitLab and opened as **MR !18** (HTTP transport + pod revision reporting + T-0038 ticket, selftest 19/19)
- [ ] Call `mark_task_complete` with the spike summary so the human can review
