from http.client import HTTPSConnection
import json
from pathlib import Path
import shutil
import ssl
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from mr6c_https_fixture import Fixture, certificate


@unittest.skipUnless(shutil.which('openssl'), 'openssl unavailable')
class HttpsFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory()
        cls.cert, cls.key = certificate(Path(cls.scratch.name) / 'tls')

    @classmethod
    def tearDownClass(cls):
        cls.scratch.cleanup()

    def fixture(self):
        return Fixture(self.cert, self.key, heartbeat_seconds=.005, stream_seconds=.02)

    def client(self, fixture):
        context = ssl.create_default_context(cafile=str(self.cert))
        self.assertTrue(context.check_hostname)
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
        return HTTPSConnection('localhost', fixture.port, context=context, timeout=5)

    def test_certificate_has_emulator_alias_and_private_key_is_private(self):
        decoded = ssl._ssl._test_decode_cert(str(self.cert))
        self.assertIn(('IP Address', '10.0.2.2'), decoded['subjectAltName'])
        self.assertEqual(self.key.stat().st_mode & 0o777, 0o600)

    def test_real_tls_socket_sse_and_gitlab_read(self):
        with self.fixture() as fixture:
            client = self.client(fixture)
            client.request('GET', '/api/v4/user')
            response = client.getresponse()
            self.assertEqual(response.status, 200)
            self.assertEqual(json.loads(response.read())['username'], 'mr6c_synthetic')
            client.request('POST', '/v1/chat/completions', json.dumps({
                'model': 'mr6c-synthetic', 'stream': True,
                'messages': [{'role': 'user', 'content': 'MR6C_SYNTHETIC hello'}],
            }), {'Content-Type': 'application/json'})
            response = client.getresponse()
            self.assertEqual(response.status, 200)
            data = response.read()
            self.assertIn(b': heartbeat', data)
            self.assertIn(b'"finish_reason": "stop"', data)
            self.assertIn(b'data: [DONE]', data)
            client.close()
            evidence = fixture.evidence()
        kinds = [item['kind'] for item in evidence['events']]
        self.assertIn('gitlab_read_response', kinds)
        self.assertIn('model_socket_request', kinds)
        self.assertIn('sse_socket_write', kinds)
        self.assertEqual(evidence['network_conclusion'], 'NOT_VERIFIED')
        self.assertEqual(evidence['device_status'], 'NOT_RUN')

    def test_unknown_ca_and_wrong_hostname_are_rejected(self):
        with self.fixture() as fixture:
            client = HTTPSConnection('localhost', fixture.port,
                                     context=ssl.create_default_context(), timeout=5)
            with self.assertRaises(ssl.SSLCertVerificationError):
                client.request('GET', '/api/v4/user')
            client.close()
            context = ssl.create_default_context(cafile=str(self.cert))
            import socket
            with socket.create_connection(('127.0.0.1', fixture.port), timeout=5) as raw:
                with self.assertRaises(ssl.SSLCertVerificationError):
                    context.wrap_socket(raw, server_hostname='other.example')

    def test_mutation_is_synthetic_and_counters_contain_no_bodies_or_headers(self):
        with self.fixture() as fixture:
            client = self.client(fixture)
            client.request('POST', '/api/v4/projects/1/issues',
                           json.dumps({'title': 'MR6C_SYNTHETIC'}))
            response = client.getresponse()
            self.assertEqual(response.status, 201)
            response.read()
            client.request('POST', '/api/v4/projects/1/issues',
                           json.dumps({'title': 'private content'}))
            response = client.getresponse()
            self.assertEqual(response.status, 400)
            response.read()
            client.close()
            evidence = json.dumps(fixture.evidence())
        self.assertNotIn('private content', evidence)
        self.assertNotIn('MR6C_SYNTHETIC', evidence)
        self.assertNotIn('Authorization', evidence)
        self.assertNotIn('title', evidence)

    def test_real_credentials_and_cookie_are_rejected_without_recording_them(self):
        with self.fixture() as fixture:
            for headers in ({'Authorization': 'Bearer secret-do-not-log'},
                            {'PRIVATE-TOKEN': 'secret-do-not-log'},
                            {'Cookie': 'secret-do-not-log'}):
                client = self.client(fixture)
                client.request('GET', '/api/v4/user', headers=headers)
                response = client.getresponse()
                self.assertEqual(response.status, 403)
                response.read()
                client.close()
            self.assertEqual(fixture.evidence()['events'], [])
            self.assertNotIn('secret-do-not-log', json.dumps(fixture.evidence()))

    def test_missing_length_and_non_synthetic_model_do_not_start_sse(self):
        with self.fixture() as fixture:
            client = self.client(fixture)
            client.request('POST', '/v1/chat/completions', '{}')
            response = client.getresponse()
            self.assertEqual(response.status, 400)
            response.read()
            client.close()
            self.assertEqual(fixture.evidence()['events'], [])

    def test_existing_certificate_directory_is_never_replaced(self):
        with self.assertRaises(FileExistsError):
            certificate(self.cert.parent)


if __name__ == '__main__':
    unittest.main()
