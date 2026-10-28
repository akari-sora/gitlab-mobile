#!/usr/bin/env python3
"""Synthetic MR6c HTTPS socket fixture; host writes alone never prove V1.

The independent Android runner/transport fixture is still required. Trust this
session's public PEM only for 10.0.2.2 and its explicit port. Never install a CA,
use an accept-all callback, alter production TLS, or use adb forwarding.
"""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import signal
import ssl
import subprocess
import threading
import time

from mr6c_emulator_checks import GateError, require, write_json

SYNTHETIC_TOKEN = 'mr6c-synthetic-token'


def certificate(directory):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=False, mode=0o700)
    key, cert = directory / 'fixture-key.pem', directory / 'fixture-cert.pem'
    try:
        result = subprocess.run([
            'openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
            '-subj', '/CN=10.0.2.2', '-addext',
            'subjectAltName=IP:10.0.2.2,IP:127.0.0.1,DNS:localhost',
            '-addext', 'basicConstraints=critical,CA:TRUE',
            '-addext', 'keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign',
            '-addext', 'extendedKeyUsage=serverAuth',
            '-keyout', str(key), '-out', str(cert),
        ], capture_output=True, timeout=30, check=False)
        require(result.returncode == 0 and key.is_file() and cert.is_file(), 'fixture_certificate_failed')
        os.chmod(key, 0o600)
        os.chmod(cert, 0o600)
    except (OSError, subprocess.TimeoutExpired, GateError):
        key.unlink(missing_ok=True)
        raise GateError('fixture_certificate_failed') from None
    return cert, key


class Fixture:
    def __init__(self, cert, key, *, port=0, heartbeat_seconds=5, stream_seconds=120):
        require(0 < heartbeat_seconds <= 5 and heartbeat_seconds <= stream_seconds < 300,
                'invalid_fixture_timing')
        self.started = time.monotonic()
        self.heartbeat_seconds, self.stream_seconds = heartbeat_seconds, stream_seconds
        self.lock = threading.Lock()
        self.events = []
        self.stopping = threading.Event()
        self.certificate = Path(cert)
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'

            def log_message(self, *_args):
                pass  # Do not retain headers, paths, bodies, credentials or raw errors.

            def setup(self):
                super().setup()
                self.connection.settimeout(10)

            def guard(self):
                # A dedicated synthetic transport must never send real credentials.
                valid = (self.headers.get('Authorization') in (None, 'Bearer ' + SYNTHETIC_TOKEN)
                         and self.headers.get('PRIVATE-TOKEN') in (None, SYNTHETIC_TOKEN)
                         and self.headers.get('Cookie') is None
                         and self.headers.get('Transfer-Encoding') is None)
                if not valid:
                    self.respond(403, {'error': 'synthetic_only'})
                return valid

            def respond(self, status, body):
                data = json.dumps(body).encode()
                self.send_response(status)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(data)))
                self.send_header('Cache-Control', 'no-store')
                self.end_headers()
                self.wfile.write(data)
                self.wfile.flush()

            def body(self):
                size = self.headers.get('Content-Length', '')
                if not size.isdigit() or not 0 < int(size) <= 65536:
                    raise GateError('fixture_body_size')
                value = json.loads(self.rfile.read(int(size)))
                if not isinstance(value, dict):
                    raise GateError('fixture_body_shape')
                return value

            def do_GET(self):
                if not self.guard():
                    return
                if self.path == '/api/v4/user':
                    self.respond(200, {'id': 1, 'username': 'mr6c_synthetic', 'name': 'Synthetic'})
                elif self.path == '/api/v4/projects/1':
                    self.respond(200, {'id': 1, 'path_with_namespace': 'mr6c/synthetic',
                                       'default_branch': 'main', 'visibility': 'private'})
                elif self.path == '/api/v4/projects/1/issues/1':
                    self.respond(200, {'id': 1, 'iid': 1, 'project_id': 1,
                                       'title': 'MR6C_SYNTHETIC', 'state': 'opened'})
                else:
                    self.respond(404, {'error': 'fixture_route'})
                    return
                fixture.record('gitlab_read_response')

            def do_POST(self):
                if not self.guard():
                    return
                try:
                    value = self.body()
                    if self.path == '/v1/chat/completions':
                        require(value.get('model') == 'mr6c-synthetic', 'fixture_model')
                        messages = value.get('messages')
                        require(isinstance(messages, list) and messages and
                                all(isinstance(m, dict) and m.get('role') in ('system', 'user', 'assistant')
                                    and isinstance(m.get('content'), str)
                                    and m['content'].startswith('MR6C_SYNTHETIC') for m in messages),
                                'fixture_messages')
                        require(value.get('stream') is True, 'fixture_stream_required')
                        self.stream()
                    elif self.path == '/api/v4/projects/1/issues':
                        require(value == {'title': 'MR6C_SYNTHETIC'}, 'fixture_mutation')
                        self.respond(201, {'id': 1, 'iid': 1, 'project_id': 1,
                                           'title': 'MR6C_SYNTHETIC', 'state': 'opened'})
                        fixture.record('gitlab_mutation_response')
                    else:
                        self.respond(404, {'error': 'fixture_route'})
                except (GateError, ValueError, UnicodeError):
                    self.respond(400, {'error': 'invalid_synthetic_request'})
                except (BrokenPipeError, ConnectionError, TimeoutError):
                    fixture.record('socket_disconnected')

            def stream(self):
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Cache-Control', 'no-store')
                self.send_header('Connection', 'close')
                self.end_headers()
                self.close_connection = True
                fixture.record('model_socket_request')
                end = time.monotonic() + fixture.stream_seconds
                while time.monotonic() < end and not fixture.stopping.is_set():
                    chunk = {'id': 'mr6c-synthetic', 'object': 'chat.completion.chunk',
                             'choices': [{'index': 0, 'delta': {'content': '.'}, 'finish_reason': None}]}
                    data = (': heartbeat\n\ndata: ' + json.dumps(chunk) + '\n\n').encode()
                    self.wfile.write(data)
                    self.wfile.flush()
                    fixture.record('sse_socket_write', len(data))
                    fixture.stopping.wait(min(fixture.heartbeat_seconds, max(0, end-time.monotonic())))
                if not fixture.stopping.is_set():
                    terminal = {'id': 'mr6c-synthetic', 'object': 'chat.completion.chunk',
                                'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}]}
                    data = ('data: ' + json.dumps(terminal) + '\n\ndata: [DONE]\n\n').encode()
                    self.wfile.write(data)
                    self.wfile.flush()
                    fixture.record('sse_socket_end', len(data))

        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(str(cert), str(key))
        class Server(ThreadingHTTPServer):
            def handle_error(self, _request, _client_address):
                # The default handler prints an uncontrolled traceback.
                fixture.record('socket_disconnected')

        self.server = Server(('127.0.0.1', port), Handler)
        self.server.daemon_threads = True
        self.server.socket = context.wrap_socket(self.server.socket, server_side=True)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @property
    def port(self):
        return self.server.server_port

    def record(self, kind, count=0):
        with self.lock:
            require(len(self.events) < 10000, 'fixture_evidence_limit')
            self.events.append({'kind': kind, 'elapsed_ms': int((time.monotonic()-self.started)*1000),
                                'bytes': count})

    def evidence(self):
        with self.lock:
            return {'schema': 1, 'host': '10.0.2.2', 'port': self.port,
                    'certificate_sha256': hashlib.sha256(self.certificate.read_bytes()).hexdigest(),
                    'events': list(self.events), 'device_status': 'NOT_RUN',
                    'network_conclusion': 'NOT_VERIFIED'}

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_args):
        self.stopping.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=10)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='new session directory')
    parser.add_argument('--port', type=int, default=0)
    parser.add_argument('--duration', type=int, default=780, help='host lifetime, 720..1800 seconds')
    args = parser.parse_args(argv)
    require(720 <= args.duration <= 1800 and 0 <= args.port < 65536, 'invalid_fixture_arguments')
    cert, key = certificate(args.output)
    try:
        with Fixture(cert, key, port=args.port) as fixture:
            write_json(args.output / 'endpoint.json', {'host': '10.0.2.2', 'port': fixture.port,
                       'certificate_pem': cert.read_text(), 'network_conclusion': 'NOT_VERIFIED'})
            print('Synthetic HTTPS fixture ready; endpoint.json contains the public endpoint.', flush=True)
            fixture.stopping.wait(args.duration)
    except KeyboardInterrupt:
        pass
    finally:
        if 'fixture' in locals():
            write_json(args.output / 'host-network.json', fixture.evidence())
        key.unlink(missing_ok=True)  # Public certificate and small evidence may be retained.
    return 0


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    try:
        raise SystemExit(main())
    except (GateError, OSError):
        print('fixture_failed', file=__import__('sys').stderr)
        raise SystemExit(1)
