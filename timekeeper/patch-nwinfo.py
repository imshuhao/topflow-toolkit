#!/usr/bin/env python3
"""Create a UTC-only B22 NITZ writer from a device-owned binary, never ship it.

At 0x31bb0 replace the addition of signed quarter-hour timezone to the
QMI UTC calendar epoch with a plain move. Calendar validation, clock_settime,
NITZ timezone metadata and success notification remain intact. File offsets equal virtual
addresses in this B22 PT_LOAD segment. Unknown firmware is rejected.
"""
import hashlib
from pathlib import Path
import sys

ORIGINAL_SHA256 = '55dbb174dd8549410de9e37ae3e8bbef08abb8816789a83e1fbc24b87b5ea5af'
PATCHED_SHA256 = '29c3c7145f52b9e16f63b368e7a22587674f137c8725a582a852fa0ef4e8fdd2'
OFFSET = 0x31bb0
ORIGINAL = bytes.fromhex('20c0208b')  # add x0, x1, w0, sxtw
PATCHED = bytes.fromhex('e00301aa')   # mov x0, x1


def patch(data):
    digest = hashlib.sha256(data).hexdigest()
    if digest == PATCHED_SHA256:
        return data
    if digest != ORIGINAL_SHA256 or data[OFFSET:OFFSET + 4] != ORIGINAL:
        raise ValueError('unsupported nwinfo: firmware hash does not match audited B22')
    result = data[:OFFSET] + PATCHED + data[OFFSET + 4:]
    if hashlib.sha256(result).hexdigest() != PATCHED_SHA256:
        raise ValueError('patched nwinfo hash mismatch')
    return result


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit('usage: patch-nwinfo.py DEVICE_BINARY OUTPUT')
    try:
        result = patch(Path(sys.argv[1]).read_bytes())
    except ValueError as exc:
        sys.exit(str(exc))
    Path(sys.argv[2]).write_bytes(result)
    Path(sys.argv[2]).chmod(0o700)
