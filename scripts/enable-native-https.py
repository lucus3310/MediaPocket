"""Enable iOS HTTPS in libavformat without replacing the existing codec build."""
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys


def dylib_major(path):
    data = path.read_bytes()
    if data[:4] == b'\xca\xfe\xba\xbe':
        for index in range(struct.unpack_from('>I', data, 4)[0]):
            cpu, _, offset, size, _ = struct.unpack_from('>IIIII', data, 8 + index * 20)
            if cpu == 0x100000c:
                data = data[offset:offset + size]
                break
    if data[:4] != b'\xcf\xfa\xed\xfe':
        raise RuntimeError('Expected an ARM64 Mach-O framework: ' + str(path))
    offset = 32
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        command, size = struct.unpack_from('<II', data, offset)
        if command == 0xd:
            return struct.unpack_from('<I', data, offset + 16)[0] >> 16
        offset += size
    raise RuntimeError('Framework has no dylib version: ' + str(path))


def enable(root):
    stamp = root / '.mediapocket-libavformat-https.json'
    if stamp.is_file():
        record = json.loads(stamp.read_text())
        if all(hashlib.sha256((root / name).read_bytes()).hexdigest() == digest
               for name, digest in record['binaries'].items()):
            return
    if sys.platform != 'darwin':
        raise RuntimeError('HTTPS-enabled iOS FFmpeg must be built on macOS')
    configure = root / 'scripts/apple/ffmpeg.sh'
    source = configure.read_text()
    old = '  --disable-securetransport '
    if source.count(old) != 1:
        raise RuntimeError('Pinned FFmpeg TLS configuration changed')
    configure.write_text(source.replace(old, '  --enable-securetransport ', 1))
    if not (root / '.git').exists():
        subprocess.run(['git', 'init', '-q'], cwd=root, check=True)
        subprocess.run(['git', '-c', 'user.name=MediaPocket CI', '-c', 'user.email=ci@invalid.example',
                        'commit', '-q', '--allow-empty', '-m', 'Pinned FFmpeg source build'], cwd=root, check=True)
    # Only the FFmpeg library outputs are needed. The upstream XCFramework
    # packager also rebuilds its CLI wrapper, which this app already bundles.
    log = root / 'mediapocket-https-build.log'
    with log.open('w') as output:
        result = subprocess.run(['bash', 'ios.sh', '--no-bitcode', '--disable-x86-64', '--no-framework'],
                                cwd=root, stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        for path in [log, root / 'build.log']:
            if path.is_file(): print(path.read_text(errors='replace')[-16000:])
        raise RuntimeError('FFmpeg HTTPS source build failed')
    candidates = list((root / 'prebuilt').glob('*/ffmpeg/lib/libavformat.dylib'))
    bundle = root / 'Frameworks/libavformat.xcframework'
    info = plistlib.loads((bundle / 'Info.plist').read_bytes())
    binaries = {}
    for simulator in [False, True]:
        matches = [path for path in candidates if ('simulator' in str(path)) == simulator and 'arm64' in str(path)]
        if len(matches) != 1:
            raise RuntimeError('Expected one libavformat per iOS platform: ' + str(candidates))
        source = matches[0]
        if b'--enable-securetransport' not in source.read_bytes():
            raise RuntimeError('Built libavformat has no SecureTransport configuration')
        library = next(item for item in info['AvailableLibraries'] if item['SupportedPlatform'] == 'ios'
                       and (item.get('SupportedPlatformVariant') == 'simulator') == simulator)
        target = bundle / library['LibraryIdentifier'] / 'libavformat.framework/libavformat'
        if dylib_major(source) != dylib_major(target):
            raise RuntimeError('Refusing incompatible libavformat ABI')
        identity = subprocess.check_output(['otool', '-D', str(source)], text=True)
        if '@rpath/libavformat.framework/libavformat' not in identity:
            raise RuntimeError('Built libavformat install name is not framework-compatible: ' + identity)
        shutil.copy2(source, target)
        library['SupportedArchitectures'] = ['arm64']
        binaries[str(target.relative_to(root))] = hashlib.sha256(target.read_bytes()).hexdigest()
    (bundle / 'Info.plist').write_bytes(plistlib.dumps(info))
    revision = subprocess.check_output(['git', '-C', str(root / 'src/ffmpeg'), 'rev-parse', 'HEAD'], text=True).strip()
    stamp.write_text(json.dumps({'backend': 'Apple SecureTransport', 'sourceCommit': revision,
                                 'preservedExistingCodecLibraries': True, 'binaries': binaries}, indent=2))
    print('HTTPS-enabled ARM64 libavformat installed; existing codecs and CLI preserved')


if __name__ == '__main__':
    enable(Path(sys.argv[1]).resolve())
