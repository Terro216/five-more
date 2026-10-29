import base64
import hashlib
import json
import tempfile
import unittest
import uuid
from unittest.mock import patch
from dataclasses import replace
from pathlib import Path

import cbor2
from cryptography.fernet import Fernet
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi.testclient import TestClient

from server.app import Config, create_app, digest


def enc(value):
    return base64.urlsafe_b64encode(value).decode().rstrip('=')


class Authenticator:
    def __init__(self):
        self.key = ec.generate_private_key(ec.SECP256R1())
        self.id = uuid.uuid4().bytes
        self.counter = 0
        self.handle = None

    def registration(self, options, origin='https://sync.example.test', flags=0x45):
        self.handle = options['user']['id']
        pub = self.key.public_key().public_numbers()
        cose = cbor2.dumps({1: 2, 3: -7, -1: 1, -2: pub.x.to_bytes(32, 'big'), -3: pub.y.to_bytes(32, 'big')})
        auth = hashlib.sha256(options['rp']['id'].encode()).digest() + bytes([flags]) + bytes(4) + bytes(16) + len(self.id).to_bytes(2, 'big') + self.id + cose
        client = json.dumps({'type': 'webauthn.create', 'challenge': options['challenge'], 'origin': origin, 'crossOrigin': False}).encode()
        return {'id': enc(self.id), 'rawId': enc(self.id), 'type': 'public-key', 'response': {
            'clientDataJSON': enc(client), 'attestationObject': enc(cbor2.dumps({'fmt': 'none', 'attStmt': {}, 'authData': auth}))}}

    def authentication(self, options, origin='https://sync.example.test', flags=0x05):
        self.counter += 1
        auth = hashlib.sha256(options['rpId'].encode()).digest() + bytes([flags]) + self.counter.to_bytes(4, 'big')
        client = json.dumps({'type': 'webauthn.get', 'challenge': options['challenge'], 'origin': origin, 'crossOrigin': False}).encode()
        signature = self.key.sign(auth + hashlib.sha256(client).digest(), ec.ECDSA(hashes.SHA256()))
        return {'id': enc(self.id), 'rawId': enc(self.id), 'type': 'public-key', 'response': {'clientDataJSON': enc(client), 'authenticatorData': enc(auth), 'signature': enc(signature), 'userHandle': self.handle}}


class ApiTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.config = Config(Path(self.temp.name), 'sync.example.test', ('https://sync.example.test',), Fernet.generate_key())
        self.app = create_app(self.config)
        self.client = TestClient(self.app)
        self.auth = Authenticator()
        self.identity = self.register(self.auth)
        self.headers = {'Authorization': 'Bearer ' + self.identity['token']}

    def tearDown(self):
        self.client.close()
        self.temp.cleanup()

    def register(self, authenticator):
        options = self.client.post('/v1/auth/register/options').json()
        response = self.client.post('/v1/auth/register/verify', json={'challengeId': options['challengeId'], 'credential': authenticator.registration(options['options'])})
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    def event(self, index=1, at=1793200000000, kind='snoozed'):
        identifier = f'e-{index}'
        return {'kind': 'event', 'id': identifier, 'revision': 0, 'deleted': False, 'data': {'eventId': identifier, 'id': 'alarm', 'occurrenceId': f'occ-{index}', 'at': at, 'type': kind, 'snoozesUsed': 1, 'snoozedMinutes': 5}}

    def sync(self, records, headers=None):
        return self.client.post('/v1/sync', headers=headers or self.headers, json={'records': records})

    def enable_audio(self):
        self.client.close()
        self.app = create_app(replace(self.config, audio_account_id=self.identity['accountId']))
        self.client = TestClient(self.app)

    def test_recovery_cannot_be_undone_by_an_inflight_add_passkey(self):
        from server.app import verify_registration_response
        options = self.client.post('/v1/auth/register/options', headers=self.headers).json()
        authenticator = Authenticator()
        fresh = {}
        def verify_then_recover(**kwargs):
            verified = verify_registration_response(**kwargs)
            response = self.client.post('/v1/auth/recover', json={'recoveryKey': self.identity['recoveryKey']})
            self.assertEqual(response.status_code, 200)
            fresh.update(response.json())
            return verified
        with patch('server.app.verify_registration_response', side_effect=verify_then_recover):
            result = self.client.post('/v1/auth/register/verify', headers=self.headers, json={'challengeId': options['challengeId'], 'credential': authenticator.registration(options['options'])})
        self.assertEqual(result.status_code, 401)
        with self.app.state.store.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM credentials WHERE account = ?', (fresh['accountId'],)).fetchone()[0], 0)

    def test_wrong_encryption_key_fails_startup(self):
        from cryptography.fernet import InvalidToken
        self.assertEqual(self.sync([self.event()]).status_code, 200)
        with self.assertRaises(InvalidToken):
            create_app(replace(self.config, data_key=Fernet.generate_key()))

    def test_recovery_of_a_different_bound_account_does_not_revoke_access(self):
        response = self.client.post('/v1/auth/recover', json={'recoveryKey': self.identity['recoveryKey'], 'expectedAccountId': 'different-account'})
        self.assertEqual(response.status_code, 403)
        self.assertEqual(self.client.get('/v1/account', headers=self.headers).status_code, 200)
        result = self.client.post('/v1/auth/recover', json={'recoveryKey': self.identity['recoveryKey'], 'expectedAccountId': self.identity['accountId']})
        self.assertEqual(result.status_code, 200)

    def test_day_buckets_use_timezone_rules_across_dst(self):
        from datetime import datetime
        # Berlin midnight is UTC+2 before the autumn transition, UTC+1 after.
        before = int(datetime.fromisoformat('2026-10-24T22:30:00+00:00').timestamp() * 1000)
        after = int(datetime.fromisoformat('2026-10-25T22:30:00+00:00').timestamp() * 1000)
        self.assertEqual(self.sync([self.event(1, before), self.event(2, after)]).status_code, 200)
        result = self.client.get('/v1/summary?time_zone=Europe%2FBerlin', headers=self.headers)
        self.assertEqual(result.status_code, 200)
        self.assertEqual(result.json()['snoozeDays'], [{'day': '2026-10-25', 'value': 2}])
        self.assertEqual(self.client.get('/v1/summary?time_zone=invalid', headers=self.headers).status_code, 422)

    def test_real_passkey_login_and_replay(self):
        options = self.client.post('/v1/auth/login/options').json()
        body = {'challengeId': options['challengeId'], 'credential': self.auth.authentication(options['options'])}
        result = self.client.post('/v1/auth/login/verify', json=body)
        self.assertEqual(result.status_code, 200, result.text)
        self.assertEqual(result.json()['accountId'], self.identity['accountId'])
        self.assertEqual(self.client.post('/v1/auth/login/verify', json=body).status_code, 400)

    def test_wrong_origin_missing_user_verification_and_handle(self):
        for origin, flags, bad_handle in [('https://phishing.example.test', 5, False), ('https://sync.example.test', 1, False), ('https://sync.example.test', 5, True)]:
            options = self.client.post('/v1/auth/login/options').json()
            credential = self.auth.authentication(options['options'], origin, flags)
            if bad_handle:
                credential['response']['userHandle'] = enc(b'another-account')
            result = self.client.post('/v1/auth/login/verify', json={'challengeId': options['challengeId'], 'credential': credential})
            self.assertEqual(result.status_code, 400)

    def test_challenge_expires(self):
        options = self.client.post('/v1/auth/login/options').json()
        with self.app.state.store.connect() as db:
            db.execute('UPDATE challenges SET expires=0')
        result = self.client.post('/v1/auth/login/verify', json={'challengeId': options['challengeId'], 'credential': self.auth.authentication(options['options'])})
        self.assertEqual(result.status_code, 400)

    def test_recovery_rotates_secret_and_revokes_old_access(self):
        result = self.client.post('/v1/auth/recover', json={'recoveryKey': self.identity['recoveryKey']})
        self.assertEqual(result.status_code, 200, result.text)
        self.assertNotEqual(result.json()['recoveryKey'], self.identity['recoveryKey'])
        self.assertEqual(self.client.get('/v1/account', headers=self.headers).status_code, 401)
        self.assertEqual(self.client.post('/v1/auth/recover', json={'recoveryKey': self.identity['recoveryKey']}).status_code, 401)
        with self.app.state.store.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM credentials').fetchone()[0], 0)
            self.assertNotEqual(db.execute('SELECT recovery FROM accounts').fetchone()[0], result.json()['recoveryKey'])

    def test_isolation_and_idempotency(self):
        other = self.register(Authenticator())
        other_headers = {'Authorization': 'Bearer ' + other['token']}
        self.assertEqual(self.sync([self.event()]).status_code, 200)
        self.assertEqual(self.sync([self.event()]).json()['accepted'][0]['revision'], 1)
        self.assertEqual(self.client.get('/v1/bootstrap', headers=other_headers).json()['records'], [])
        self.assertEqual(self.client.get('/v1/history', headers=other_headers).json()['records'], [])
        self.assertEqual(self.client.get('/v1/summary', headers=other_headers).json()['snoozes'], 0)
        result = self.client.get('/v1/account', headers=self.headers)
        foreign_id = self.client.get('/v1/account', headers=other_headers).json()['sessions'][0]['id']
        self.client.delete('/v1/sessions/' + foreign_id, headers=self.headers)
        self.assertEqual(self.client.get('/v1/account', headers=other_headers).status_code, 200)
        self.assertEqual(result.headers['cache-control'], 'no-store')

    def test_events_cannot_be_rewritten(self):
        self.sync([self.event()])
        edited = self.event(kind='dismissed')
        edited['revision'] = 1
        result = self.sync([edited]).json()
        self.assertEqual(len(result['conflicts']), 1)
        self.assertEqual(result['conflicts'][0]['data']['type'], 'snoozed')

    def test_atomic_batch_and_no_preview_uploads(self):
        invalid = self.event(2)
        invalid['data']['id'] = 'preview:test'
        self.assertEqual(self.sync([self.event(), invalid]).status_code, 422)
        self.assertEqual(self.client.get('/v1/bootstrap', headers=self.headers).json()['records'], [])

    def test_history_more_than_500_and_complete_summary(self):
        for chunk in range(6):
            self.assertEqual(self.sync([self.event(chunk * 100 + i) for i in range(100)]).status_code, 200)
        bootstrap = self.client.get('/v1/bootstrap', headers=self.headers).json()
        self.assertEqual(len(bootstrap['records']), 500)
        self.assertEqual(self.client.get('/v1/summary', headers=self.headers).json()['snoozes'], 600)
        identifiers, params = set(), {}
        while True:
            page = self.client.get('/v1/history', params=params, headers=self.headers).json()
            identifiers.update(r['id'] for r in page['records'])
            if not page['more']:
                break
            last = page['records'][-1]
            params = {'before_at': last['at'], 'before_id': last['id']}
        self.assertEqual(len(identifiers), 600)

    def test_period_boundary_keeps_original_ring(self):
        start = 1793200000000
        fired = self.event(1, start - 60000, 'fired')
        dismissed = self.event(2, start + 120000, 'dismissed')
        dismissed['data']['occurrenceId'] = fired['data']['occurrenceId']
        self.sync([fired, dismissed])
        result = self.client.get('/v1/summary', params={'start': start, 'end': start + 180000}, headers=self.headers).json()
        self.assertEqual(result['outcomes'], [1, 0, 0])
        self.assertEqual(result['wakeDays'][0]['value'], 3)

    def test_audio_denied_for_every_account_by_default(self):
        identifier = str(uuid.uuid4()) + '.m4a'
        payload = {'kind': 'note', 'id': identifier, 'revision': 0, 'deleted': False, 'data': {'file': identifier, 'at': 1793200000000, 'seconds': 300}}
        self.assertEqual(self.sync([payload]).status_code, 403)
        self.assertEqual(self.client.put('/v1/audio/' + identifier, headers=self.headers, content=b'1234ftypM4A ').status_code, 403)
        self.assertEqual(self.client.get('/v1/audio/' + identifier, headers=self.headers).status_code, 403)

    def test_owner_audio_round_trip_encrypted_and_other_account_denied(self):
        self.enable_audio()
        identifier = str(uuid.uuid4()) + '.m4a'
        payload = {'kind': 'note', 'id': identifier, 'revision': 0, 'deleted': False, 'data': {'file': identifier, 'at': 1793200000000, 'seconds': 300}}
        self.assertEqual(self.sync([payload]).status_code, 200)
        audio = b'1234ftypM4A ' + b'private-voice-data' * 10
        self.assertEqual(self.client.put('/v1/audio/' + identifier, headers=self.headers, content=audio).status_code, 200)
        self.assertEqual(self.client.get('/v1/audio/' + identifier, headers=self.headers).content, audio)
        other = self.register(Authenticator())
        headers = {'Authorization': 'Bearer ' + other['token']}
        self.assertEqual(self.client.get('/v1/audio/' + identifier, headers=headers).status_code, 403)
        file = next((Path(self.temp.name) / 'audio').iterdir())
        self.assertNotIn(b'private-voice-data', file.read_bytes())
        with self.app.state.store.connect() as db:
            self.assertNotIn(identifier.encode(), db.execute('SELECT data FROM records').fetchone()[0])
        payload.update(revision=1, deleted=True)
        self.assertEqual(self.sync([payload]).status_code, 200)
        self.assertEqual(self.client.get('/v1/audio/' + identifier, headers=self.headers).status_code, 404)
        self.assertFalse(file.exists())

    def test_sleep_revision_conflicts_and_deletion_cursor(self):
        payload = {'kind': 'sleep', 'id': 'night', 'revision': 0, 'deleted': False, 'data': {'occurrenceId': 'night', 'bedAt': 1793170000000, 'wokeAt': 1793200000000, 'sleepQuality': 3, 'wakeQuality': 4}}
        self.sync([payload])
        cursor = self.client.get('/v1/bootstrap', headers=self.headers).json()['cursor']
        payload['data']['sleepQuality'] = 5
        self.assertEqual(len(self.sync([payload]).json()['conflicts']), 1)
        payload.update(revision=1, deleted=True)
        self.assertEqual(self.sync([payload]).status_code, 200)
        changes = self.client.get('/v1/changes', params={'cursor': cursor}, headers=self.headers).json()
        self.assertTrue(changes['records'][0]['deleted'])
        self.assertGreater(changes['cursor'], cursor)

    def test_unauthorized_requests_and_large_body(self):
        for path in ('/v1/account', '/v1/bootstrap', '/v1/history', '/v1/summary', '/v1/changes'):
            self.assertEqual(self.client.get(path).status_code, 401)
        response = self.client.post('/v1/sync', headers=self.headers, content=b'a' * 512001)
        self.assertEqual(response.status_code, 413)

    def test_quota_rolls_back_entire_batch(self):
        self.client.close()
        self.app = create_app(replace(self.config, metadata_quota=1))
        self.client = TestClient(self.app)
        self.assertEqual(self.sync([self.event()]).status_code, 413)
        self.assertEqual(self.client.get('/v1/bootstrap', headers=self.headers).json()['records'], [])


if __name__ == '__main__':
    unittest.main()
