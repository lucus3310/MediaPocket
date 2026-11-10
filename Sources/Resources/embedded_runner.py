"""App-owned CPython entry point. Never launches another app or process."""
import importlib
import json
import os
from pathlib import Path
import time
import types

import _mediapocket
import certifi
import runner

os.environ['SSL_CERT_FILE'] = certifi.where()
os.environ['REQUESTS_CA_BUNDLE'] = certifi.where()
_plugins_loaded = False


class NativeRuntime:
    def run(self, arguments, stdout, stderr):
        return _mediapocket.execute(json.dumps([str(arg) for arg in arguments]), str(stdout), str(stderr))

    def callback(self, job_id=None, token=None):
        pass  # Swift observes the same local status; no application handoff.


def health(root, runtime):
    global _plugins_loaded
    status = dict(phase='initializing', message='正在檢查內建 FFmpeg 與解析器…', token='native', updated=time.time())
    runner.atomic_json(root / 'native-engine.json', status)
    try:
        for module in ('ssl', 'ctypes', 'yt_dlp', 'yt_dlp_ejs'):
            importlib.import_module(module)
        from yt_dlp.plugins import load_all_plugins
        if not _plugins_loaded:
            load_all_plugins()
            _plugins_loaded = True
        for module in ('yt_dlp_plugins.extractor.threads', 'yt_dlp_plugins.extractor.webkit_jsi', 'yt_dlp_plugins.extractor.ytjsc'):
            importlib.import_module(module)
        if runtime.run(['ffmpeg', '-hide_banner', '-encoders'], root / 'native-encoders.txt', root / 'native-error.txt'):
            raise RuntimeError('內建 FFmpeg 未能啟動。')
        if 'aac' not in (root / 'native-encoders.txt').read_text():
            raise RuntimeError('內建 FFmpeg 編碼器清單無法讀取。')
        # Use a closed loopback port to exercise the HTTPS protocol resolver.
        # A connection-refused exit is EXPECTED; "Protocol not found" is not.
        # This avoids depending on a public website for each app launch.
        probe_error = root / 'native-https-check.txt'
        runtime.run(['ffmpeg', '-hide_banner', '-nostdin', '-loglevel', 'error',
                     '-rw_timeout', '1000000', '-i',
                     'https://127.0.0.1:1/mediapocket-health-check',
                     '-f', 'null', '-'],
                    root / 'native-https-output.txt', probe_error)
        diagnostic = probe_error.read_text(errors='replace').lower() if probe_error.is_file() else ''
        if 'protocol not found' in diagnostic:
            raise RuntimeError('iOS 內建 FFmpeg 缺少 HTTPS／TLS 支援，無法下載網路影片。請重新編譯安裝支援 SecureTransport 的 IPA。')
        if not diagnostic:
            raise RuntimeError('無法確認內建 FFmpeg 的 HTTPS 能力，請查看 native-https-check.txt。')
        status.update(phase='ready', message='內建 FFmpeg HTTPS 下載協定與 yt-dlp 解析器已就緒。')
    except Exception as error:
        status.update(phase='failed', message=runner.safe_error(error))
    status['updated'] = time.time()
    runner.atomic_json(root / 'native-engine.json', status)


def run(action, directory, job):
    root = Path(directory)
    root.mkdir(parents=True, exist_ok=True)
    runtime = NativeRuntime()
    if action == 'health':
        health(root, runtime)
    elif action == 'smoke':
        # Included only in Debug builds; actual iOS framework integration test.
        from native_engine_smoke import smoke
        smoke(root, runtime)
    elif action == 'js-smoke':
        from native_engine_smoke import javascript
        javascript(root)
    elif action in ('probe', 'download'):
        try:
            runner.run_job(root, job, runtime, probe=action == 'probe')
        except Exception as error:
            runner.record_startup_failure(root, types.SimpleNamespace(setup=False, job=job), error)
    else:
        raise ValueError('Unknown embedded operation')
    return 0
