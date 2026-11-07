"""Run the real AVPlayer/VLC sample-step tests on an available iOS Simulator."""
import json
from pathlib import Path
import subprocess
import shutil
import os
import time


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


devices = json.loads(run('xcrun', 'simctl', 'list', 'devices', 'available', '--json', capture_output=True, text=True).stdout)
phones = [device for runtime, group in devices['devices'].items() if 'iOS-27' in runtime
          for device in group if 'iPhone' in device['name'] and device.get('isAvailable')]
if not phones:
    raise RuntimeError('No installed iOS 27 iPhone Simulator is available')
device = sorted(phones, key=lambda d: (d['name'] != 'iPhone 16', d['name']))[0]
identifier = device['udid']
print(f"Playback test device: {device['name']} ({identifier})", flush=True)
if device['state'] != 'Booted':
    run('xcrun', 'simctl', 'boot', identifier)
run('xcrun', 'simctl', 'bootstatus', identifier, '-b', timeout=240)
run('xcodebuild', 'test', '-project', 'MediaPocket.xcodeproj', '-scheme', 'MediaPocket',
    '-configuration', 'Debug', '-destination', f'id={identifier}',
    '-derivedDataPath', 'build/Simulator', '-resultBundlePath', 'build/PlaybackTests.xcresult',
    '-parallel-testing-enabled', 'NO', '-test-timeouts-enabled', 'YES',
    '-maximum-test-execution-time-allowance', '120',
    'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-', 'CODE_SIGNING_REQUIRED=NO', timeout=900)
Path('build/artifacts/playback-tests.json').write_text(json.dumps({
    'device': device['name'], 'result': 'passed', 'physicalIphone': False,
    'checks': ['CFR and VFR native adjacent-frame timestamps', 'VLC next and previous frame callbacks',
               '8x renderer transform, pan, player preservation and rotation reset',
               'multi-frame traversal follows adjacent samples', 'A-B looping on both engines and seek-outside disable'],
    'interfaceRenders': 'native SwiftUI dock at portrait and landscape sizes; not physical gesture tests'
}, indent=2) + '\n')
container = Path(run('xcrun', 'simctl', 'get_app_container', identifier,
                     'io.github.lucus3310.MediaPocket', 'data', capture_output=True, text=True).stdout.strip())
for name in ['PlayerDock-portrait.png', 'PlayerDock-landscape.png', 'DownloadCenter-home.png', 'DownloadCenter-quality.png', 'FormatSheet-advanced.png']:
    shutil.copyfile(container / 'Documents/InterfaceReview' / name, Path('build/artifacts') / name)

# Relaunch the actual app process; recreating a Swift store alone does not
# exercise URL bookmark resolution after the process has been terminated.
subprocess.run(['xcrun', 'simctl', 'terminate', identifier, 'io.github.lucus3310.MediaPocket'], capture_output=True, check=False)
environment = dict(os.environ, SIMCTL_CHILD_MEDIAPOCKET_SOURCE_PROBE='1')
run('xcrun', 'simctl', 'launch', identifier, 'io.github.lucus3310.MediaPocket', env=environment)
probe = container / 'Documents/SourceColdLaunchResult.json'
deadline = time.monotonic() + 45
while not probe.exists() and time.monotonic() < deadline:
    time.sleep(0.2)
report = json.loads(probe.read_text())
if not report.get('passed'):
    raise RuntimeError(f'Cold-launch source restoration failed: {report}')
shutil.copyfile(probe, Path('build/artifacts/source-restoration-tests.json'))
time.sleep(1)
run('xcrun', 'simctl', 'io', identifier, 'screenshot', 'build/artifacts/SourceLibrary-home.png')
