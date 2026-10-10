#!/usr/bin/env python3
"""Private qualification policy writer; never changes global or tool sandbox policy."""
import argparse
import json
import os
import stat
import subprocess
import tempfile
import uuid
from pathlib import Path


def require_socket(value):
    policy([value])
    path = Path(value)
    if path.resolve(strict=True) != path or not stat.S_ISSOCK(path.lstat().st_mode):
        raise ValueError('Approved local endpoint must be an existing unaliased UNIX socket')
    return value


def simulator_socket(simulator, developer_directory):
    # Never accept "booted": ownership must identify one selected simulator.
    if str(uuid.UUID(simulator)).upper() != simulator.upper():
        raise ValueError('An exact simulator UUID is required')
    developer = Path(developer_directory)
    if not developer.is_absolute() or developer.resolve(strict=True) != developer or not developer.is_dir():
        raise ValueError('An existing canonical developer directory is required')
    environment = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'DEVELOPER_DIR': str(developer)}
    # A shutdown simulator cannot supply this variable. Do not boot, install,
    # or guess a launchd namespace inside the policy resolver.
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
        result = subprocess.run(['/usr/bin/xcrun', 'simctl', 'getenv', simulator, 'TESTMANAGERD_SIM_SOCK'],
                                env=environment, stdout=output, stderr=errors, timeout=15, check=False)
        if result.returncode != 0 or output.tell() > 1025 or errors.tell() > 65536:
            raise ValueError('Selected simulator test-manager socket could not be resolved')
        output.seek(0)
        value = output.read(1026).decode('utf-8', errors='strict')
    if not value.endswith('\n') or value.count('\n') != 1:
        raise ValueError('Simulator socket response must contain exactly one path')
    return require_socket(value[:-1])


def policy(unix_sockets=(), loopback_ports=()):
    if len(unix_sockets) > 16 or len(loopback_ports) > 16:
        raise ValueError('Local communication exceptions exceed budget')
    rules = ['(version 1)', '(allow default)', '(deny network-outbound)']
    for path in unix_sockets:
        if not isinstance(path, str) or not Path(path).is_absolute() or '\0' in path or '\n' in path or '\r' in path or '..' in Path(path).parts or str(Path(path)) != path or len(path.encode()) > 1024:
            raise ValueError('An exact absolute UNIX socket path is required')
    for path in sorted(set(unix_sockets)):
        rules.append('(allow network-outbound (remote unix-socket (path-literal ' + json.dumps(path, ensure_ascii=False) + ')))')
    for port in loopback_ports:
        if type(port) is not int or not 1 <= port <= 65535:
            raise ValueError('An exact loopback port is required')
    for port in sorted(set(loopback_ports)):
        rules.append('(allow network-outbound (remote ip "localhost:' + str(port) + '"))')
    return '\n'.join(rules) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--unix-socket', action='append', default=[])
    parser.add_argument('--loopback-port', action='append', type=int, default=[])
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--simulator', help='Already booted owned simulator UUID; resolve its live Apple IPC endpoint')
    parser.add_argument('--developer-directory', type=Path)
    parser.add_argument('command', nargs=argparse.REMAINDER, help='Optional explicit command after --; launch under the generated policy')
    args = parser.parse_args()
    try:
        if bool(args.simulator) != bool(args.developer_directory):
            raise ValueError('Simulator resolution requires its explicit developer directory')
        sockets = [require_socket(value) for value in args.unix_socket]
        resolved = simulator_socket(args.simulator, args.developer_directory) if args.simulator else None
        if resolved:
            sockets.append(resolved)
        payload = policy(sockets, args.loopback_port).encode()
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'wb') as output:
            output.write(payload); output.flush(); os.fsync(output.fileno())
        if resolved and simulator_socket(args.simulator, args.developer_directory) != resolved:
            raise ValueError('Simulator socket changed during policy creation; command was not launched')
        if args.command:
            if args.command[0] != '--' or len(args.command) < 2 or not Path(args.command[1]).is_absolute():
                raise ValueError('Launch requires -- followed by an explicit absolute executable')
            # Keep the generated profile as evidence. No broader parent sandbox
            # can be relaxed by this child policy.
            environment = dict(os.environ)
            if args.developer_directory:
                environment['DEVELOPER_DIR'] = str(args.developer_directory)
            os.execve('/usr/bin/sandbox-exec', ['sandbox-exec', '-f', str(args.output), *args.command[1:]], environment)
    except (ValueError, OSError, TypeError, UnicodeError, subprocess.TimeoutExpired) as error:
        parser.exit(1, 'Offline policy creation failed: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
