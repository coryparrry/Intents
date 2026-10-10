import importlib.util
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
from pathlib import Path

spec = importlib.util.spec_from_file_location('offline', Path(__file__).resolve().parents[1] / 'scripts/offline_harness.py')
offline = importlib.util.module_from_spec(spec); spec.loader.exec_module(offline)


class OfflineHarnessTests(unittest.TestCase):
    def test_simulator_resolution_uses_exact_owned_id_and_fails_closed(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            root = Path(temporary).resolve()
            address = str(root / 'current.sock')
            Path(address).write_bytes(b'')
            with self.assertRaises(ValueError): offline.require_socket(address)
            # Pure resolver fixtures simulate the socket stat; the opt-in
            # kernel test below uses actual sockets and actual policy launch.
            with patch.object(offline.stat, 'S_ISSOCK', return_value=True):
                simulator = '09D3C36B-7A4C-406A-91E5-0A99A429F7D3'
                def resolved(command, **kwargs):
                    self.assertEqual(command, ['/usr/bin/xcrun', 'simctl', 'getenv', simulator, 'TESTMANAGERD_SIM_SOCK'])
                    self.assertEqual(kwargs['env']['DEVELOPER_DIR'], str(root))
                    kwargs['stdout'].write((address + '\n').encode())
                    return subprocess.CompletedProcess(command, 0)
                with patch.object(offline.subprocess, 'run', side_effect=resolved):
                    self.assertEqual(offline.simulator_socket(simulator, root), address)
                    with self.assertRaises(ValueError): offline.simulator_socket('booted', root)
                for reply, status in [(b'', 0), (b'/missing\n', 0), ((address + '\n\n').encode(), 0), (b'x' * 1026, 0), (b'\xff\n', 0), ((address + '\n').encode(), 1)]:
                    def invalid(command, **kwargs):
                        kwargs['stdout'].write(reply)
                        return subprocess.CompletedProcess(command, status)
                    with patch.object(offline.subprocess, 'run', side_effect=invalid):
                        with self.assertRaises((ValueError, UnicodeError, OSError)):
                            offline.simulator_socket(simulator, root)

    def test_changed_endpoint_prevents_launch_and_retains_exact_policy(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            output = Path(temporary) / 'runtime.sb'
            args = ['offline_harness.py', '--simulator', '09D3C36B-7A4C-406A-91E5-0A99A429F7D3', '--developer-directory', temporary,
                    '--output', str(output), '--', '/usr/bin/true']
            with patch.object(sys, 'argv', args), patch.object(offline, 'simulator_socket', side_effect=['/private/tmp/current.sock', '/private/tmp/new.sock']), patch.object(offline.os, 'execve') as launch:
                with self.assertRaises(SystemExit) as failure: offline.main()
                self.assertEqual(failure.exception.code, 1)
                launch.assert_not_called()
            self.assertEqual(output.read_text(), offline.policy(['/private/tmp/current.sock']))

    def test_stable_endpoint_launches_only_through_written_deny_policy(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            output = Path(temporary) / 'runtime.sb'
            args = ['offline_harness.py', '--simulator', '09D3C36B-7A4C-406A-91E5-0A99A429F7D3', '--developer-directory', temporary,
                    '--output', str(output), '--', '/usr/bin/true']
            with patch.object(sys, 'argv', args), patch.object(offline, 'simulator_socket', return_value='/private/tmp/current.sock') as resolve, patch.object(offline.os, 'execve') as launch:
                offline.main()
                self.assertEqual(resolve.call_count, 2)
                launch.assert_called_once()
                executable, arguments, environment = launch.call_args.args
                self.assertEqual(executable, '/usr/bin/sandbox-exec')
                self.assertEqual(arguments, ['sandbox-exec', '-f', str(output), '/usr/bin/true'])
                self.assertEqual(environment['DEVELOPER_DIR'], temporary)
            self.assertEqual(output.read_text(), offline.policy(['/private/tmp/current.sock']))

    def test_default_deny_and_exact_escaped_local_exceptions(self):
        text = offline.policy(['/private/tmp/quoted"socket'], [12345])
        self.assertIn('(deny network-outbound)', text)
        self.assertIn('path-literal "/private/tmp/quoted\\"socket"', text)
        self.assertIn('localhost:12345', text)
        self.assertNotIn('localhost:*', text)
        self.assertNotIn('regex', text)

    def test_invalid_paths_ports_and_exception_counts_rejected(self):
        for value in ['relative', '/a/../b', '/a\0b', '/a\nb', '/a//b', '/a/./b']:
            with self.assertRaises(ValueError): offline.policy([value])
        for port in [0, 65536, True, '123']:
            with self.assertRaises(ValueError): offline.policy([], [port])
        with self.assertRaises(ValueError): offline.policy([f'/socket-{i}' for i in range(17)])
        for ports in ([1, True], [True, 1], [12345, 12345.0]):
            with self.assertRaises(ValueError): offline.policy([], ports)

    @unittest.skipUnless(sys.platform == 'darwin' and os.environ.get('INTENTS_AUTOMATION_OFFLINE_HARNESS') == '1', 'Opt-in local kernel boundary test; no device or Xcode operation')
    def test_kernel_allows_exact_ipc_and_denies_unapproved_local_and_offhost_addresses(self):
        with tempfile.TemporaryDirectory(prefix='offline-ipc-', dir='/private/tmp') as temporary:
            root = Path(temporary).resolve()
            allowed, denied = str(root / 'allowed.sock'), str(root / 'denied.sock')
            servers = []
            for address in (allowed, denied):
                server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); server.bind(address); server.listen(1); server.settimeout(5); servers.append(server)
            tcp = socket.socket(); tcp.bind(('127.0.0.1', 0)); tcp.listen(1); tcp.settimeout(5); servers.append(tcp)
            port = tcp.getsockname()[1]
            replies = []
            def echo(server):
                try:
                    connection, _ = server.accept()
                    with connection:
                        connection.settimeout(3); payload = connection.recv(16); connection.sendall(payload); replies.append(payload.decode())
                except (OSError, TimeoutError): pass
            workers = [threading.Thread(target=echo, args=(server,)) for server in (servers[0], tcp)]
            for worker in workers: worker.start()
            profile = root / 'runtime.sb'
            writer = Path(__file__).resolve().parents[1] / 'scripts/offline_harness.py'
            arguments = [sys.executable, str(writer), '--unix-socket', allowed, '--loopback-port', str(port), '--output', str(profile)]
            written = subprocess.run(arguments, capture_output=True, text=True, timeout=5)
            self.assertEqual(written.returncode, 0, written.stderr)
            self.assertEqual(profile.stat().st_mode & 0o777, 0o600)
            original = profile.read_bytes()
            replaced = subprocess.run(arguments, capture_output=True, text=True, timeout=5)
            self.assertNotEqual(replaced.returncode, 0)
            self.assertEqual(profile.read_bytes(), original)
            client = '''import socket,json,sys,errno
allowed,denied,port=sys.argv[1],sys.argv[2],int(sys.argv[3])
results={}
for name,family,address,permit in [('approvedUnix',socket.AF_UNIX,allowed,True),('approvedLoopback',socket.AF_INET,('127.0.0.1',port),True),('unapprovedUnix',socket.AF_UNIX,denied,False),('unapprovedLoopback',socket.AF_INET,('127.0.0.1',port+1 if port<65535 else port-1),False),('offhostIPv4',socket.AF_INET,('1.1.1.1',443),False),('offhostIPv6',socket.AF_INET6,('2606:4700:4700::1111',443),False)]:
 with socket.socket(family,socket.SOCK_STREAM) as connection:
  connection.settimeout(2)
  try:
   connection.connect(address)
   if permit:
    connection.sendall(b'fixture'); results[name]={'reply':connection.recv(16).decode()}
   else: results[name]={'unexpectedConnection':True}
  except OSError as error: results[name]={'errno':error.errno}
print(json.dumps(results,sort_keys=True))
'''
            try:
                process = subprocess.run(['/usr/bin/sandbox-exec', '-f', str(profile), sys.executable, '-c', client, allowed, denied, str(port)], capture_output=True, text=True, timeout=15)
                self.assertEqual(process.returncode, 0, process.stderr)
                results = json.loads(process.stdout)
                for name in ('approvedUnix', 'approvedLoopback'): self.assertEqual(results[name], {'reply': 'fixture'})
                for name in ('unapprovedUnix', 'unapprovedLoopback', 'offhostIPv4', 'offhostIPv6'): self.assertEqual(results[name], {'errno': 1})
                print('OFFLINE_KERNEL_RESULTS=' + json.dumps(results, sort_keys=True))
            finally:
                for server in servers: server.close()
                for worker in workers: worker.join(timeout=6)
            self.assertEqual(sorted(replies), ['fixture', 'fixture'])


if __name__ == '__main__':
    unittest.main()
