# Contributing

Thanks for taking the time to help. This is a small project that touches GPU
clock state on machines other people depend on, so the bar is "small, correct,
reviewable" rather than "large and clever".

## What this project is

A bash daemon plus a systemd template unit that clamps the GPU clock while it is
idle and releases it when work arrives. It is not a scheduler, a wrapper, or a
replacement for `nvidia-smi`. Read `README.en.md` first — especially
"Behaviour" and "Notes" — so a change does not fight the mechanism that is
already measurable.

## Requirements for development

- bash 4.2 or newer
- coreutils
- `shellcheck` 0.9 or newer
- systemd (`systemd-analyze verify` for the unit)
- `nvidia-smi` for manual testing; **not** required for the test suite
- No GPU is needed to run the tests or the CI checks

## Getting started

```bash
git clone https://github.com/kuraneko1/nvidia-idle-clock.git
cd nvidia-idle-clock
git switch -c fix/short-description
```

## Checks to run before opening a PR

Run all of these from the repository root; CI runs the same commands.

```bash
# 1. Syntax
bash -n nvidia-idle-clock install.sh uninstall.sh

# 2. Lint — must be clean at warning level
shellcheck -s bash -S warning nvidia-idle-clock install.sh uninstall.sh

# 3. Tests — no GPU required, uses a fake nvidia-smi
bash tests/run.sh

# 4. Unit file
cp nvidia-idle-clock@.service /tmp/nvidia-idle-clock@0.service
systemd-analyze verify /tmp/nvidia-idle-clock@0.service

# 5. Whitespace
git diff --check
```

`tests/run.sh` exits non-zero on failure and prints a one-line summary. It is
plain bash with `assert_*` helpers — no bats, no test framework to install. The
fake `nvidia-smi` is injected through the `NVSMI` environment variable, so the
suite never touches real hardware. Please add a case for every behaviour change;
a fix without a regression test will usually be asked for one.

## Code style

- bash 4.2+, `set -uo pipefail`. Do not add `set -e`: the daemon has deliberate
  error handling and `-e` would bypass it.
- 2-space indentation, LF line endings, UTF-8. `.editorconfig` covers this.
- Quote every expansion. No `eval`, no `$(cat file)`, no unquoted globs.
- Comments are short and explain *why*, not *what*. English only.
- Log lines keep stable, greppable `key=value` fields and are English:

  ```
  level=info gpu=0 msg="clamped" min=135 max=135 idle_s=30 observed_mhz=135
  ```

  Use `level=error` for anything that needs attention and keep one event per
  line so the output can be grepped.
- Installer output and user-facing messages are English too.

## No new runtime dependencies

The daemon must run on a stock systemd host with nothing but bash, coreutils,
`nvidia-smi` and systemd. That constraint is deliberate: it is installed with
`install` into `/usr/local/sbin` and started as root, so every dependency is one
more thing that can be missing at boot.

`flock` and `logger` are allowed, but only if their absence degrades gracefully
(detect with `command -v`, fall back, log a warning) instead of failing the
unit. New build tooling is fine as long as it is never needed at runtime.

## Adding a new file

The repository uses an explicit whitelist in `.gitignore`:

```gitignore
/*
!/.gitignore
!/nvidia-idle-clock
...
```

This is not an accident. The checkout lives in a directory that is shared with
unrelated private projects, so "ignore everything, unignore what we ship" is the
only setting that cannot accidentally publish those files. The side effect is
that `git add .` silently skips a new file.

If you add a path, add a matching `!` entry in the same PR — directories with a
trailing slash (`!/docs/`), files without (`!/SECURITY.md`). Then confirm:

```bash
git check-ignore -v tests/run.sh   # should print nothing
git status --porcelain             # should show your new file
```

Do not replace the whitelist with a denylist. On a fresh clone it would look
fine and would be harmless, but it would expose unrelated files in the shared
working copy this repository is developed in.

## Commits

- One logical change per commit; keep style/formatting churn out of functional
  commits.
- Subject line in the imperative mood, prefixed with the area:

  ```
  script: keep the exit status when the trap fires
  systemd: wait for the driver before starting
  installer: refuse a partial install
  docs: correct the release latency
  ```

- Explain the *why* in the body; reference the issue (`Refs #12`) when one
  exists.
- Existing history is Japanese; new commits, comments and log output are
  English (see the English-output issue).

## Pull requests

- One concern per PR. If a fix needs a refactor, split it.
- Link the issue with `Fixes #N` when the PR closes it.
- Paste the commands you ran and their results in the PR body — including the
  "fake `nvidia-smi` only" note if you did not test on a real GPU.
- Say explicitly what you did *not* test. Untested paths are fine if they are
  named.
- Do not add reviewers, labels, or milestones; the maintainer sets those.
- Do not force-push a branch under review; add commits instead.

## Security issues

Do not open a public issue or PR for a vulnerability. Use
[SECURITY.md](SECURITY.md) — the private advisory route — and the maintainer
will handle it outside the normal review flow.

## License

Contributions are accepted under the MIT license, the same as the project
(see `LICENSE`). By opening a PR you agree that your contribution can be
distributed under those terms.
