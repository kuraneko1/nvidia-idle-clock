# Security policy

`nvidia-idle-clock` runs as root, on `multi-user.target`, and changes GPU clock
state through `nvidia-smi`. A defect can therefore do more than print a wrong
message: it can leave a device clamped (or release a clock lock that something
else depends on). Please report problems privately rather than in the tracker.

## Supported versions

Only the latest 0.2.x release line is supported. Earlier commits are kept for
reference and do not receive fixes.

| Version | Supported          |
| ------- | ------------------ |
| 0.2.x   | :white_check_mark: |
| < 0.2   | :x:                |

There is no long-term-support branch. If you are running a commit instead of a
release, reproduce the issue on the newest `main` before reporting.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting for this repository:

<https://github.com/kuraneko1/nvidia-idle-clock/security/advisories/new>

Do **not** open a public issue, a public PR, or a discussion for a suspected
vulnerability. A public report tells every user of a root daemon how to trigger
the bug before a fix is available.

If you cannot use GitHub Security Advisories, open a minimal public issue that
says only "I would like to report a security issue privately" — without
details — and a maintainer will reply with a channel.

This is a small, single-maintainer project: reports are handled on a
best-effort basis, with no guaranteed response time. Please include enough
information to reproduce the issue so a fix does not have to wait on a
round-trip.

## What to include in a report

The service is stateful — it holds a clock lock for as long as a GPU is idle —
so a report without the device state is usually not actionable.

- The version or commit: `git rev-parse HEAD` in your checkout, or the release
  tag.
- Full `nvidia-smi -q` output (redact the serial number and UUID if you prefer).
  In particular `Clocks`, `Clocks Event Reasons`, `Power Readings` and
  `Applications`. This shows whether an application clock lock was left behind
  and which process caused it.
- `systemctl cat 'nvidia-idle-clock@*'` — the unit plus any drop-ins, because
  `GPU=` and `IDLE_CAP=` overrides change the blast radius.
- `journalctl -u nvidia-idle-clock@0 --no-pager` around the incident. The log
  uses stable `key=value` fields (`level=`, `gpu=`, `msg=`, `min=`, `max=`,
  `observed_mhz=`) so lines can be grepped and pasted without editing.
- Distribution, kernel, NVIDIA driver version and systemd version.
- What an attacker or a non-root user could reach: is the failure reachable
  from a normal login, or does it require root already?

## Scope

In scope:

- Anything that lets a non-root user influence the daemon's decisions or the
  clock values it applies.
- A failure mode that leaves a GPU clamped after the service stops, or that
  releases a clock lock belonging to another tool.
- The installer and uninstaller: path handling, symlink following, ownership
  and permission checks, command injection through arguments or environment.
- Unit hardening regressions (`CapabilityBoundingSet`, `ProtectSystem`,
  `NoNewPrivileges`, and so on).

Out of scope:

- Defects in the NVIDIA driver or in `nvidia-smi` itself. Report those to
  NVIDIA; a wrapper here cannot fix them.
- The fact that the service runs as root. That is a documented requirement, not
  a vulnerability; suggestions for reducing privileges are welcome as normal
  feature requests.
- Anything that already requires root or physical access. Running commands as
  root is not an escalation.
- Support questions and "it did not save power on my GPU" reports — those are
  normal issues.

## Disclosure

Fixes are prepared in a private fork and published together with a GitHub
Security Advisory. Credit is given in the advisory unless you ask otherwise.
Please give the maintainer a reasonable window to ship a fix before publishing
details; for a single-maintainer project that is typically days, not months.
