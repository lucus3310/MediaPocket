"""Fetch pinned, free iOS frameworks and pure-Python packages; no Apple account."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / 'build/native'
DEST.mkdir(parents=True, exist_ok=True)
SOURCES = {
    'python': ('https://github.com/beeware/Python-Apple-support/releases/download/3.13-b18/Python-3.13-iOS-support.b18.tar.gz',
               'd06acf2a9c7964a8689566353a0e707402eff822037de5e29ba0e16040f7047d'),
    'ffmpeg': ('https://github.com/jaywcjlove/ffmpeg-kit/archive/0bd85df8f9693061f6f979414662baaf876a3e20.tar.gz',
               'cc005b9c0c1916907537b7b7476c14d576fb147327a0a173e2686201a3611188'),
}
for name, (url, digest) in SOURCES.items():
    expected = DEST / ('Python.xcframework' if name == 'python' else 'FFmpegKit')
    # A cached TLS-enabled build must not be overwritten by the upstream binary.
    if name == 'ffmpeg' and (expected / '.mediapocket-https-enabled').is_file():
        continue
    archive = DEST / (name + '.tar.gz')
    if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
        with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'MediaPocket-Native'}), timeout=180) as response, archive.open('wb') as output:
            shutil.copyfileobj(response, output)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
        raise RuntimeError(name + ' archive checksum mismatch')
    expected = DEST / ('Python.xcframework' if name == 'python' else 'FFmpegKit')
    if not expected.exists():
        with tarfile.open(archive) as bundle:
            # Archives are pinned; still reject path traversal and escaping links.
            for member in bundle.getmembers():
                if member.name.startswith('/') or '..' in Path(member.name).parts:
                    raise RuntimeError('Unsafe native archive member')
            bundle.extractall(DEST, filter='data')
        if name == 'ffmpeg':
            (DEST / 'ffmpeg-kit-0bd85df8f9693061f6f979414662baaf876a3e20').rename(expected)

# The pinned upstream XCFramework is intentionally built with SecureTransport
# disabled. As a result it cannot open normal https:// media URLs even though
# localhost HTTP fixtures pass. Rebuild the same audited source for iOS with
# Apple's system TLS backend; no external OpenSSL or yt-dlp transfer is used.
ffmpeg_root = DEST / 'FFmpegKit'
tls_stamp = ffmpeg_root / '.mediapocket-https-enabled'
if not tls_stamp.is_file():
    configure = ffmpeg_root / 'scripts/apple/ffmpeg.sh'
    script = configure.read_text()
    disabled = '  --disable-securetransport ' + chr(92) + chr(10)
    enabled = '  --enable-securetransport ' + chr(92) + chr(10)
    if disabled not in script:
        raise RuntimeError('Pinned FFmpeg source no longer contains expected TLS configuration')
    configure.write_text(script.replace(disabled, enabled, 1))
    # The pinned source archive has no .git folder, but ios.sh uses git describe.
    if not (ffmpeg_root / '.git').exists():
        subprocess.run(['git', 'init', '-q'], cwd=ffmpeg_root, check=True)
        subprocess.run(['git', '-c', 'user.name=MediaPocket CI',
                        '-c', 'user.email=ci@invalid.example', 'commit', '-q',
                        '--allow-empty', '-m', 'Pinned HTTPS FFmpeg build'],
                       cwd=ffmpeg_root, check=True)
    subprocess.run(['bash', 'ios.sh', '--no-bitcode', '--disable-x86-64'],
                   cwd=ffmpeg_root, check=True)
    built = ffmpeg_root / 'prebuilt/bundle-apple-xcframework-ios'
    frameworks = ['ffmpegkit', 'libavcodec', 'libavdevice', 'libavfilter',
                  'libavformat', 'libavutil', 'libswresample', 'libswscale']
    for name in frameworks:
        source = built / (name + '.xcframework')
        target = ffmpeg_root / 'Frameworks' / source.name
        if not source.is_dir():
            raise RuntimeError('TLS FFmpeg build did not produce ' + source.name)
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(source, target)
    tls_stamp.write_text('SecureTransport enabled, ios.sh --no-bitcode --disable-x86-64\\n')
    # The package only consumes Sources/ and Frameworks/, not build objects.
    for directory in ('.tmp', 'src', 'prebuilt'):
        shutil.rmtree(ffmpeg_root / directory, ignore_errors=True)

# Resolve FFmpeg symbols from its own framework/dependencies rather than another
# player's bundled FFmpeg, while keeping the upstream serial execution API.
bridge = DEST / 'FFmpegKit/Sources/CFFmpegBridge/CFFmpegBridge.c'
source = bridge.read_text()
source = source.replace('return dlsym(RTLD_DEFAULT, name);',
    'void *handle = dlopen("@rpath/ffmpegkit.framework/ffmpegkit", RTLD_NOW | RTLD_GLOBAL);\n'
    '    return dlsym(handle ? handle : RTLD_DEFAULT, name);')
if 'static int (*fks_log_level)(void);' not in source:
    source = source.replace('static fks_execution_context *fks_current_context;',
        'static fks_execution_context *fks_current_context;\n'
        'static int (*fks_log_level)(void);')
    source = source.replace('fks_execution_context *execution = fks_current_context;',
        'fks_execution_context *execution = fks_current_context;\n'
        '    if (fks_log_level && level >= 0 && (level & 0xff) > fks_log_level()) return;', 1)
    source = source.replace('fks_current_context = &execution;',
        'fks_log_level = (int (*)(void))fks_symbol("av_log_get_level");\n'
        '    fks_current_context = &execution;')
bridge.write_text(source)
# The C callback retains only an opaque pointer. Keep its Swift owner alive
# explicitly through the native call, including optimized Release builds.
execution = DEST / 'FFmpegKit/Sources/FFmpegKit/Execution.swift'
source = execution.read_text()
source = source.replace('let opaque = Unmanaged.passUnretained(callbackContext).toOpaque()',
    'let opaque = Unmanaged.passRetained(callbackContext).toOpaque()\n'
    '        defer { Unmanaged<NativeCallbackContext>.fromOpaque(opaque).release() }')
execution.write_text(source)
packages = DEST / 'packages'
if not (packages / 'yt_dlp').exists():
    subprocess.run([sys.executable, '-m', 'pip', 'install', '--target', str(packages), '--only-binary=:all:', '--no-compile', '--no-deps',
                    'yt-dlp==2026.10.26', 'yt-dlp-ejs==0.8.0', 'yt-dlp-apple-webkit-jsi==0.1.1',
                    'yt-dlp-threads==0.1.0', 'certifi==2025.10.5'], check=True)
subprocess.run([sys.executable, str(ROOT / 'scripts/patch-resolver-webkit.py'),
                str(packages / 'yt_dlp_plugins/webkit_jsi/lib/api.py')], check=True)
(DEST / 'manifest.json').write_text(json.dumps({'python': '3.13-b18', 'ffmpegCommit': '0bd85df8f9693061f6f979414662baaf876a3e20',
    'archives': {name: digest for name, (_, digest) in SOURCES.items()}, 'execution': 'in-process; no shell or helper application'}, indent=2))
print('Pinned native FFmpeg and CPython are ready.')
