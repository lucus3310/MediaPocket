#!/usr/bin/env python3
"""MediaPocket a-Shell companion. Extract with yt-dlp; transfer with FFmpeg.

No subprocess is created on iOS: commands use a-Shell's in-process ios_system.
The only IPC inputs are a local request JSON and a validated UUID argument.
"""
from __future__ import annotations

import argparse
import contextlib
import ctypes
import importlib
import json
import math
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import threading
import time
from urllib.parse import parse_qs, quote, urlparse
import uuid

VERSION = "0.4.0"
PACKAGES = ["yt-dlp==2026.10.26", "yt-dlp-ejs==0.8.0",
            "yt-dlp-apple-webkit-jsi==0.1.1", "yt-dlp-threads==0.1.0"]
MEDIA_PROTOCOLS = {"https", "http", "m3u8", "m3u8_native"}


def atomic_json(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, allow_nan=False), encoding="utf-8")
    os.replace(temporary, path)


def platform_for(url):
    if not isinstance(url, str) or len(url.encode()) >= 8192:
        raise ValueError("連結過長或格式錯誤。")
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.username or parsed.password or parsed.port not in (None, 443):
        raise ValueError("只接受 HTTPS 平台影片連結。")
    host, path = parsed.hostname, parsed.path
    if host == "youtu.be" and re.fullmatch(r"/[\w-]+/?", path):
        return "youtube"
    if host in ("youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"):
        if (path == "/watch" and parse_qs(parsed.query).get("v")) or re.fullmatch(r"/(shorts|live|embed)/[\w-]+/?", path):
            return "youtube"
    if host in ("instagram.com", "www.instagram.com") and re.fullmatch(r"/(p|reel|reels|tv)/[\w-]+/?", path):
        return "instagram"
    if host in ("threads.com", "www.threads.com", "threads.net", "www.threads.net") and re.fullmatch(r"/(?:@[^/]+/post|t|share)/[\w-]+/?", path):
        return "threads"
    if host == "b23.tv" and re.fullmatch(r"/[\w-]+/?", path):
        return "bilibili"
    if host in ("bilibili.com", "www.bilibili.com", "m.bilibili.com") and re.fullmatch(r"/video/(BV[A-Za-z0-9]+|av[0-9]+)/?", path):
        return "bilibili"
    raise ValueError("請提供這四個平台的單一影片或貼文連結。")


class Runtime:
    def __init__(self):
        self.native = None
        if os.name != "posix":
            return
        try:
            self.native = ctypes.CDLL(None).ios_system
            self.native.argtypes = [ctypes.c_char_p]
            self.native.restype = ctypes.c_int
        except (AttributeError, OSError):
            self.native = None

    def run(self, arguments, stdout, stderr):
        # Never interpolate a URL into an unquoted shell command. Only the native
        # a-Shell path needs a command string; desktop tests use argv directly.
        if self.native:
            command = shlex.join([str(arg) for arg in arguments])
            command += " > " + shlex.quote(str(stdout)) + " 2> " + shlex.quote(str(stderr))
            return self.native(command.encode("utf-8"))
        with open(stdout, "wb") as out, open(stderr, "wb") as err:
            return subprocess.run(arguments, stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                                  timeout=3600, check=False).returncode

    def callback(self, job_id=None, token=None):
        if not self.native:
            return
        callback = "mediapocket://complete"
        if job_id:
            callback += "?id=" + quote(job_id) + "&token=" + quote(token or "")
        self.native(("openurl " + shlex.quote(callback)).encode("utf-8"))


def setup(bridge, runtime):
    status = {"phase": "installing", "message": "正在安裝免費解析元件…", "token": "setup", "updated": time.time()}
    atomic_json(bridge / "setup.json", status)
    try:
        if sys.version_info < (3, 11):
            raise ValueError("請先在 App Store 更新完整版 a-Shell；需要 Python 3.11 以上。")
        from pip._internal.cli.main import main as pip_main
        result = pip_main(["install", "--upgrade", "--only-binary=:all:", "--disable-pip-version-check",
                           "--no-input", *PACKAGES])
        if result:
            raise ValueError("Python 套件安裝未完成，請檢查 a-Shell 終端訊息與網路後重試。")
        importlib.invalidate_caches()
        for module in ("yt_dlp", "yt_dlp_ejs", "yt_dlp_plugins.extractor.threads", "yt_dlp_plugins.extractor.webkit_jsi"):
            importlib.import_module(module)
        for command in ("ffmpeg", "ffprobe"):
            if runtime.run([command, "-version"], bridge / (command + "-version.txt"), bridge / "setup-error.txt"):
                raise ValueError(f"找不到可運作的 {command}，請更新完整版 a-Shell。")
        status.update(phase="ready", message=f"下載工具 {VERSION} 已就緒：FFmpeg、ffprobe 與四平台解析元件。")
    except Exception as error:
        status.update(phase="failed", message=safe_error(error))
    status["updated"] = time.time()
    atomic_json(bridge / "setup.json", status)
    print(status["message"])
    runtime.callback()


def safe_error(error):
    # Source/CDN URLs can contain session tokens. Keep them out of UI status.
    text = re.sub(r"https?://\S+", "[來源網址]", str(error))
    text = re.sub(r"(?i)(cookie|authorization)\s*[:=][^\n]+", r"\1: [已隱藏]", text)
    return text[-1200:] or "下載失敗，請查看 a-Shell 訊息。"


class QuietLog:
    def debug(self, message):
        pass
    def warning(self, message):
        pass
    def error(self, message):
        pass


def strict_threads_extractor():
    # The upstream plugin's /share fallback may pick a recommended post when
    # og:url is absent. Refuse that ambiguity before calling its extractor.
    from yt_dlp_plugins.extractor.threads import ThreadsIE
    from yt_dlp.utils import ExtractorError

    class MediaPocketThreadsIE(ThreadsIE):
        def _real_extract(self, url):
            if "/share/" in urlparse(url).path:
                page = self._download_webpage(url, "share", headers={
                    "User-Agent": "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"})
                canonical = self._og_search_property("url", page, default=None)
                if not canonical or platform_for(canonical) != "threads" or not re.fullmatch(
                        r"/@[^/]+/post/[\w-]+/?", urlparse(canonical).path):
                    raise ExtractorError("無法確認 Threads 分享連結的貼文代碼，請改貼 @帳號/post/代碼 的原始網址。", expected=True)
                url = canonical
            return super()._real_extract(url)
    return MediaPocketThreadsIE()


def format_selector(quality, audio_only):
    cap = "" if quality == "best" else f"[height<={int(quality)}]"
    choices = []
    for protocol in ("https", "http", "m3u8_native", "m3u8"):
        suffix = f"[protocol={protocol}]"
        if audio_only:
            choices.extend(["ba" + suffix, "b" + suffix])
        else:
            choices.extend(["bv" + cap + suffix + "+ba" + suffix,
                            "b" + cap + suffix, "bv" + cap + suffix])
    return "/".join(choices)


@contextlib.contextmanager
def extractor(request, bridge):
    import yt_dlp
    cookie = bridge / "cookies" / (request["platform"] + ".txt")
    options = {
        "format": format_selector(request["quality"], request["audioOnly"]),
        "noplaylist": True, "playlistend": 20, "ignoreerrors": False,
        "quiet": True, "no_warnings": True, "logger": QuietLog(),
        "socket_timeout": 30, "retries": 3, "extractor_retries": 2,
        "cachedir": str(bridge / "cache"), "skip_download": True,
    }
    if cookie.is_file() and not cookie.is_symlink():
        options["cookiefile"] = str(cookie)
    with yt_dlp.YoutubeDL(options) as ydl:
        key = None
        if request["platform"] == "threads":
            adapter = strict_threads_extractor()
            ydl.add_info_extractor(adapter)
            key = adapter.ie_key()
        info = ydl.extract_info(request["url"], download=False, ie_key=key)
        entries = list(info.get("entries") or [info]) if info else []
        if not entries or len(entries) > 20 or any(item is None for item in entries):
            raise ValueError("這則貼文沒有可下載的影片，或包含超過 20 段影片。")
        yield ydl, entries


def inputs_for(entry, ydl, audio_only):
    formats = entry.get("requested_formats") or [entry]
    if entry.get("has_drm") or any(fmt.get("has_drm") for fmt in formats):
        raise ValueError("此內容有 DRM 保護，無法下載。")
    selected = []
    for fmt in formats:
        url = fmt.get("url", "")
        if fmt.get("protocol", urlparse(url).scheme) not in MEDIA_PROTOCOLS or urlparse(url).scheme not in ("http", "https"):
            raise ValueError("目前來源不是可由 FFmpeg 直接下載的 HTTPS／HLS 格式。")
        if "\n" in url or "\r" in url:
            raise ValueError("來源網址格式錯誤。")
        headers = dict(entry.get("http_headers") or {})
        headers.update(fmt.get("http_headers") or {})
        cookie = ydl.cookiejar.get_cookie_header(url)
        if cookie:
            headers["Cookie"] = cookie
        selected.append((fmt, url, headers))
    if audio_only:
        selected = [item for item in selected if item[0].get("acodec") != "none"][-1:]
    if not selected:
        raise ValueError("這段影片沒有可下載的音訊。")
    return selected


def ffmpeg_command(inputs, output, progress, audio_only):
    args = ["ffmpeg", "-hide_banner", "-nostdin", "-n", "-loglevel", "warning"]
    allowed = {"user-agent", "referer", "origin", "accept", "accept-language", "cookie"}
    for _, url, headers in inputs:
        lines = []
        for name, value in headers.items():
            if name.lower() not in allowed:
                continue
            if "\r" in str(value) or "\n" in str(value):
                raise ValueError("來源 HTTP 標頭格式錯誤。")
            lines.append(f"{name}: {value}\r\n")
        args += ["-protocol_whitelist", "http,https,tcp,tls,crypto", "-rw_timeout", "30000000",
                 "-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "5"]
        if lines:
            args += ["-headers", "".join(lines)]
        args += ["-i", url]
    if audio_only:
        args += ["-map", "0:a:0", "-vn"]
    else:
        args += ["-map", "0:v:0"]
        # Separate DASH audio must be mapped from its own input, rather than
        # relying on FFmpeg's automatic track selection.
        audio = next((index for index in reversed(range(len(inputs))) if inputs[index][0].get("acodec") != "none"), None)
        if audio is not None:
            args += ["-map", f"{audio}:a:0?"]
    return args + ["-c", "copy", "-progress", str(progress), "-f", "matroska", str(output)]


def verify_output(runtime, output, audio_only, slot, expected_audio=False):
    probe = slot / "probe.json"
    result = runtime.run(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(output)],
                         probe, slot / "probe-error.txt")
    if result or not output.is_file() or output.stat().st_size <= 0:
        raise ValueError("FFmpeg 輸出驗證失敗；未將這個檔案匯入檔案庫。")
    metadata = json.loads(probe.read_text(encoding="utf-8"))
    kind = "audio" if audio_only else "video"
    if not any(stream.get("codec_type") == kind for stream in metadata.get("streams", [])):
        raise ValueError("輸出缺少預期的影音軌，未匯入檔案庫。")
    if expected_audio and not any(stream.get("codec_type") == "audio" for stream in metadata.get("streams", [])):
        raise ValueError("輸出缺少來源音訊軌，未匯入檔案庫。")


def progress_value(path, duration):
    if not duration or not math.isfinite(duration) or duration <= 0:
        return None
    try:
        values = dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line)
        return min(0.99, max(0, int(values.get("out_time_us", "0")) / 1_000_000 / duration))
    except (OSError, ValueError):
        return None


def run_job(bridge, job_id, runtime, extraction=extractor):
    job_id = str(uuid.UUID(job_id)).upper()
    slot = bridge / "jobs" / job_id
    if slot.is_symlink() or slot.resolve().parent != (bridge / "jobs").resolve():
        raise ValueError("任務路徑不正確。")
    # flock is released by iOS even if the app is killed; a stale lock file
    # therefore does not block recovery. a-Shell has fcntl; Windows tests don't.
    with (bridge / "worker.lock").open("a+") as lock:
        try:
            import fcntl
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except ImportError:
            pass
        except BlockingIOError:
            print("另一個下載正在執行，請完成後再啟動此任務。")
            return
        _execute_job(bridge, slot, job_id, runtime, extraction)


def _execute_job(bridge, slot, job_id, runtime, extraction):
    request = json.loads((slot / "request.json").read_text(encoding="utf-8"))
    if str(uuid.UUID(request["id"])).upper() != job_id or platform_for(request["url"]) != request["platform"]:
        raise ValueError("任務資料與平台不一致。")
    if request["quality"] not in ("best", "1080", "720") or not isinstance(request["audioOnly"], bool):
        raise ValueError("畫質設定不正確。")
    token = str(uuid.UUID(request["token"])).upper()
    if (slot / "imported.json").exists():
        runtime.callback(job_id, token)
        return
    existing = slot / "status.json"
    if existing.exists():
        previous = json.loads(existing.read_text(encoding="utf-8"))
        if previous.get("phase") in ("complete", "failed", "cancelled") and previous.get("token") == token:
            print("這個任務已結束，請回 App 建立重試任務。")
            runtime.callback(job_id, token)
            return
    status = {"phase": "extracting", "message": "正在解析影片連結…", "token": token, "updated": time.time()}
    status_lock = threading.Lock()

    def update(**values):
        with status_lock:
            status.update(values, updated=time.time())
            atomic_json(slot / "status.json", status)

    def check_cancel():
        if (slot / "cancel").exists():
            raise InterruptedError("已取消；未完成的檔案不會匯入。")

    update()
    try:
        check_cancel()
        output_dir = slot / "output"
        output_dir.mkdir(exist_ok=True)
        if output_dir.is_symlink():
            raise ValueError("輸出目錄不正確。")
        # Recover an interrupted attempt inside this uncommitted job only.
        for old in output_dir.iterdir():
            if old.is_symlink() or not old.is_file() or not re.fullmatch(r"\d{3}\.(mkv|mka)(\.part)?", old.name):
                raise ValueError("任務輸出目錄含有非預期檔案，請建立新任務。")
            old.unlink()
        outputs = []
        with extraction(request, bridge) as (ydl, entries):
            for index, entry in enumerate(entries, 1):
                check_cancel()
                if entry.get("is_live"):
                    raise ValueError("直播進行中暫不支援，請在直播結束後下載回放。")
                inputs = inputs_for(entry, ydl, request["audioOnly"])
                name = f"{index:03d}." + ("mka" if request["audioOnly"] else "mkv")
                final = output_dir / name
                temporary = output_dir / (name + ".part")
                progress = slot / "ffmpeg-progress.txt"
                progress.write_text("")
                duration = entry.get("duration")
                update(phase="downloading", message=f"FFmpeg 下載與合併 {index}/{len(entries)}…",
                       title=str(entry.get("title") or request["platform"])[:200], progress=None)
                stop = threading.Event()

                def monitor():
                    while not stop.wait(1):
                        message = "等待 FFmpeg 安全結束；可在 a-Shell 按 Ctrl+C 停止。" if (slot / "cancel").exists() else f"FFmpeg 下載與合併 {index}/{len(entries)}…"
                        update(message=message, progress=progress_value(progress, duration))

                watcher = threading.Thread(target=monitor, daemon=True)
                watcher.start()
                try:
                    result = runtime.run(ffmpeg_command(inputs, temporary, progress, request["audioOnly"]),
                                         slot / "ffmpeg-stdout.txt", slot / "ffmpeg-error.txt")
                finally:
                    stop.set()
                    watcher.join(timeout=3)
                check_cancel()
                if result:
                    raise ValueError("FFmpeg 下載失敗。來源可能已過期、限流或拒絕存取；請重新建立任務。詳細訊息在任務資料夾的 ffmpeg-error.txt，可能含來源網址，請勿公開分享。")
                expected_audio = any(item[0].get("acodec") not in (None, "none") for item in inputs)
                verify_output(runtime, temporary, request["audioOnly"], slot, expected_audio)
                os.replace(temporary, final)
                outputs.append(name)
        check_cancel()
        if not outputs:
            raise ValueError("沒有取得影片。")
        update(phase="complete", message="下載與軌道驗證完成，返回 App 後匯入。", outputs=outputs, progress=1)
    except (KeyboardInterrupt, InterruptedError):
        update(phase="cancelled", message="已取消；未完成的檔案不會匯入。", progress=None)
    except Exception as error:
        update(phase="failed", message=safe_error(error), progress=None)
    print(status["message"])
    runtime.callback(job_id, token)


def main():
    parser = argparse.ArgumentParser(description="MediaPocket free a-Shell FFmpeg companion")
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument("--setup", action="store_true")
    actions.add_argument("--job")
    arguments = parser.parse_args()
    bridge = Path(__file__).resolve().parent
    runtime = Runtime()
    if arguments.setup:
        setup(bridge, runtime)
    else:
        try:
            run_job(bridge, arguments.job, runtime)
        except Exception as error:
            print("無法啟動任務：" + safe_error(error))
            print("請重新授權 MediaPocket 最外層資料夾，或在 App 建立新任務。")


if __name__ == "__main__":
    main()
