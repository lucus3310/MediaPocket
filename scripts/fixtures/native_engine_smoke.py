"""Debug-only test, executed by the bundled iOS CPython and FFmpeg frameworks."""
import contextlib
import functools
import http.server
import json
from pathlib import Path
import threading
import uuid

import runner
import download_engine


def javascript(root):
    from yt_dlp_plugins.webkit_jsi.lib.easy import WKJSE_Factory, WKJSE_Webview
    from yt_dlp_plugins.webkit_jsi.lib.logging import DefaultLoggerImpl
    # The vendor's SCRIPT_TEMPL ends in .then(() => restoreWebKit), which
    # discards JS return values. EJS receives results through console.log.
    messages = []
    delivered = threading.Event()
    def on_log(message):
        messages.append(message)
        if message.get('logType') == 2 and message.get('argsArr') == [3]:
            delivered.set()
    with WKJSE_Factory(DefaultLoggerImpl()) as send:
        with WKJSE_Webview(send) as webview:
            webview.on_script_log(on_log)
            webview.execute_js('console.log(1 + 2);')
            assert delivered.wait(5), 'WebKit console result missing: ' + repr(messages)
    runner.atomic_json(root / 'native-js-tests.json', dict(passed=True, physicalIphone=False,
        execution='bundled WebKit JSI console channel on iOS Simulator', consoleResult=3))


def smoke(root, runtime):
    from yt_dlp import YoutubeDL

    root.mkdir(parents=True, exist_ok=True)
    def command(arguments, name):
        out, err = root / (name + '.out'), root / (name + '.err')
        result = runtime.run(arguments, out, err)
        assert result == 0, (arguments[0], result, err.read_text()[-3000:])
        return out

    # Exercise multiple calls in one process (CLI state must reset each time).
    command(['ffmpeg', '-hide_banner', '-y', '-f', 'lavfi', '-i', 'color=c=blue:s=320x180:r=30',
             '-t', '0.4', '-c:v', 'mpeg4', '-an', str(root / 'video.mp4')], 'fixture-video')
    command(['ffmpeg', '-hide_banner', '-y', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100',
             '-t', '0.4', '-c:a', 'aac', str(root / 'audio.m4a')], 'fixture-audio')
    metadata = command(['ffprobe', '-v', 'error', '-show_streams', '-of', 'json', str(root / 'video.mp4')], 'fixture-probe')
    assert json.loads(metadata.read_text())['streams'][0]['width'] == 320
    assert 'aac' in download_engine.encoder_set(runtime, root)

    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *_): pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=str(root)))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = 'http://127.0.0.1:' + str(server.server_port)
    entry = dict(id='native-fixture', title='Native HTTP fixture', duration=0.4,
                 formats=[dict(format_id='v', url=base + '/video.mp4', protocol='http', ext='mp4',
                               vcodec='mpeg4', acodec='none', width=320, height=180, fps=30),
                          dict(format_id='a', url=base + '/audio.m4a', protocol='http', ext='m4a',
                               vcodec='none', acodec='aac', abr=128)])
    @contextlib.contextmanager
    def extraction(request, bridge):
        with YoutubeDL(dict(quiet=True, no_warnings=True, skip_download=True, js_runtimes={})) as ydl:
            yield ydl, [dict(entry)]
    (root / 'jobs').mkdir(exist_ok=True)
    results = []
    try:
        for mode, profile in [('fast', 'auto'), (None, 'original'), ('fast', 'mp3')]:
            job, token = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
            slot = root / 'jobs' / job
            slot.mkdir()
            request = dict(id=job, token=token, url='https://youtu.be/native-fixture', platform='youtube',
                           quality='best', audioOnly=False, method='native', requiresSelection=True,
                           transferMode=mode, connections=2)
            runner.atomic_json(slot / 'request.json', request)
            runner.run_job(root, job, runtime, extraction=extraction, probe=True)
            catalog = json.loads((slot / 'catalog.json').read_text())
            selection = next(option for option in catalog['options'] if option['audioOnly'] == (profile == 'mp3'))
            request.update(selection=selection['id'], audioOnly=selection['audioOnly'], outputProfile=profile)
            runner.atomic_json(slot / 'request.json', request)
            runner.run_job(root, job, runtime, extraction=extraction)
            status = json.loads((slot / 'status.json').read_text())
            diagnostic = (slot / 'ffmpeg-error.txt').read_text(errors='replace') if (slot / 'ffmpeg-error.txt').exists() else ''
            assert status['phase'] == 'complete', (status, diagnostic[-3000:])
            assert len(status['outputs']) == 1
            metadata = json.loads((slot / 'probe.json').read_text())
            types = {stream['codec_type'] for stream in metadata['streams']}
            assert types == ({'audio'} if profile == 'mp3' else {'video', 'audio'}), types
            results.append(dict(mode=mode or 'FFmpeg HTTP', profile=profile, streams=sorted(types)))
    finally:
        server.shutdown()
        server.server_close()
    runner.atomic_json(root / 'native-engine-tests.json', dict(passed=True, physicalIphone=False,
        execution='in-process CPython + FFmpeg on iOS Simulator',
        checks=results, repeatedCLI=True, ffprobeJSON=True))
