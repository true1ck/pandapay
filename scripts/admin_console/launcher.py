#!/usr/bin/env python3
"""PC-local console supervisor. Never changes OS trust, SSH or live services."""
import argparse
import fcntl
import http.client
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import stat
import subprocess
import sys
import threading
import time
import webbrowser

STATE = Path.home() / 'Library/Application Support/PandaPayAdmin'
ROOT = Path(__file__).resolve().parents[2]


def protected(path):
    p = Path(path).expanduser()
    if not p.is_absolute() or p.is_symlink() or not p.is_file():
        raise ValueError('A regular absolute protected file is required')
    mode = p.stat()
    if mode.st_uid != os.getuid() or stat.S_IMODE(mode.st_mode) & 0o077:
        raise ValueError('Protected files must belong to you and have mode 0600')
    return str(p)


def configuration(path, target):
    cfg = json.loads(Path(protected(path)).read_text())
    if cfg.get('target') != target or not re.fullmatch(r'[a-z][a-z0-9-]{0,31}', target):
        raise ValueError('Target must match the protected configuration')
    for field in ('ssh_host', 'ssh_user'):
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,253}', cfg.get(field, '')):
            raise ValueError('Invalid SSH endpoint')
    for field in ('ssh_identity', 'known_hosts', 'certificate_key'):
        cfg[field] = protected(cfg[field])
    for field in ('certificate', 'bundle', 'nginx_mime_types'):
        p = Path(cfg[field]).expanduser()
        if not p.is_absolute() or not p.exists() or p.is_symlink():
            raise ValueError('Missing local bundle/TLS configuration')
        cfg[field] = str(p)
    if not (Path(cfg['bundle']) / 'index.html').is_file():
        raise ValueError('Build/install the reviewed console bundle first')
    for value in cfg.values():
        if not isinstance(value, str) or any(c in value for c in ('\n', '\r', '"', '$', '\\')):
            raise ValueError('Unsupported configuration value')
    return cfg


def ssh_command(cfg):
    return ['ssh', '-F', '/dev/null', '-N', '-T', '-o', 'BatchMode=yes',
            '-o', 'IdentitiesOnly=yes', '-o', 'IdentityAgent=none',
            '-o', 'StrictHostKeyChecking=yes', '-o', 'ExitOnForwardFailure=yes',
            '-o', 'ForwardAgent=no', '-o', 'ServerAliveInterval=15',
            '-o', 'ServerAliveCountMax=2', '-o', 'ConnectTimeout=10',
            '-o', 'UserKnownHostsFile=' + cfg['known_hosts'],
            '-i', cfg['ssh_identity'], '-L', '127.0.0.1:7431:127.0.0.1:4321',
            cfg['ssh_user'] + '@' + cfg['ssh_host']]


def control(command):
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(3)
        s.connect(str(STATE / 'control.sock'))
        s.sendall(command.encode('ascii'))
        return json.loads(s.recv(4096))


def serve(cfg):
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    if STATE.is_symlink() or STATE.stat().st_uid != os.getuid():
        raise ValueError('Unsafe local state directory')
    os.chmod(STATE, 0o700)
    with (STATE / 'lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        # No existing listener may be silently reused.
        for port in (7431, 8443):
            with socket.socket() as s:
                s.bind(('127.0.0.1', port))
        template = (ROOT / 'deploy/nginx/console.localhost.conf.example').read_text()
        values = {'STATE': str(STATE), 'MIME': cfg['nginx_mime_types'],
                  'CERT': cfg['certificate'], 'KEY': cfg['certificate_key'], 'BUNDLE': cfg['bundle']}
        for key, value in values.items():
            template = template.replace('@' + key + '@', value)
        conf = STATE / 'nginx.conf'
        conf.write_text(template)
        os.chmod(conf, 0o600)
        nginx = shutil.which('nginx')
        if not nginx:
            raise ValueError('Install a reviewed Nginx version first')
        subprocess.run([nginx, '-t', '-c', str(conf), '-p', str(STATE)], check=True, capture_output=True)
        stop = threading.Event()
        for signum in (signal.SIGTERM, signal.SIGINT):
            signal.signal(signum, lambda *_: stop.set())
        children = []
        sockpath = STATE / 'control.sock'
        sockpath.unlink(missing_ok=True)
        try:
            children.append(subprocess.Popen(ssh_command(cfg), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
            # Establish local forwarding before opening the UI. Remote failure
            # remains a denied/unavailable gateway response, never a fallback.
            deadline = time.monotonic() + 12
            while True:
                if children[0].poll() is not None:
                    raise ValueError('Private transport failed')
                try:
                    with socket.create_connection(('127.0.0.1', 7431), timeout=.25): break
                except OSError:
                    if time.monotonic() >= deadline: raise ValueError('Private transport unavailable')
                    time.sleep(.1)
            check = http.client.HTTPConnection('127.0.0.1', 7431, timeout=5)
            try:
                check.request('GET', '/ready', headers={'Host': 'localhost:8443'})
                result = check.getresponse()
                ready = json.loads(result.read(4096))
                if result.status != 200 or ready.get('ok') is not True or ready.get('environment') != cfg['target']:
                    raise ValueError('Private gateway is not ready')
            finally:
                check.close()
            children.append(subprocess.Popen([nginx, '-c', str(conf), '-p', str(STATE), '-g', 'daemon off; master_process off;'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
            with socket.socket(socket.AF_UNIX) as server:
                server.bind(str(sockpath)); os.chmod(sockpath, 0o600)
                server.listen(2); server.settimeout(.5)
                while not stop.is_set() and all(p.poll() is None for p in children):
                    try: connection, _ = server.accept()
                    except socket.timeout: continue
                    with connection:
                        connection.settimeout(1)
                        cmd = connection.recv(16)
                        if cmd == b'stop': stop.set()
                        connection.sendall(json.dumps({'target': cfg['target'], 'running': not stop.is_set()}).encode())
        finally:
            for child in reversed(children):
                if child.poll() is None: child.terminate()
            for child in children:
                try: child.wait(timeout=5)
                except subprocess.TimeoutExpired: child.kill(); child.wait()
            sockpath.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['start', '_run', 'status', 'stop'])
    parser.add_argument('--target')
    parser.add_argument('--config')
    args = parser.parse_args()
    if args.action in ('status', 'stop'):
        try: print(json.dumps(control(args.action)))
        except OSError: print(json.dumps({'running': False}))
        return
    cfg = configuration(args.config, args.target)
    if args.action == '_run': serve(cfg); return
    subprocess.Popen([sys.executable, str(Path(__file__).resolve()), '_run', '--target', args.target,
                      '--config', str(Path(args.config).resolve())], start_new_session=True,
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(30):
        time.sleep(.5)
        try:
            status = control('status')
            if status.get('target') != args.target: raise ValueError('Another target is already running')
            print(json.dumps(status)); webbrowser.open('https://localhost:8443'); return
        except OSError: pass
    raise ValueError('Console did not start; check private transport, TLS, Nginx and port availability')


if __name__ == '__main__':
    try: main()
    except Exception as error:
        # No resolved configuration or raw subprocess output is printed.
        print('Local admin console unavailable: ' + type(error).__name__, file=sys.stderr)
        sys.exit(1)
