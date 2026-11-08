"""Xcode post-build: stdlib + Python extension frameworks, for unsigned/device and simulator."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

root = Path(os.environ['PROJECT_DIR'])
app = Path(os.environ['TARGET_BUILD_DIR']) / os.environ['WRAPPER_NAME']
native = root / 'build/native'
frameworks = app / 'Frameworks'
frameworks.mkdir(exist_ok=True)
stdlib = app / 'python/lib'
stdlib.mkdir(parents=True, exist_ok=True)
simulator = os.environ['PLATFORM_NAME'] == 'iphonesimulator'
slice_name = 'ios-arm64_x86_64-simulator' if simulator else 'ios-arm64'
python = native / 'Python.xcframework'
shutil.copytree(python / 'lib', stdlib, dirs_exist_ok=True, ignore=shutil.ignore_patterns('libpython*.dylib', '__pycache__', 'test', 'tests'))
shutil.copytree(python / slice_name / 'lib-arm64', stdlib, dirs_exist_ok=True,
                ignore=shutil.ignore_patterns('libpython*.dylib', '__pycache__'))
shutil.copytree(native / 'packages', app / 'python-packages', dirs_exist_ok=True,
                ignore=shutil.ignore_patterns('__pycache__', '*.pyc', 'bin'))
if os.environ['CONFIGURATION'] == 'Debug' or simulator:
    shutil.copy2(root / 'scripts/fixtures/native_engine_smoke.py', app / 'native_engine_smoke.py')
else:
    (app / 'native_engine_smoke.py').unlink(missing_ok=True)
for binary in list(stdlib.rglob('*.so')):
    relative = binary.relative_to(app)
    module = binary.name.split('.')[0]
    if module.startswith(('_test', 'xx')):
        binary.unlink()
        continue
    folder = frameworks / (module + '.framework')
    folder.mkdir(exist_ok=True)
    target = folder / module
    shutil.copy2(binary, target)
    binary.unlink()
    marker = binary.with_suffix('.fwork')
    marker.write_text(str(target.relative_to(app)))
    (folder / (module + '.origin')).write_text(str(marker.relative_to(app)))
    (folder / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'io.github.lucus3310.MediaPocket.python.' + module.replace('_', '-').strip('-'),
        'CFBundleExecutable': module, 'CFBundleName': module, 'CFBundlePackageType': 'FMWK',
        'CFBundleShortVersionString': '3.13', 'CFBundleVersion': '1', 'MinimumOSVersion': '18.0',
        'CFBundleSupportedPlatforms': ['iPhoneSimulator' if simulator else 'iPhoneOS'],
    }))
    if os.environ.get('CODE_SIGNING_ALLOWED') == 'YES':
        subprocess.run(['codesign', '--force', '--sign', os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') or '-', '--timestamp=none', str(folder)], check=True)
licenses = app / 'Native-LICENSES'
licenses.mkdir(exist_ok=True)
shutil.copy2(native / 'FFmpegKit/LICENSE', licenses / 'FFmpegKit-LICENSE.txt')
shutil.copy2(native / 'manifest.json', licenses / 'native-build.json')
for source in python.rglob('LICENSE*'):
    if source.is_file():
        shutil.copy2(source, licenses / 'Python-LICENSE.txt')
        break
print('Embedded CPython stdlib, packages and extension frameworks into', app.name)
