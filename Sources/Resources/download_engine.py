"""Format policy and local FFmpeg processing, independent of the iOS handoff UI."""
from __future__ import annotations
import hashlib
import json
import math
from pathlib import Path
import re

PROTOCOLS = {"http", "https", "m3u8", "m3u8_native", "http_dash_segments"}
VIDEO_PROFILES = {"original", "auto", "mp4", "h264", "hevc", "webm"}
AUDIO_PROFILES = {"original", "m4a", "mp3", "flac", "wav"}


def number(value, scale=1):
    return round(value * scale) if isinstance(value, (int, float)) and math.isfinite(value) and 0 <= value < 1e15 else 0


def codec(value):
    value = str(value or "unknown").lower().split(".")[0]
    return {"avc1": "h264", "avc3": "h264", "hvc1": "hevc", "hev1": "hevc", "h265": "hevc",
            "vp09": "vp9", "av01": "av1", "mp4a": "aac"}.get(value, value)


def video(fmt):
    return fmt.get("vcodec") != "none" and (fmt.get("vcodec") is not None or bool(fmt.get("height")) or bool(fmt.get("width")))


def audio(fmt):
    return fmt.get("acodec") not in (None, "none")


def formats(entry):
    from urllib.parse import urlparse
    return [fmt for fmt in (entry.get("formats") or [entry]) if not entry.get("has_drm") and not fmt.get("has_drm")
            and fmt.get("protocol", urlparse(fmt.get("url") or "").scheme) in PROTOCOLS
            and (fmt.get("protocol") != "http_dash_segments" or bool(fmt.get("fragments")))
            and urlparse(fmt.get("url") or "").scheme in ("http", "https")]


def descriptor(fmt, audio_only=False):
    if audio_only:
        return {"codec": codec(fmt.get("acodec")), "ext": str(fmt.get("ext") or "unknown"),
                "abr": number(fmt.get("abr")), "asr": number(fmt.get("asr")),
                "channels": number(fmt.get("audio_channels")), "language": str(fmt.get("language") or "")[:24]}
    return {"height": number(fmt.get("height")), "fpsMillis": number(fmt.get("fps"), 1000),
            "codec": codec(fmt.get("vcodec")), "ext": str(fmt.get("ext") or "unknown"),
            "range": str(fmt.get("dynamic_range") or "SDR")[:24]}


def key(criteria, audio_only):
    digest = hashlib.sha256(json.dumps(criteria, sort_keys=True).encode()).hexdigest()[:16]
    return ("a:" if audio_only else "v:") + digest


def identities(entries):
    return [str(entry.get("id", index)) for index, entry in enumerate(entries)]


def best_audio(group):
    candidates = [fmt for fmt in group if audio(fmt)]
    return (next((fmt for fmt in reversed(candidates) if not video(fmt)), None)
            or (candidates[-1] if candidates else None))


def choose(group, option):
    criteria = option.get("criteria")
    if criteria is not None and key(criteria, option["audioOnly"]) != option["id"]:
        raise ValueError("畫質清單校驗失敗，請重新解析。")
    candidates = [fmt for fmt in group if (audio(fmt) if option["audioOnly"] else video(fmt))
                  and (criteria is None or descriptor(fmt, option["audioOnly"]) == criteria)
                  and (option.get("height") is None or number(fmt.get("height")) == option["height"])]
    if not candidates:
        raise ValueError("選定的解析度、fps 或編碼已不可用，未自動降級；請重新解析。")
    if option["audioOnly"]:
        return [best_audio(candidates)]
    selected = max(enumerate(candidates), key=lambda pair: (number(pair[1].get("height")), number(pair[1].get("fps")), pair[0]))[1]
    result = [selected]
    track = best_audio(group)
    if not audio(selected) and track is not None and track is not selected:
        result.append(track)
    return result


def catalog(entries, token):
    if not entries or len(entries) > 20 or any(entry.get("is_live") for entry in entries):
        raise ValueError("目前支援已結束的影片貼文，每則最多 20 段。")
    groups = [formats(entry) for entry in entries]
    options = []
    if all(any(video(fmt) for fmt in group) for group in groups):
        options.append({"id": "video:best", "label": "各片最高原畫質" if len(entries) > 1 else "最高原畫質・不限 4K", "audioOnly": False})
        heights = set.intersection(*[{number(fmt.get("height")) for fmt in group if video(fmt) and 0 < number(fmt.get("height")) <= 16384} for group in groups])
        options.extend({"id": f"video:{height}", "label": f"{height}p・自動 fps／編碼", "audioOnly": False, "height": height} for height in sorted(heights, reverse=True)[:32])
    if all(any(audio(fmt) for fmt in group) for group in groups):
        options.append({"id": "audio:best", "label": "最佳音訊・原編碼", "audioOnly": True})
    for audio_only in (False, True):
        maps = []
        for group in groups:
            mapping = {}
            for fmt in group:
                if not (audio(fmt) if audio_only else video(fmt)) or (not audio_only and not number(fmt.get("height"))):
                    continue
                criteria = descriptor(fmt, audio_only)
                mapping[key(criteria, audio_only)] = criteria
            maps.append(mapping)
        shared = set.intersection(*(set(mapping) for mapping in maps))
        for identity in sorted(shared, key=lambda value: (maps[0][value].get("height", 0), maps[0][value].get("fpsMillis", 0), maps[0][value].get("abr", 0), value), reverse=True)[:72 if not audio_only else 24]:
            criteria = maps[0][identity]
            if audio_only:
                parts = [criteria["codec"].upper()]
                if criteria["abr"]: parts.append(f'{criteria["abr"]} kb/s')
                if criteria["asr"]: parts.append(f'{criteria["asr"] / 1000:g} kHz')
                if criteria["language"]: parts.append(criteria["language"])
            else:
                parts = [f'{criteria["height"]}p']
                if criteria["fpsMillis"]: parts.append(f'{criteria["fpsMillis"] / 1000:g} fps')
                parts += [criteria["codec"].upper(), criteria["ext"].upper()]
                if criteria["range"] != "SDR": parts.append(criteria["range"])
            option = {"id": identity, "label": " · ".join(parts), "audioOnly": audio_only, "criteria": criteria,
                      "videoCodec" if not audio_only else "audioCodec": criteria["codec"], "container": criteria["ext"]}
            if not audio_only:
                option.update(height=criteria["height"], fps=criteria["fpsMillis"] / 1000 or None, dynamicRange=criteria["range"])
            sizes = []
            for group in groups:
                selected = choose(group, option)
                size = [number(fmt.get("filesize") or fmt.get("filesize_approx")) for fmt in selected]
                if not all(size): break
                sizes.append(sum(size))
            if len(sizes) == len(groups): option["estimatedBytes"] = sum(sizes)
            options.append(option)
    if not options:
        raise ValueError("這個來源沒有可用的未加密影音格式。")
    return {"schema": 2, "token": token, "title": str(entries[0].get("title") or "影片")[:200],
            "identities": identities(entries), "options": options, "updated": __import__("time").time()}


def apply(entries, catalog, selection):
    if catalog.get("schema") != 2 or catalog.get("identities") != identities(entries):
        raise ValueError("來源影片清單已變更，請重新解析。")
    option = next((item for item in catalog["options"] if item["id"] == selection), None)
    if option is None: raise ValueError("選定格式已失效，請重新解析。")
    return [dict(entry, requested_formats=choose(formats(entry), option)) for entry in entries]


def output_plan(request, entry, encoders):
    profile = request.get("outputProfile") or "original"
    audio_only = request["audioOnly"]
    if profile not in (AUDIO_PROFILES if audio_only else VIDEO_PROFILES):
        raise ValueError("輸出格式不適用於這個影音選項。")
    selected = entry.get("requested_formats") or [entry]
    vf = next((fmt for fmt in selected if video(fmt)), {})
    af = next((fmt for fmt in reversed(selected) if audio(fmt)), {})
    vc, ac = codec(vf.get("vcodec")), codec(af.get("acodec"))
    mp4_video = vc in {"h264", "hevc", "av1", "mpeg4"}
    mp4_audio = ac in {"aac", "alac", "mp3"} or not af
    if profile == "auto": profile = "mp4" if mp4_video and mp4_audio else "original"
    if profile == "original": return ("mka" if audio_only else "mkv", ["-c", "copy"], "matroska", False)
    if profile == "webm":
        if vc not in {"vp8", "vp9", "av1"} or (af and ac not in {"opus", "vorbis"}):
            raise ValueError("選定編碼不適合無損 WebM；請選 VP9／AV1 + Opus，或改用自動格式／MKV。")
        return "webm", ["-c", "copy"], "webm", False
    if audio_only:
        name = {"m4a": "aac", "mp3": "libmp3lame", "flac": "flac", "wav": "pcm_s16le"}[profile]
        copy = profile == "m4a" and ac in {"aac", "alac"}
        if not copy and name not in encoders: raise ValueError(f"目前 FFmpeg 缺少 {name}，請更新 a-Shell 或選原編碼。")
        args = ["-c:a", "copy" if copy else name]
        if profile in {"m4a", "mp3"} and not copy: args += ["-b:a", "256k" if profile == "m4a" else "320k"]
        return profile, args, {"m4a": "ipod", "mp3": "mp3", "flac": "flac", "wav": "wav"}[profile], not copy
    need_video = profile in {"h264", "hevc"} or not mp4_video
    need_audio = bool(af) and (not mp4_audio or (profile in {"h264", "hevc"} and ac != "aac"))
    args = ["-c:v", "copy", "-c:a", "copy"]
    if need_video:
        if str(vf.get("dynamic_range") or "SDR") != "SDR":
            raise ValueError("HDR 來源請用原編碼／自動格式保存，避免轉成 SDR 時色彩失真。")
        target = "hevc" if profile == "hevc" else "h264"
        choices = [target + "_videotoolbox", "libx265" if target == "hevc" else "libx264"]
        encoder = next((name for name in choices if name in encoders), None)
        if encoder is None: raise ValueError(f"目前 FFmpeg 缺少 {target} 編碼器，請更新 a-Shell 或選原編碼。")
        pixels = number(vf.get("height")) * number(vf.get("width")) or 1920 * 1080
        bitrate = max(2_000_000, min(120_000_000, round(pixels * max(24, number(vf.get("fps"))) * (0.10 if target == "hevc" else 0.16))))
        args = ["-c:v", encoder, "-b:v", str(bitrate), "-pix_fmt", "yuv420p", "-c:a", "copy"]
        if encoder.endswith("_videotoolbox"): args += ["-allow_sw", "1"]
        else: args += ["-preset", "medium"]
        if target == "hevc": args += ["-tag:v", "hvc1"]
    if need_audio:
        if "aac" not in encoders: raise ValueError("目前 FFmpeg 缺少 AAC 編碼器，請選原編碼。")
        args += ["-c:a", "aac", "-b:a", "256k"]
    return "mp4", args + ["-movflags", "+faststart"], "mp4", need_video or need_audio


def encoder_set(runtime, slot):
    output = slot / "encoders.txt"
    if runtime.run(["ffmpeg", "-hide_banner", "-encoders"], output, slot / "encoder-error.txt"):
        return set()
    return set(re.findall(r"^\s*[VAS][A-Z.]{5}\s+(\S+)", output.read_text(errors="replace"), re.MULTILINE))


def local_command(paths, output, progress, audio_only, plan):
    _, codecs, muxer, _ = plan
    args = ["ffmpeg", "-hide_banner", "-nostdin", "-n", "-loglevel", "warning"]
    for path in paths: args += ["-i", str(path)]
    if audio_only: args += ["-map", "0:a:0", "-vn"]
    else:
        args += ["-map", "0:v:0"]
        args += ["-map", f"{len(paths) - 1}:a:0?"]
    return args + codecs + ["-progress", str(progress), "-f", muxer, str(output)]


def download_tracks(ydl, entry, cache, concurrency, update, check_cancel):
    from yt_dlp.downloader import get_suitable_downloader
    from yt_dlp.utils import DownloadCancelled
    paths = []
    selected = entry.get("requested_formats") or [entry]
    for index, fmt in enumerate(selected):
        check_cancel()
        fingerprint = {name: fmt.get(name) for name in ("format_id", "vcodec", "acodec", "width", "height", "fps", "language")}
        fingerprint["entry"] = entry.get("id")
        identity = hashlib.sha256(json.dumps(fingerprint, sort_keys=True).encode()).hexdigest()[:24]
        destination = cache / (identity + ".media")
        info = dict(entry, **fmt)
        headers = dict(entry.get("http_headers") or {})
        headers.update(fmt.get("http_headers") or {})
        if any("\r" in str(value) or "\n" in str(value) for value in headers.values()):
            raise ValueError("來源 HTTP 標頭不正確。")
        info["http_headers"] = headers
        for name in ("requested_formats", "requested_downloads", "entries", "formats"): info.pop(name, None)
        params = dict(ydl.params, continuedl=True, nopart=False, concurrent_fragment_downloads=concurrency,
                      retries=5, fragment_retries=5, skip_unavailable_fragments=False, fixup="never", external_downloader={}, hls_prefer_native=True,
                      quiet=True, noprogress=True)
        downloader_class = get_suitable_downloader(info, params)
        if downloader_class is None or downloader_class.__name__ in {"FFmpegFD", "ExternalFD"}:
            raise ValueError("此來源需要不受支援的外部下載器，請改用其他格式。")
        downloader = downloader_class(ydl, params)
        import threading
        import time
        progress_lock = threading.Lock()
        last_update = [0.0]
        def progress(hook):
            try: check_cancel()
            except InterruptedError as error: raise DownloadCancelled(str(error))
            with progress_lock:
                now = time.monotonic()
                if now - last_update[0] < 0.25 and hook.get("status") != "finished": return
                last_update[0] = now
            total = hook.get("total_bytes") or hook.get("total_bytes_estimate")
            done = hook.get("downloaded_bytes") or 0
            percent = min(0.99, max(0, done / total)) if total else None
            speed = hook.get("speed")
            eta = hook.get("eta")
            message = f"下載軌道 {index + 1}/{len(selected)}"
            if speed: message += f" · {speed / 1048576:.1f} MB/s"
            if eta is not None: message += f" · 約 {round(eta)} 秒"
            update(phase="downloading", message=message, progress=(index + percent) / len(selected) * 0.8 if percent is not None else None)
        downloader.add_progress_hook(progress)
        result = downloader.download(str(destination), info)
        succeeded = result[0] if isinstance(result, tuple) else result
        check_cancel()
        if not succeeded or not destination.is_file() or destination.stat().st_size <= 0:
            raise ValueError("軌道下載未完成；已保留可續傳暫存，請重試。")
        paths.append(destination)
    return paths
