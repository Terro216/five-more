#!/usr/bin/env python3
"""Validate release identity and package only verified, consistently signed APKs."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
VERSION = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
PACKAGE = "dev.ilyamedve.fivemore"


def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def parse_version(pubspec):
    match = re.search(rf"^version: ({VERSION})\+([1-9][0-9]*)$", pubspec, re.M)
    if not match:
        raise ValueError("pubspec.yaml must contain version: X.Y.Z+positiveVersionCode")
    version, code = match[1], int(match[5])
    if code > 2100000000:
        raise ValueError("Android versionCode exceeds its supported range")
    return version, code


def require_newer(version, code, previous_version, previous_code):
    if tuple(map(int, version.split('.'))) <= tuple(map(int, previous_version.split('.'))):
        raise ValueError(f"Version must be greater than published tag v{previous_version}")
    if code <= previous_code:
        raise ValueError(f"versionCode must be greater than {previous_code}")


def validate(tag):
    version, code = parse_version((ROOT / 'pubspec.yaml').read_text())
    if tag != f'v{version}':
        raise ValueError("Release tag must match pubspec.yaml exactly")
    notes = ROOT / 'docs/releases' / f'{tag}.md'
    if not notes.is_file() or not notes.read_text().strip():
        raise ValueError(f"Missing release notes: docs/releases/{tag}.md")
    for old_tag in run('git', 'tag', '--list', 'v*').splitlines():
        if old_tag == tag or not re.fullmatch(rf'v{VERSION}', old_tag):
            continue
        old_version, old_code = parse_version(run('git', 'show', f'{old_tag}:pubspec.yaml'))
        require_newer(version, code, old_version, old_code)
    print(f'{tag}: Android versionCode {code}; release version checks passed')


def verify_identity(badging, certificate, version, code, expected_certificate):
    match = re.search(r"package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'", badging)
    if not match or match.groups() != (PACKAGE, str(code), version):
        raise ValueError('APK package/version differs from the release source')
    if not re.search(r'^Number of signers: 1$', certificate, re.M):
        raise ValueError('Release APK must have exactly one signer')
    # Build-tools 37 prints scheme labels ("V2 Signer:") instead of "Signer #1".
    # The same certificate may be reported once for each verified scheme.
    signers = re.findall(
        r'^(Signer #\d+|V[1-4](?:\.\d+)? Signer:) certificate SHA-256 digest: ([0-9a-fA-F]+)$',
        certificate, re.M)
    if not signers:
        raise ValueError('No readable signing certificate in apksigner output')
    if any(label.startswith('Signer #') and label != 'Signer #1' for label, _ in signers):
        raise ValueError('Unexpected additional APK signer')
    if {digest.lower() for _, digest in signers} != {expected_certificate.lower()}:
        raise ValueError('APK signing certificate differs from the established update key')
    if 'application-debuggable' in badging:
        raise ValueError('A debuggable APK cannot be published')
    if "sdkVersion:'26'" not in badging:
        raise ValueError('Unexpected minimum Android version')
    if 'android.permission.INTERNET' in badging:
        raise ValueError('The offline pilot must not request network access')
    if "native-code: 'armeabi-v7a' 'arm64-v8a' 'x86_64'" not in badging:
        # aapt may change ABI order between build-tools versions.
        abi_line = next((line for line in badging.splitlines() if line.startswith('native-code:')), '')
        if set(re.findall(r"'([^']+)'", abi_line)) != {'armeabi-v7a', 'arm64-v8a', 'x86_64'}:
            raise ValueError('Release APK must contain all three supported Android ABIs')


def package(apk, output):
    version, code = parse_version((ROOT / 'pubspec.yaml').read_text())
    sdk = os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
    if not sdk:
        raise ValueError('Set ANDROID_HOME to the Android SDK directory')
    candidates = [path for path in (Path(sdk) / 'build-tools').iterdir()
                  if re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', path.name)]
    build_tools = max(candidates, key=lambda path: tuple(map(int, path.name.split('.'))))
    print(f'Verifying APK with Android build-tools {build_tools.name}')
    certificate = run(str(build_tools / 'apksigner'), 'verify', '--verbose', '--print-certs', str(apk.resolve()))
    badging = run(str(build_tools / 'aapt'), 'dump', 'badging', str(apk.resolve()))
    expected = (ROOT / '.android-signing-certificate.sha256').read_text().strip()
    verify_identity(badging, certificate, version, code, expected)
    output.mkdir(parents=True, exist_ok=True)
    name = f'five-more-{version}-universal.apk'
    target = output / name
    shutil.copyfile(apk, target)
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    metadata = {
        'version': version, 'version_code': code, 'package': PACKAGE,
        'source_commit': run('git', 'rev-parse', 'HEAD'),
        'apk': name, 'sha256': digest, 'bytes': target.stat().st_size,
        'certificate_sha256': expected, 'build_mode': 'release',
        'abis': ['armeabi-v7a', 'arm64-v8a', 'x86_64'],
        'flutter': (ROOT / '.flutter-version').read_text().strip(),
        'flutter_revision': (ROOT / '.flutter-revision').read_text().strip(),
        'android_build_tools': build_tools.name,
        'physical_device_validation': 'not performed by CI; requires explicit user report',
    }
    if os.environ.get('GITHUB_RUN_ID'):
        metadata['workflow_url'] = (
            f"https://github.com/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}")
    (output / f'five-more-{version}-sha256.txt').write_text(f'{digest}  {name}\n')
    (output / f'five-more-{version}-build-info.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print(f'Verified {name}: package, version, certificate, offline permissions and ABIs')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    check = commands.add_parser('validate')
    check.add_argument('--tag', required=True)
    build = commands.add_parser('package')
    build.add_argument('--apk', required=True, type=Path)
    build.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    try:
        if args.command == 'validate':
            validate(args.tag)
        else:
            package(args.apk, args.output)
    except (ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Release validation failed: {error}\n')


if __name__ == '__main__':
    main()
