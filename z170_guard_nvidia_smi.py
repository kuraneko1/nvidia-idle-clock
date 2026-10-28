#!/usr/bin/python3
"""Constrain nvidia-idle-clock nvidia-smi calls to verified physical V100s."""
import os
import subprocess
import sys

REAL = '/usr/bin/nvidia-smi'
ALLOWED = {
    'GPU-95283591-83a0-dfef-b9ff-e9e601e3d593': ('Tesla V100-PCIE-32GB', '0x1DB610DE'),
    'GPU-450167d4-8564-727d-8a97-232f720b0d23': ('Tesla PG500-216', '0x1DF010DE'),
}


def guarded_args(args, gpu, query):
    """Fail closed; rewrite exactly one selector to the confirmed UUID."""
    if gpu not in ALLOWED:
        raise ValueError('GPU is not an approved V100 UUID')
    result = query([REAL, '-i', gpu, '--query-gpu=index,uuid,name,pci.device_id',
                    '--format=csv,noheader,nounits'], capture_output=True, text=True,
                   timeout=5, check=True)
    rows = result.stdout.splitlines()
    fields = [v.strip() for v in rows[0].split(',')] if len(rows) == 1 else []
    if len(fields) != 4 or not fields[0].isdigit() or fields[1] != gpu or tuple(fields[2:]) != ALLOWED[gpu]:
        raise ValueError('GPU identity or model mismatch')
    out = list(args)
    selectors = [i for i, arg in enumerate(out) if arg in ('-i', '--id')]
    if any(arg.startswith(('--id=', '-i=')) for arg in out):
        raise ValueError('unsupported selector form')
    if len(selectors) > 1:
        raise ValueError('multiple selectors refused')
    if not selectors:
        if out != ['--query-gpu=index,uuid', '--format=csv,noheader,nounits']:
            raise ValueError('unscoped command refused')
    else:
        i = selectors[0]
        if i + 1 >= len(out) or out[i + 1] not in (fields[0], gpu):
            raise ValueError('GPU selector no longer matches confirmed identity')
        out[i + 1] = gpu
    return out


def main():
    try:
        args = guarded_args(sys.argv[1:], os.environ.get('GPU', ''), subprocess.run)
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        print('z170 V100 guard: refused nvidia-smi operation: ' + str(exc), file=sys.stderr)
        return 1
    os.execv(REAL, [REAL] + args)


if __name__ == '__main__':
    sys.exit(main())
