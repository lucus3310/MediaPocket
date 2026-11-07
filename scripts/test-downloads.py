#!/usr/bin/env python3
"""Offline contract tests plus real FFmpeg HTTP/track integration on macOS CI."""
import contextlib
import functools
from http.cookiejar import Cookie
import http.server
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
import uuid

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("runner", ROOT / "Sources/Resources/runner.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class StartupTests(unittest.TestCase):
    def test_runtime_failure_is_visible_and_persisted_for_setup(self):
        with tempfile.TemporaryDirectory() as temporary:
            bridge = Path(temporary)
            console = io.StringIO()
            with patch.object(runner, "__file__", str(bridge / "runner.py")), \
                 patch.object(runner, "Runtime", side_effect=RuntimeError("native API unavailable")), \
                 patch.object(sys, "argv", ["runner.py", "--setup"]), contextlib.redirect_stdout(console):
                runner.main()
            status = json.loads((bridge / "setup.json").read_text(encoding="utf-8"))
            self.assertEqual(status["phase"], "failed")
            self.assertIn("native API unavailable", status["message"])
            self.assertIn("MediaPocket", console.getvalue())

    def test_job_bootstrap_failure_keeps_token_and_does_not_overwrite_completion(self):
        with tempfile.TemporaryDirectory() as temporary:
            bridge = Path(temporary)
            job_id, token = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
            slot = bridge / "jobs" / job_id
            slot.mkdir(parents=True)
            (slot / "request.json").write_text(json.dumps({"id": job_id, "token": token}))
            for expected in ("failed", "complete"):
                if expected == "complete":
                    runner.atomic_json(slot / "status.json", {"phase": "complete", "token": token, "outputs": ["001.mkv"]})
                with patch.object(runner, "__file__", str(bridge / "runner.py")), \
                     patch.object(runner, "Runtime", side_effect=RuntimeError("unavailable https://cdn.test/?token=SECRET")), \
                     patch.object(sys, "argv", ["runner.py", "--job", job_id]), contextlib.redirect_stdout(io.StringIO()):
                    runner.main()
                status = json.loads((slot / "status.json").read_text(encoding="utf-8"))
                self.assertEqual(status["phase"], expected)
                self.assertEqual(status["token"], token)
                self.assertNotIn("SECRET", json.dumps(status))


class Contracts(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "darwin", "Apple WebKit provider requires Darwin")
    def test_apple_provider_import_contract(self):
        from yt_dlp.plugins import load_all_plugins
        load_all_plugins()
        import yt_dlp_ejs
        from yt_dlp_plugins.extractor.ytjsc import AppleWebKitJCP
        self.assertEqual(AppleWebKitJCP.PROVIDER_VERSION, "0.1.1")

    def test_routes_and_injection(self):
        valid = [("https://youtu.be/abc", "youtube"), ("https://www.instagram.com/reel/abc/", "instagram"),
                 ("https://www.threads.com/@u/post/Abc", "threads"), ("https://b23.tv/abc", "bilibili")]
        for url, platform in valid:
            self.assertEqual(runner.platform_for(url), platform)
        for url in ["https://youtube.com.evil.test/watch?v=abc", "file:///etc/passwd", "https://www.youtube.com/playlist?list=x"]:
            with self.assertRaises(ValueError):
                runner.platform_for(url)

    def test_safe_headers_and_explicit_mapping(self):
        inputs = [({"acodec": "none"}, "https://example.test/v?x=';echo%20bad", {"Referer": "https://www.bilibili.com/"}),
                  ({"acodec": "aac"}, "https://example.test/a", {"Cookie": "session=local"})]
        command = runner.ffmpeg_command(inputs, "out.mkv", "progress", False)
        self.assertIn("1:a:0?", command)
        self.assertIn("0:v:0", command)
        self.assertIn("copy", command)
        self.assertIn("Cookie: session=local\r\n", command)
        inputs[0][2]["Referer"] = "value\r\nInjected: yes"
        with self.assertRaises(ValueError):
            runner.ffmpeg_command(inputs, "out.mkv", "progress", False)

    def test_status_redaction(self):
        text = runner.safe_error(ValueError("failed https://cdn.test/file?token=SECRET Cookie: PRIVATE"))
        self.assertNotIn("SECRET", text)
        self.assertNotIn("PRIVATE", text)

    def test_real_ytdlp_cookiejar_contract(self):
        from yt_dlp.cookies import YoutubeDLCookieJar
        jar = YoutubeDLCookieJar()
        jar.set_cookie(Cookie(0, "session", "local", None, False, "cdn.test", False, False,
                              "/", True, True, None, True, None, None, {}))
        class YDL:
            cookiejar = jar
        inputs = runner.inputs_for({"url": "https://cdn.test/video.mp4", "protocol": "https", "acodec": "aac"}, YDL(), False)
        self.assertEqual(inputs[0][2]["Cookie"], "session=local")

    def test_native_runtime_quotes_untrusted_arguments(self):
        import shlex
        runtime = runner.Runtime()
        captured = []
        runtime.native = lambda command: captured.append(command.decode()) or 0
        runtime.fork = lambda: 7
        runtime.wait_full = lambda pid, status, options: pid
        runtime.release = lambda pid: None
        url = "https://cdn.test/file?x=';echo SECRET&y=1"
        runtime.run(["ffmpeg", "-i", url, "a file.mkv"], "stdout file", "stderr file")
        self.assertEqual(shlex.split(captured[0]), ["ffmpeg", "-i", url, "a file.mkv", ">", "stdout file", "2>", "stderr file"])

    def test_native_runtime_waits_and_returns_child_exit_status(self):
        runtime = runner.Runtime()
        events = []
        runtime.fork = lambda: events.append("fork") or 7
        runtime.native = lambda command: events.append("dispatch") or 0
        def wait(pid, status, options):
            events.append("wait")
            status._obj.value = 37 << 8
            return pid
        runtime.wait_full = wait
        runtime.release = lambda pid: events.append("release")
        self.assertEqual(runtime.call_native("ffmpeg -version"), 37)
        self.assertEqual(events, ["fork", "dispatch", "wait", "release"])

    def test_threads_selects_target_and_refuses_ambiguous_share(self):
        from yt_dlp import YoutubeDL
        target = {"code": "Target", "video_versions": [{"url": "https://cdn.test/target.mp4", "width": 640, "height": 360}],
                  "original_width": 640, "original_height": 360, "user": {"username": "u"}}
        recommended = dict(target, code="Other", video_versions=[{"url": "https://cdn.test/WRONG.mp4"}])
        page = '<script type="application/json">' + json.dumps([recommended, target]) + '</script>'
        adapter = runner.strict_threads_extractor()
        with YoutubeDL({"quiet": True, "format": runner.format_selector("1080", False)}) as ydl:
            ydl.add_info_extractor(adapter)
            with patch.object(adapter, "_download_webpage", return_value=page):
                result = adapter._real_extract("https://www.threads.com/@u/post/Target")
                self.assertEqual(result["id"], "Target")
                self.assertTrue(all("WRONG" not in item["url"] for item in result["formats"]))
                processed = ydl.extract_info("https://www.threads.com/@u/post/Target", download=False, ie_key=adapter.ie_key())
                selected = runner.inputs_for(processed, ydl, False)
                self.assertEqual(selected[0][1], "https://cdn.test/target.mp4")
                self.assertEqual(selected[0][2]["Referer"], "https://www.threads.com/")
                with self.assertRaises(Exception):
                    adapter._real_extract("https://www.threads.com/@u/post/Missing")
                with self.assertRaises(Exception):
                    adapter._real_extract("https://www.threads.com/share/unknown")


class QualityCatalogTests(unittest.TestCase):
    def entry(self, identity="one", heights=(360, 720, 1080)):
        formats = [{"format_id": str(height), "height": height, "vcodec": "h264", "acodec": "none",
                    "protocol": "https", "url": f"https://cdn.test/{height}?token=PRIVATE"} for height in heights]
        formats += [{"format_id": "audio", "vcodec": "none", "acodec": "aac", "protocol": "https", "url": "https://cdn.test/audio"},
                    {"height": 2160, "vcodec": "av1", "has_drm": True, "url": "https://cdn.test/drm"},
                    {"height": 4320, "vcodec": "av1", "protocol": "http_dash_segments", "url": "https://cdn.test/dash"}]
        return {"id": identity, "title": "Fixture", "formats": formats}

    def test_catalog_contains_actual_common_qualities_without_source_urls(self):
        entries = [self.entry(), self.entry("two", (720,))]
        catalog = runner.quality_catalog(entries, "token")
        self.assertEqual([option["id"] for option in catalog["options"]], ["video:best", "video:720", "audio:best"])
        self.assertNotIn("PRIVATE", json.dumps(catalog))
        self.assertNotIn("https://", json.dumps(catalog))
        chosen = runner.apply_selection(entries, catalog, "video:720")
        self.assertTrue(all(entry["requested_formats"][0]["height"] == 720 for entry in chosen))
        self.assertTrue(all(entry["requested_formats"][1]["acodec"] == "aac" for entry in chosen))
        best = runner.apply_selection(entries, catalog, "video:best")
        self.assertEqual([entry["requested_formats"][0]["height"] for entry in best], [1080, 720])

    def test_stale_resolution_and_changed_post_never_silently_downgrade(self):
        catalog = runner.quality_catalog([self.entry()], "token")
        for entries, selection in [([self.entry(heights=(360,))], "video:1080"),
                                   ([self.entry("different")], "video:720"),
                                   ([self.entry()], "video:2160")]:
            with self.assertRaises(ValueError):
                runner.apply_selection(entries, catalog, selection)
        with self.assertRaises(ValueError):
            runner.quality_catalog([dict(self.entry(), is_live=True)], "token")

    def test_audio_and_unknown_resolution_are_not_fabricated(self):
        entry = {"id": "silent", "formats": [{"url": "https://cdn.test/silent", "vcodec": "h264", "acodec": "none"}]}
        catalog = runner.quality_catalog([entry], "token")
        self.assertEqual([option["id"] for option in catalog["options"]], ["video:best"])
        selected = runner.apply_selection([self.entry()], runner.quality_catalog([self.entry()], "token"), "audio:best")
        self.assertEqual(selected[0]["requested_formats"][0]["vcodec"], "none")


class AuthorizedHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get("Cookie") != "session=local" or self.headers.get("Referer") != "https://www.bilibili.com/":
            self.send_error(403)
            return
        super().do_GET()
    def log_message(self, *_):
        pass


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "real FFmpeg integration runs in macOS CI")
class FFmpegIntegration(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="MediaPocket downloads ")
        self.base = Path(self.temp.name)
        self.runtime = runner.Runtime()
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(AuthorizedHandler, directory=str(self.base)))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=12",
                        "-t", "2", "-c:v", "libx264", "-an", str(self.base / "video.mp4")], check=True)
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440",
                        "-t", "2", "-c:a", "aac", str(self.base / "audio.m4a")], check=True)
        self.bridge = self.base / "MediaPocketBridge"
        (self.bridge / "jobs").mkdir(parents=True)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.temp.cleanup()

    def request(self, audio=False):
        job_id = str(uuid.uuid4()).upper()
        slot = self.bridge / "jobs" / job_id
        slot.mkdir()
        runner.atomic_json(slot / "request.json", {"id": job_id, "token": str(uuid.uuid4()).upper(),
                          "platform": "bilibili", "url": "https://www.bilibili.com/video/BV123/",
                          "quality": "1080", "audioOnly": audio, "created": 1})
        return job_id, slot

    @contextlib.contextmanager
    def extraction(self, request, bridge):
        from yt_dlp.cookies import YoutubeDLCookieJar
        jar = YoutubeDLCookieJar()
        jar.set_cookie(Cookie(0, "session", "local", None, False, "127.0.0.1", False, False,
                              "/", True, False, None, True, None, None, {}))
        class YDL:
            cookiejar = jar
        formats = [{"url": self.url + "/video.mp4", "protocol": "http", "acodec": "none"},
                   {"url": self.url + "/audio.m4a", "protocol": "http", "acodec": "aac"}]
        yield YDL(), [{"title": "Fixture", "duration": 2, "requested_formats": formats,
                       "http_headers": {"Referer": "https://www.bilibili.com/"}}]

    def test_ffmpeg_http_download_merge_and_audio_only(self):
        for audio in (False, True):
            job_id, slot = self.request(audio)
            runner.run_job(self.bridge, job_id, self.runtime, self.extraction)
            status = json.loads((slot / "status.json").read_text())
            self.assertEqual(status["phase"], "complete", status)
            output = slot / "output" / status["outputs"][0]
            probe = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(output)]))
            tracks = {item["codec_type"] for item in probe["streams"]}
            self.assertEqual(tracks, {"audio"} if audio else {"video", "audio"})
            self.assertGreater(float(probe["format"]["duration"]), 1.8)
            # A second callback/run must not duplicate or replace a completed file.
            size = output.stat().st_size
            runner.run_job(self.bridge, job_id, self.runtime, self.extraction)
            self.assertEqual(size, output.stat().st_size)

    def test_probe_app_selection_then_real_ffmpeg_download(self):
        shutil.copyfile(self.base / "video.mp4", self.base / "video-current.mp4")
        shutil.copyfile(self.base / "audio.m4a", self.base / "audio-current.m4a")
        @contextlib.contextmanager
        def catalog_extraction(request, bridge):
            with self.extraction(request, bridge) as (ydl, entries):
                for entry in entries:
                    entry["id"] = "fixture"
                    entry["formats"] = [dict(entry["requested_formats"][0], format_id="v90", height=90, vcodec="h264"),
                                        dict(entry["requested_formats"][1], format_id="a", vcodec="none")]
                    if request.get("selection"):
                        for fmt in entry["formats"]:
                            fmt["url"] = fmt["url"].replace("video.mp4", "video-current.mp4").replace("audio.m4a", "audio-current.m4a")
                yield ydl, entries
        for choice, audio in (("video:90", False), ("audio:best", True)):
            job_id, slot = self.request()
            request = json.loads((slot / "request.json").read_text())
            request["requiresSelection"] = True
            runner.atomic_json(slot / "request.json", request)
            with patch.object(self.runtime, "run", wraps=self.runtime.run) as transfer:
                runner.run_job(self.bridge, job_id, self.runtime, catalog_extraction, probe=True)
                transfer.assert_not_called()
            self.assertEqual(json.loads((slot / "status.json").read_text())["phase"], "awaitingSelection")
            self.assertFalse((slot / "output").exists())
            catalog = json.loads((slot / "catalog.json").read_text())
            self.assertIn(choice, [option["id"] for option in catalog["options"]])
            for stale in ("video.mp4", "audio.m4a"):
                (self.base / stale).unlink(missing_ok=True)
            request.update(selection=choice, audioOnly=audio)
            runner.atomic_json(slot / "request.json", request)
            runner.run_job(self.bridge, job_id, self.runtime, catalog_extraction)
            status = json.loads((slot / "status.json").read_text())
            self.assertEqual(status["phase"], "complete", status)
            self.assertTrue((slot / "output" / ("001.mka" if audio else "001.mkv")).is_file())

    def test_cancel_and_corrupt_output_do_not_complete(self):
        job_id, slot = self.request()
        (slot / "cancel").touch()
        runner.run_job(self.bridge, job_id, self.runtime, self.extraction)
        self.assertEqual(json.loads((slot / "status.json").read_text())["phase"], "cancelled")
        corrupt = slot / "corrupt.mkv"
        corrupt.write_bytes(b"not a video")
        with self.assertRaises(ValueError):
            runner.verify_output(self.runtime, corrupt, False, slot)

    def test_hls_download_uses_ffmpeg(self):
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(self.base / "video.mp4"),
                        "-i", str(self.base / "audio.m4a"), "-c", "copy", "-f", "hls", "-hls_time", "1",
                        "-hls_playlist_type", "vod", str(self.base / "index.m3u8")], check=True)
        @contextlib.contextmanager
        def hls(request, bridge):
            with self.extraction(request, bridge) as (ydl, _):
                yield ydl, [{"title": "HLS", "duration": 2, "url": self.url + "/index.m3u8",
                             "protocol": "m3u8_native", "acodec": "aac",
                             "http_headers": {"Referer": "https://www.bilibili.com/"}}]
        job_id, slot = self.request()
        runner.run_job(self.bridge, job_id, self.runtime, hls)
        self.assertEqual(json.loads((slot / "status.json").read_text())["phase"], "complete")

    def test_http_failure_never_publishes_outputs(self):
        @contextlib.contextmanager
        def rejected(request, bridge):
            with self.extraction(request, bridge) as (ydl, entries):
                entries[0]["http_headers"] = {"Referer": "https://wrong.test/"}
                yield ydl, entries
        job_id, slot = self.request()
        runner.run_job(self.bridge, job_id, self.runtime, rejected)
        status = json.loads((slot / "status.json").read_text())
        self.assertEqual(status["phase"], "failed")
        self.assertNotIn("outputs", status)


if __name__ == "__main__":
    if "--require-ffmpeg" in sys.argv:
        sys.argv.remove("--require-ffmpeg")
        if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
            raise SystemExit("FFmpeg and ffprobe are required for CI integration tests")
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    artifacts = ROOT / "build/artifacts"
    artifacts.mkdir(parents=True, exist_ok=True)
    runner.atomic_json(artifacts / "download-tests.json", {
        "passed": result.wasSuccessful(), "tests": result.testsRun, "skipped": len(result.skipped),
        "realFFmpeg": bool(shutil.which("ffmpeg") and shutil.which("ffprobe")),
        "physicalIphone": False, "livePlatformDownloads": False,
        "checks": ["four platform URL routing", "strict Threads post matching", "HTTP auth headers",
                   "FFmpeg separate-track merge", "HLS", "audio-only", "failure/cancel", "idempotent completion",
                   "probe without transfer", "actual quality catalog", "App selection then FFmpeg", "stale selection rejection"]
    })
    raise SystemExit(not result.wasSuccessful())
