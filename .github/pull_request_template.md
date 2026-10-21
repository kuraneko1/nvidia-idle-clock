# Summary

<!-- What changes, and why. One concern per PR. -->

## Related issues

<!-- Use "Fixes #N" so the issue closes on merge. If there is no issue, say why. -->

## Type of change

- [ ] Bug fix (non-breaking change which fixes an issue)
- [ ] New feature (non-breaking change which adds functionality)
- [ ] Breaking change (existing configuration or CLI behaviour changes)
- [ ] Documentation / tooling only

## Test plan

Paste the commands you ran and their result. The full list is in
[CONTRIBUTING.md](https://github.com/kuraneko1/nvidia-idle-clock/blob/main/CONTRIBUTING.md).

```bash
bash -n nvidia-idle-clock install.sh uninstall.sh
shellcheck -s bash -S warning nvidia-idle-clock install.sh uninstall.sh
bash tests/run.sh                       # if tests/ exists
systemd-analyze verify ./nvidia-idle-clock@0.service
```

GPU hardware used, if the change was exercised against a real device
(model and driver version), or "fake `nvidia-smi` only" otherwise:

## Checklist

- [ ] User-facing text (comments, log messages, installer output) is English.
- [ ] Log lines keep greppable `key=value` fields.
- [ ] No new runtime dependency beyond bash, coreutils, `nvidia-smi` and systemd.
- [ ] Behaviour changes are covered by `tests/run.sh` (or a note says why not).
- [ ] README / CHANGELOG updated if user-visible behaviour changed.
- [ ] If a new file was added, `.gitignore` has a matching `!` entry
      (the repository tracks an explicit whitelist; see CONTRIBUTING.md).
- [ ] Not a security fix — or, if it is, it was agreed through
      [SECURITY.md](https://github.com/kuraneko1/nvidia-idle-clock/blob/main/SECURITY.md)
      rather than in a public PR.
