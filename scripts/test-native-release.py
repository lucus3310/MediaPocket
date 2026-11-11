"""Verify the embedded C/Swift/Python boundary with optimized Release code."""
import json
from pathlib import Path
import subprocess


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


devices = json.loads(run('xcrun', 'simctl', 'list', 'devices', 'available', '--json', capture_output=True, text=True).stdout)
phones = [device for runtime, group in devices['devices'].items() if 'iOS-27' in runtime
          for device in group if 'iPhone' in device['name'] and device.get('isAvailable')]
device = sorted(phones, key=lambda d: (d['state'] != 'Booted', d['name'] != 'iPhone 16', d['name']))[0]
identifier = device['udid']
if device['state'] != 'Booted':
    run('xcrun', 'simctl', 'boot', identifier)
run('xcrun', 'simctl', 'bootstatus', identifier, '-b', timeout=240)
run('xcrun', 'simctl', 'keychain', identifier, 'add-root-cert', 'build/https-fixture/localhost-cert.cer')
# Release must produce new reports; a zero-test run cannot reuse Debug evidence.
lookup = subprocess.run(['xcrun', 'simctl', 'get_app_container', identifier,
                         'io.github.lucus3310.MediaPocket', 'data'], capture_output=True, text=True)
if lookup.returncode == 0:
    reports = Path(lookup.stdout.strip()) / 'Documents/NativeEngineTests'
    for name in ['native-engine-tests.json', 'native-js-tests.json']:
        (reports / name).unlink(missing_ok=True)
run('xcodebuild', 'test', '-project', 'MediaPocket.xcodeproj', '-scheme', 'MediaPocketNativeRelease',
    '-configuration', 'Release', '-destination', f'id={identifier}', '-derivedDataPath', 'build/Simulator',
    '-resultBundlePath', 'build/NativeReleaseTests.xcresult', '-parallel-testing-enabled', 'NO',
    '-test-timeouts-enabled', 'YES', '-maximum-test-execution-time-allowance', '180',
    'ENABLE_TESTABILITY=YES', 'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-', 'CODE_SIGNING_REQUIRED=NO', timeout=900)
container = Path(run('xcrun', 'simctl', 'get_app_container', identifier,
                     'io.github.lucus3310.MediaPocket', 'data', capture_output=True, text=True).stdout.strip())
for source, output in [('native-engine-tests.json', 'native-release-tests.json'), ('native-js-tests.json', 'native-release-js-tests.json')]:
    report = json.loads((container / 'Documents/NativeEngineTests' / source).read_text())
    if not report.get('passed'):
        raise RuntimeError('Optimized embedded engine failed: ' + source)
    report.update(configuration='Release', optimization='-O', physicalIphone=False)
    Path('build/artifacts', output).write_text(json.dumps(report, indent=2) + '\n')
