import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release_metadata import parse_version, require_newer, verify_identity


class ReleaseSafetyTest(unittest.TestCase):
    def setUp(self):
        self.certificate = 'Number of signers: 1\nSigner #1 certificate SHA-256 digest: abc123'
        self.badging = (
            "package: name='dev.ilyamedve.fivemore' versionCode='6' versionName='0.5.1'\n"
            "sdkVersion:'26'\nnative-code: 'arm64-v8a' 'x86_64' 'armeabi-v7a'\n"
        )

    def verify(self, badging=None, certificate=None):
        verify_identity(badging or self.badging, certificate or self.certificate, '0.5.1', 6, 'abc123')

    def test_version_code_is_explicit(self):
        self.assertEqual(parse_version('name: app\nversion: 0.5.1+6\n'), ('0.5.1', 6))
        for version in ['0.5.1', '0.5.1+0', '0.5.1-beta+6', '01.5.1+6', '0.5.1+2100000001']:
            with self.subTest(version=version), self.assertRaises(ValueError):
                parse_version(f'version: {version}\n')

    def test_both_versions_must_increase(self):
        require_newer('0.5.1', 6, '0.5.0', 5)
        for version, code in [('0.5.0', 6), ('0.4.9', 7), ('0.5.1', 5), ('0.5.1', 4)]:
            with self.subTest(version=version, code=code), self.assertRaises(ValueError):
                require_newer(version, code, '0.5.0', 5)

    def test_valid_update_and_arbitrary_abi_order(self):
        self.verify()

    def test_wrong_identity_cannot_be_published(self):
        for before, after in [('fivemore', 'otherapp'), ("versionCode='6'", "versionCode='5'"),
                              ("versionName='0.5.1'", "versionName='0.5.0'")]:
            with self.subTest(after=after), self.assertRaises(ValueError):
                self.verify(badging=self.badging.replace(before, after))

    def test_different_or_extra_signer_cannot_be_published(self):
        for cert in [self.certificate.replace('abc123', 'fff'),
                     self.certificate + '\nSigner #2 certificate SHA-256 digest: abc123',
                     self.certificate.replace('Number of signers: 1', 'Number of signers: 2')]:
            with self.subTest(cert=cert), self.assertRaises(ValueError):
                self.verify(certificate=cert)

    def test_build_tools_37_scheme_labels(self):
        for label in ['V2 Signer:', 'V3.0 Signer:', 'V3.1 Signer:', 'V3.2 Signer:']:
            with self.subTest(label=label):
                self.verify(certificate=self.certificate.replace('Signer #1', label))
        self.verify(certificate='Number of signers: 1\n'
                    'V2 Signer: certificate SHA-256 digest: abc123\n'
                    'V3.0 Signer: certificate SHA-256 digest: abc123')

    def test_unreadable_or_mixed_scheme_signatures_are_rejected(self):
        for cert in ['Number of signers: 1\nUnrecognized certificate format',
                     'Number of signers: 1\nV2 Signer: certificate SHA-256 digest: abc123\n'
                     'V3.0 Signer: certificate SHA-256 digest: fff']:
            with self.subTest(cert=cert), self.assertRaises(ValueError):
                self.verify(certificate=cert)

    def test_debug_and_network_permissions_cannot_be_published(self):
        for line in ['application-debuggable', "uses-permission: name='android.permission.INTERNET'"]:
            with self.subTest(line=line), self.assertRaises(ValueError):
                self.verify(badging=self.badging + line)

    def test_unsupported_android_or_missing_abi_cannot_be_published(self):
        for badging in [self.badging.replace("sdkVersion:'26'", "sdkVersion:'28'"),
                        self.badging.replace(" 'armeabi-v7a'", '')]:
            with self.subTest(badging=badging), self.assertRaises(ValueError):
                self.verify(badging=badging)


if __name__ == '__main__':
    unittest.main()
