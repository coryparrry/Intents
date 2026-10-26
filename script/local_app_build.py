#!/usr/bin/env python3
"""Owner-safe local build locking, signing selection, and exclusive app moves."""
import ctypes
import fcntl
import hashlib
import os
from pathlib import Path
import re
import stat
import sys


LOCK_ENV = 'INTENTS_LOCAL_BUILD_LOCK_FD'
ROOT = Path(__file__).resolve().parents[1]


def lock_path():
    # Every invocation publishes into the same checkout, even when launched by
    # callers with different TMPDIR/TMP/TEMP values. Keep its lock equally stable.
    """Create or validate a private owner-only lock directory and derive one stable checkout-specific lock filename."""
    directory = Path('/tmp').resolve() / f'intents-local-build-locks-{os.getuid()}'
    directory.mkdir(mode=0o700, exist_ok=True)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError(f'Local build lock directory is not private: {directory}')
    digest = hashlib.sha256(os.fsencode(ROOT)).hexdigest()
    return directory / (digest + '.lock')


def validate_lock(fd):
    """Verify an inherited descriptor matches the safe current lock file and holds its exclusive nonblocking kernel lock."""
    expected = lock_path().lstat()
    actual = os.fstat(fd)
    if (not stat.S_ISREG(actual.st_mode) or actual.st_uid != os.getuid() or actual.st_nlink != 1
            or actual.st_mode & 0o077 or (actual.st_dev, actual.st_ino) != (expected.st_dev, expected.st_ino)):
        raise ValueError('Invalid inherited local build lock')
    # The inherited open-file description retains this lock across exec. A stale
    # environment variable cannot bypass another owner's active kernel lock.
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)


def run_locked(script, arguments):
    """Require the maintained build script, acquire a safe exclusive checkout lock, and exec bash with the live descriptor inherited; exit 3 on contention."""
    if Path(script).resolve() != ROOT / 'script/build_and_run.sh':
        raise ValueError('Unexpected local build script')
    fd = os.open(lock_path(), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    validate_lock_file = os.fstat(fd)
    if (not stat.S_ISREG(validate_lock_file.st_mode) or validate_lock_file.st_uid != os.getuid()
            or validate_lock_file.st_nlink != 1 or validate_lock_file.st_mode & 0o077):
        raise ValueError('Unsafe local build lock file')
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print('Another local app build is running. Wait for it to finish before running again.', file=sys.stderr)
        raise SystemExit(3)
    os.set_inheritable(fd, True)
    environment = dict(os.environ, **{LOCK_ENV: str(fd)})
    # Exec keeps one owner process and a live kernel lock. No stale lock token
    # survives SIGKILL; children retain the lock only while build work remains.
    os.execve('/bin/bash', ['/bin/bash', str(script), *arguments], environment)


def select_identity(inventory, override):
    """Select exactly one Developer ID Application certificate by optional fingerprint or name and validate its final team suffix."""
    identities = []
    for line in inventory.splitlines():
        match = re.fullmatch(r'\s*\d+\)\s+([A-Fa-f0-9]{40})\s+"(Developer ID Application: [^"]+)"\s*', line)
        if match:
            identities.append((match[1].upper(), match[2]))
    identities = sorted(set(identities))
    if override:
        identities = [entry for entry in identities
                      if override.upper() == entry[0] or override == entry[1]]
    if len(identities) != 1:
        if override:
            raise ValueError('INTENTS_LOCAL_SIGNING_IDENTITY must select exactly one available '
                             'Developer ID Application certificate; Apple Development and ad hoc signing are unsupported.')
        raise ValueError('Local Run requires exactly one available Developer ID Application certificate. '
                         'Set INTENTS_LOCAL_SIGNING_IDENTITY to its exact certificate SHA-1 when several are available.')
    identity, name = identities[0]
    # The trusted security inventory supplies Apple's complete certificate name.
    # Read only the selected entry's final Team suffix, never another entry or a
    # configured team. The sealed app's actual Team is checked again before use.
    _, separator, suffix = name.rpartition(' (')
    if not separator or not suffix.endswith(')'):
        raise ValueError('Selected Developer ID Application certificate has no Team ID suffix')
    team = suffix[:-1]
    if not re.fullmatch(r'[A-Z0-9]{10}', team):
        raise ValueError('Selected Developer ID Application certificate has an invalid Team ID')
    return identity, team


def rename_exclusive(source, destination):
    """Never replace or nest into a destination that appeared during publication."""
    library = ctypes.CDLL(None, use_errno=True)
    if sys.platform == 'darwin':
        operation = library.renamex_np
        operation.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        # SDK sys/stdio.h: RENAME_EXCL = 0x00000004.
        result = operation(os.fsencode(source), os.fsencode(destination), 0x00000004)
    elif sys.platform.startswith('linux'):
        operation = library.renameat2
        operation.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        result = operation(-100, os.fsencode(source), -100, os.fsencode(destination), 1)
    else:
        raise ValueError('Exclusive local app publication is unavailable on this platform')
    if result:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def main():
    """Dispatch lock acquisition, inherited-lock validation, identity selection, or exclusive rename and convert OS or validation failures into CLI diagnostics."""
    arguments = sys.argv[1:]
    try:
        if len(arguments) >= 2 and arguments[0] == '--run':
            run_locked(arguments[1], arguments[2:])
        elif len(arguments) == 2 and arguments[0] == '--check-lock':
            fd = int(arguments[1])
            validate_lock(fd)
        elif len(arguments) == 2 and arguments[0] == '--select-identity':
            print(' '.join(select_identity(sys.stdin.read(), arguments[1])))
        elif len(arguments) == 3 and arguments[0] == '--rename-exclusive':
            rename_exclusive(arguments[1], arguments[2])
        else:
            raise ValueError('Unexpected local app build helper arguments')
    except (OSError, ValueError) as error:
        raise SystemExit(f'Local app build: {error}') from error


if __name__ == '__main__':
    main()
