"""Exercise the real iOS software keyboard and built-in engine settings."""
import json
from pathlib import Path
import subprocess


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


devices = json.loads(run('xcrun', 'simctl', 'list', 'devices', 'available', '--json', capture_output=True, text=True).stdout)
phones = [device for runtime, group in devices['devices'].items() if 'iOS-27' in runtime
          for device in group if 'iPhone' in device['name'] and device.get('isAvailable')]
if not phones:
    raise RuntimeError('No available iOS 27 iPhone Simulator')
device = sorted(phones, key=lambda d: (d['state'] != 'Booted', d['name'] != 'iPhone 16', d['name']))[0]
identifier = device['udid']
run('defaults', 'write', 'com.apple.iphonesimulator', 'ConnectHardwareKeyboard', '-bool', 'NO')
if device['state'] != 'Booted':
    run('xcrun', 'simctl', 'boot', identifier)
run('xcrun', 'simctl', 'bootstatus', identifier, '-b', timeout=240)
run('xcodebuild', 'test', '-project', 'MediaPocket.xcodeproj', '-scheme', 'MediaPocketKeyboardUI',
    '-configuration', 'Debug', '-destination', f'id={identifier}', '-derivedDataPath', 'build/Simulator',
    '-resultBundlePath', 'build/KeyboardTests.xcresult', '-parallel-testing-enabled', 'NO',
    '-test-timeouts-enabled', 'YES', '-maximum-test-execution-time-allowance', '120',
    'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-', 'CODE_SIGNING_REQUIRED=NO', timeout=600)
attachments = Path('build/artifacts/keyboard-ui')
attachments.mkdir(parents=True, exist_ok=True)
run('xcrun', 'xcresulttool', 'export', 'attachments', '--path', 'build/KeyboardTests.xcresult', '--output-path', str(attachments))
Path('build/artifacts/keyboard-tests.json').write_text(json.dumps({
    'passed': True, 'device': device['name'], 'physicalIphone': False,
    'checks': ['software keyboard shown', 'visible dismissal button', 'keyboard closed twice',
               'input URL retained', 'native engine ready', 'built-in engine settings visible', 'no external setup actions'],
}, indent=2) + '\n')
