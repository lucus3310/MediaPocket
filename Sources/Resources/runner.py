#!/usr/bin/env python3
"""Shared yt-dlp orchestration. iOS supplies an in-process FFmpeg runtime.
Desktop subprocess execution exists exclusively for command-line fixtures.
"""
from __future__ import annotations

import argparse
import contextlib
import importlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
import time
from urllib.parse import parse_qs, quote, urlparse
import uuid
import download_engine as engine

VERSION = "0.10.2"
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
    if host in ("tiktok.com", "www.tiktok.com") and re.fullmatch(r"/(?:@[^/]+/video/\d+|t/[A-Za-z0-9_-]+)/?", path): return "tiktok"
    if host in ("vm.tiktok.com", "vt.tiktok.com") and re.fullmatch(r"/[A-Za-z0-9_-]+/?", path): return "tiktok"
    if host in ("x.com", "www.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com") and re.fullmatch(r"/[^/]+/status/\d+/?", path): return "x"
    if host in ("vimeo.com", "www.vimeo.com", "player.vimeo.com") and re.fullmatch(r"/(?:video/)?\d+(?:/[A-Za-z0-9]+)?/?", path): return "vimeo"
    if (host in ("dailymotion.com", "www.dailymotion.com") and re.fullmatch(r"/video/[A-Za-z0-9]+/?", path)) or (host == "dai.ly" and re.fullmatch(r"/[A-Za-z0-9]+/?", path)): return "dailymotion"
    raise ValueError("請提供支援平台的單一影片或貼文連結。")


class Runtime:
    """Desktop fixture runner only. iOS always supplies NativeRuntime."""
    def __init__(self):
        if sys.platform == "ios":
            raise RuntimeError("iOS requires the embedded FFmpeg bridge")

    def run(self, arguments, stdout, stderr):
        with open(stdout, "wb") as out, open(stderr, "wb") as err:
            return subprocess.run(arguments, stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                                  timeout=3600, check=False).returncode

    def callback(self, job_id=None, token=None):
        pass


def setup(bridge, runtime):
    # Desktop diagnostics only; the app's health check is embedded_runner.health.
    status = dict(phase="ready", message="Desktop fixture runtime ready", token="setup", updated=time.time())
    for command in ("ffmpeg", "ffprobe"):
        if runtime.run([command, "-version"], bridge / (command + "-version.txt"), bridge / "setup-error.txt"):
            status.update(phase="failed", message=command + " unavailable")
    atomic_json(bridge / "setup.json", status)


def safe_error(error):
    # Source/CDN URLs can contain session tokens. Keep them out of UI status.
    text = re.sub(r"https?://\S+", "[來源網址]", str(error))
    text = re.sub(r"(?i)(cookie|authorization)\s*[:=][^\n]+", r"\1: [已隱藏]", text)
    return text[-1200:] or "下載失敗，請查看任務訊息。"


class QuietLog:
    def debug(self, message):
        pass
    def warning(self, message):
        print("[yt-dlp] " + safe_error(message), flush=True)
    def error(self, message):
        print("[yt-dlp] " + safe_error(message), flush=True)


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
    print("[MediaPocket] 載入 yt-dlp…", flush=True)
    import yt_dlp
    print("[MediaPocket] yt-dlp 已啟動，正在解析 " + request["platform"] + "…", flush=True)
    cookie = bridge / "cookies" / (request["platform"] + ".txt")
    options = {
        "format": "bv*+ba/b/ba" if request.get("requiresSelection") else format_selector(request["quality"], request["audioOnly"]),
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
        print(f"[MediaPocket] 解析完成：{len(entries)} 段，已取得來源與格式。", flush=True)
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


def available_formats(entry):
    # yt-dlp orders formats from lower to higher preference. Keep only transports
    # this FFmpeg bridge implements; never advertise DRM, storyboards or DASH fragments.
    return [fmt for fmt in (entry.get("formats") or [entry])
            if not entry.get("has_drm") and not fmt.get("has_drm")
            and fmt.get("protocol", urlparse(fmt.get("url", "")).scheme) in MEDIA_PROTOCOLS
            and urlparse(fmt.get("url", "")).scheme in ("http", "https")]


def video_format(fmt):
    return fmt.get("vcodec") != "none" and (
        fmt.get("vcodec") is not None or bool(fmt.get("height")) or bool(fmt.get("width")))


def audio_format(fmt):
    return fmt.get("acodec") not in (None, "none")


def resolution(fmt):
    value = fmt.get("height")
    return int(value) if isinstance(value, (int, float)) and math.isfinite(value) and 0 < value <= 16384 else 0


def quality_catalog(entries, token):
    return engine.catalog(entries, token)


def direct_entries(entries):
    result = []
    for entry in entries:
        supported = available_formats(entry)
        if not supported:
            raise ValueError("此來源沒有可由 FFmpeg 直接下載的完整媒體／HLS 網址，未改用 yt-dlp 下載。")
        result.append(dict(entry, formats=supported))
    return result


def legacy_quality_catalog(entries, token):
    if not entries or len(entries) > 20 or any(entry.get("is_live") for entry in entries):
        raise ValueError("目前僅支援已結束的影片貼文，每則最多 20 段。")
    formats = [available_formats(entry) for entry in entries]
    options = []
    if all(any(video_format(fmt) for fmt in group) for group in formats):
        options.append({"id": "video:best", "label": "各片最高可用畫質" if len(entries) > 1 else "最高可用畫質", "audioOnly": False})
        heights = set.intersection(*[{resolution(fmt) for fmt in group if video_format(fmt) and resolution(fmt)} for group in formats])
        for height in sorted(heights, reverse=True)[:40]:
            options.append({"id": f"video:{height}", "label": f"{height}p", "audioOnly": False, "height": height})
    if all(any(audio_format(fmt) for fmt in group) for group in formats):
        options.append({"id": "audio:best", "label": "只下載音訊・原編碼", "audioOnly": True})
    if not options:
        raise ValueError("沒有可由 FFmpeg 下載的共同影音格式。來源可能受限或使用不支援的傳輸格式。")
    return {"schema": 1, "token": token, "title": str(entries[0].get("title") or "影片")[:200],
            "identities": [str(entry.get("id", index)) for index, entry in enumerate(entries)],
            "options": options, "updated": time.time()}


def apply_selection(entries, catalog, selection):
    if catalog.get("schema") == 2:
        return engine.apply(entries, catalog, selection)
    if catalog.get("schema") != 1 or catalog.get("identities") != [str(entry.get("id", index)) for index, entry in enumerate(entries)]:
        raise ValueError("貼文內容已變更，請在 App 重新取得可用畫質。")
    option = next((item for item in catalog["options"] if item["id"] == selection), None)
    if not option:
        raise ValueError("畫質選擇失效，請在 App 重新解析。")
    selected_entries = []
    for entry in entries:
        formats = available_formats(entry)
        audio = [fmt for fmt in formats if audio_format(fmt)]
        audio_only = [fmt for fmt in audio if not video_format(fmt)]
        best_audio = (audio_only or audio)[-1] if audio else None
        if option["audioOnly"]:
            if best_audio is None:
                raise ValueError("選定音訊已不可用，請重新取得畫質。")
            chosen = [best_audio]
        else:
            videos = [fmt for fmt in formats if video_format(fmt) and (option.get("height") is None or resolution(fmt) == option["height"])]
            if not videos:
                raise ValueError("選定畫質已不可用，未降級下載；請在 App 重新解析。")
            video = max(enumerate(videos), key=lambda pair: (resolution(pair[1]), pair[0]))[1]
            chosen = [video]
            if not audio_format(video) and best_audio is not None and best_audio is not video:
                chosen.append(best_audio)
        selected_entries.append(dict(entry, requested_formats=chosen))
    return selected_entries


def ffmpeg_command(inputs, output, progress, audio_only, plan=None):
    args = ["ffmpeg", "-hide_banner", "-nostdin", "-n", "-loglevel", "warning"]
    allowed = {"user-agent", "referer", "origin", "accept", "accept-language", "cookie", "authorization", "range"}
    for _, url, headers in inputs:
        lines = []
        for name, value in headers.items():
            if name.lower() not in allowed:
                continue
            if "\r" in str(value) or "\n" in str(value):
                raise ValueError("來源 HTTP 標頭格式錯誤。")
            lines.append(f"{name}: {value}\r\n")
        args += ["-protocol_whitelist", "file,http,https,tcp,tls,crypto", "-rw_timeout", "30000000",
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
    codecs, muxer = (plan[1], plan[2]) if plan else (["-c", "copy"], "matroska")
    return args + codecs + ["-progress", str(progress), "-f", muxer, str(output)]


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


def run_job(bridge, job_id, runtime, extraction=extractor, probe=False):
    job_id = str(uuid.UUID(job_id)).upper()
    slot = bridge / "jobs" / job_id
    if slot.is_symlink() or slot.resolve().parent != (bridge / "jobs").resolve():
        raise ValueError("任務路徑不正確。")
    # flock is released by iOS even if the app is killed; a stale lock file
    # therefore does not block recovery. iOS has fcntl; Windows tests don't.
    with (bridge / "worker.lock").open("a+") as lock:
        try:
            import fcntl
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except ImportError:
            pass
        except BlockingIOError:
            print("另一個下載正在執行，請完成後再啟動此任務。")
            return
        _execute_job(bridge, slot, job_id, runtime, extraction, probe)


def _execute_job(bridge, slot, job_id, runtime, extraction, probe=False):
    request = json.loads((slot / "request.json").read_text(encoding="utf-8"))
    if str(uuid.UUID(request["id"])).upper() != job_id or platform_for(request["url"]) != request["platform"]:
        raise ValueError("任務資料與平台不一致。")
    if request["quality"] not in ("best", "1080", "720") or not isinstance(request["audioOnly"], bool):
        raise ValueError("畫質設定不正確。")
    if request.get("connections", 4) not in (1, 2, 4, 8) or request.get("transferMode") not in (None, "fast"):
        raise ValueError("下載模式設定不正確。")
    token = str(uuid.UUID(request["token"])).upper()
    if request.get("method") == "smgShortcut":
        raise ValueError("這是舊版外部交接紀錄，請在 App 重新解析連結。")
    if (slot / "imported.json").exists():
        runtime.callback(job_id, token)
        return
    existing = slot / "status.json"
    if existing.exists():
        previous = json.loads(existing.read_text(encoding="utf-8"))
        if previous.get("phase") in ("complete", "failed", "cancelled") and previous.get("token") == token and (
                previous.get("phase") == "complete" or request.get("attempt", 0) <= previous.get("attempt", 0)):
            print("這個任務已結束，請回 App 建立重試任務。")
            runtime.callback(job_id, token)
            return
    status = {"phase": "extracting", "message": "正在解析影片連結…", "token": token, "updated": time.time(), "attempt": request.get("attempt", 0)}
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
        if probe:
            update(phase="scanning", message="yt-dlp 正在取得可用畫質，完成後可選擇畫質。")
            with extraction(dict(request, quality="best", audioOnly=False), bridge) as (_, entries):
                if request.get("transferMode") != "fast":
                    entries = direct_entries(entries)
                catalog = quality_catalog(entries, token)
                check_cancel()
                atomic_json(slot / "catalog.json", catalog)
            update(phase="awaitingSelection", message="可用畫質已取得，請在 App 選擇後開始下載。", title=catalog["title"])
            print(status["message"], flush=True)
            try:
                runtime.callback(job_id, token)
            except Exception:
                print("[MediaPocket] 無法自動返回；請手動回 App 選畫質。", flush=True)
            return
        if request.get("requiresSelection") and not request.get("selection"):
            raise ValueError("請先回 App 選擇畫質；尚未開始下載。")
        output_dir = slot / "output"
        output_dir.mkdir(exist_ok=True)
        if output_dir.is_symlink():
            raise ValueError("輸出目錄不正確。")
        # Recover an interrupted attempt inside this uncommitted job only.
        for old in output_dir.iterdir():
            if old.is_symlink() or not old.is_file() or not re.fullmatch(r"\d{3}\.(mkv|mka|mp4|webm|m4a|mp3|flac|wav)(\.part)?", old.name):
                raise ValueError("任務輸出目錄含有非預期檔案，請建立新任務。")
            old.unlink()
        outputs = []
        # All legacy jobs use FFmpeg for transfer; yt-dlp remains metadata-only.
        staged = False
        advanced = staged or request.get("outputProfile") not in (None, "original")
        encoders = engine.encoder_set(runtime, slot) if advanced else set()
        cache = slot / "tracks"
        if staged:
            cache.mkdir(exist_ok=True)
            if cache.is_symlink(): raise ValueError("暫存資料夾不正確。")
        with extraction(request, bridge) as (ydl, entries):
            if request.get("requiresSelection"):
                if not staged:
                    entries = direct_entries(entries)
                catalog = json.loads((slot / "catalog.json").read_text(encoding="utf-8"))
                if catalog.get("token") != token:
                    raise ValueError("畫質清單不屬於此任務，請重新解析。")
                entries = apply_selection(entries, catalog, request["selection"])
            if advanced and request["audioOnly"]:
                normalized = []
                for entry in entries:
                    track = engine.best_audio(entry.get("requested_formats") or [entry])
                    if track is None: raise ValueError("來源沒有可下載的音訊。")
                    normalized.append(dict(entry, requested_formats=[track]))
                entries = normalized
            plans = [engine.output_plan(request, entry, encoders) for entry in entries] if advanced else []
            for index, entry in enumerate(entries, 1):
                check_cancel()
                if entry.get("is_live"):
                    raise ValueError("直播進行中暫不支援，請在直播結束後下載回放。")
                plan = plans[index - 1] if advanced else None
                inputs = inputs_for(entry, ydl, request["audioOnly"]) if not staged else []
                name = f"{index:03d}." + (plan[0] if plan else "mka" if request["audioOnly"] else "mkv")
                final = output_dir / name
                temporary = output_dir / (name + ".part")
                progress = slot / "ffmpeg-progress.txt"
                progress.write_text("")
                duration = entry.get("duration")
                update(phase="downloading", message=f"準備下載 {index}/{len(entries)}…",
                       title=str(entry.get("title") or request["platform"])[:200], progress=None)
                print(f"[MediaPocket] FFmpeg 下載與合併 {index}/{len(entries)}…", flush=True)
                paths = None
                if staged:
                    paths = engine.download_tracks(ydl, entry, cache, request.get("connections", 4), update, check_cancel)
                    update(phase="converting" if plan[3] else "merging", message="FFmpeg 轉碼中…" if plan[3] else "FFmpeg 原編碼合併中…", progress=0.8)
                stop = threading.Event()

                def monitor():
                    while not stop.wait(1):
                        message = "正在取消內建 FFmpeg…" if (slot / "cancel").exists() else ("FFmpeg 轉碼中…" if plan and plan[3] else f"FFmpeg 下載與合併 {index}/{len(entries)}…")
                        value = progress_value(progress, duration)
                        update(message=message, progress=(0.8 + value * 0.19 if value is not None else 0.8) if staged else value)

                watcher = threading.Thread(target=monitor, daemon=True)
                watcher.start()
                try:
                    command = engine.local_command(paths, temporary, progress, request["audioOnly"], plan) if staged else ffmpeg_command(inputs, temporary, progress, request["audioOnly"], plan)
                    result = runtime.run(command,
                                         slot / "ffmpeg-stdout.txt", slot / "ffmpeg-error.txt")
                    fallback = engine.software_fallback(request, entry, encoders, plan) if result and advanced else None
                    if fallback is not None:
                        check_cancel()
                        temporary.unlink(missing_ok=True)
                        error_log = slot / "ffmpeg-error.txt"
                        if error_log.exists(): error_log.replace(slot / "ffmpeg-videotoolbox-error.txt")
                        update(phase="converting", message="VideoToolbox 無法完成，改用可用的軟體編碼器重試。" + ("沿用已下載軌道。" if staged else "FFmpeg 將重新讀取來源下載。"), progress=0.8 if staged else None)
                        command = engine.local_command(paths, temporary, progress, request["audioOnly"], fallback) if staged else ffmpeg_command(inputs, temporary, progress, request["audioOnly"], fallback)
                        result = runtime.run(command,
                                             slot / "ffmpeg-stdout.txt", slot / "ffmpeg-error.txt")
                finally:
                    stop.set()
                    watcher.join(timeout=3)
                check_cancel()
                if result:
                    if staged:
                        raise ValueError("FFmpeg 合併／轉碼失敗，已保留軌道暫存。請改用原編碼重試，或檢查裝置編碼器及可用空間；詳細錯誤在任務資料夾的 ffmpeg-error.txt。")
                    raise ValueError("FFmpeg 下載失敗。來源可能已過期、限流或拒絕存取；請重新建立任務。詳細訊息在任務資料夾的 ffmpeg-error.txt，可能含來源網址，請勿公開分享。")
                expected_audio = any(engine.audio(fmt) for fmt in (entry.get("requested_formats") or [entry])) if advanced else any(item[0].get("acodec") not in (None, "none") for item in inputs)
                verify_output(runtime, temporary, request["audioOnly"], slot, expected_audio)
                os.replace(temporary, final)
                outputs.append(name)
        check_cancel()
        if not outputs:
            raise ValueError("沒有取得影片。")
        if staged:
            import shutil
            try: shutil.rmtree(cache)
            except OSError: print("[MediaPocket] 成品已驗證；部分暫存未能清理，可稍後從檔案 App 清理任務的 tracks 資料夾。", flush=True)
        update(phase="complete", message="下載與軌道驗證完成，正在加入檔案庫。", outputs=outputs, progress=1)
    except (KeyboardInterrupt, InterruptedError):
        update(phase="cancelled", message="已取消；未完成的檔案不會匯入。", progress=None)
    except Exception as error:
        update(phase="cancelled" if (slot / "cancel").exists() else "failed", message=safe_error(error), progress=None)
    print(status["message"])
    runtime.callback(job_id, token)


def record_startup_failure(bridge, arguments, error):
    """Failures before run_job has created status must also reach the App."""
    message = "無法啟動下載工具：" + safe_error(error)
    print("[MediaPocket] " + message, flush=True)
    try:
        if arguments.setup:
            destination, token = bridge / "setup.json", "setup"
        else:
            job_id = str(uuid.UUID(arguments.job or getattr(arguments, "probe", None))).upper()
            root = bridge / "jobs"
            slot = root / job_id
            if slot.is_symlink() or slot.resolve().parent != root.resolve():
                return
            request_path = slot / "request.json"
            if request_path.is_symlink():
                return
            request = json.loads(request_path.read_text(encoding="utf-8"))
            if str(uuid.UUID(request["id"])).upper() != job_id:
                return
            token = str(uuid.UUID(request["token"])).upper()
            destination = slot / "status.json"
            if destination.exists():
                previous = json.loads(destination.read_text(encoding="utf-8"))
                if previous.get("token") == token and previous.get("phase") in ("complete", "failed", "cancelled"):
                    return
        atomic_json(destination, {"phase": "failed", "message": message, "token": token, "updated": time.time()})
    except Exception:
        print("[MediaPocket] 無法寫回狀態；請檢查 App 內任務資料夾。", flush=True)


def main():
    parser = argparse.ArgumentParser(description="MediaPocket desktop FFmpeg fixture runner")
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument("--setup", action="store_true")
    actions.add_argument("--job")
    actions.add_argument("--probe")
    arguments = parser.parse_args()
    bridge = Path(__file__).resolve().parent
    print(f"[MediaPocket] MediaPocket 下載程式已啟動 v{VERSION} · Python {sys.version.split()[0]}", flush=True)
    try:
        runtime = Runtime()
        if arguments.setup:
            setup(bridge, runtime)
        else:
            run_job(bridge, arguments.job or arguments.probe, runtime, probe=bool(arguments.probe))
    except Exception as error:
        record_startup_failure(bridge, arguments, error)


if __name__ == "__main__":
    main()
