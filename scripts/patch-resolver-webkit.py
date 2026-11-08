"""Patch the pinned WebKit factory to run only as a link resolver."""
from pathlib import Path
import sys


def patch_api(source):
    if '# MediaPocket resolver-only policy' in source:
        return source
    edits = [
        ('from .consts import SCRIPT_PHOLDER, SCRIPT_TEMPL',
         'from .consts import SCRIPT_PHOLDER, SCRIPT_TEMPL\n'
         '# MediaPocket resolver-only policy\nfrom resolver_policy import MEDIA_GUARD\nimport _mediapocket'),
        ('real_script = SCRIPT_TEMPL.replace(SCRIPT_PHOLDER, script)',
         'real_script = MEDIA_GUARD + SCRIPT_TEMPL.replace(SCRIPT_PHOLDER, script)'),
        ('                        exsk.callback(pa.release_obj, p_cfg)',
         '                        exsk.callback(pa.release_obj, p_cfg)\n'
         '                        pa.send_message(p_cfg, b"setAllowsInlineMediaPlayback:", c_bool(True), argtypes=(c_bool,))\n'
         '                        pa.send_message(p_cfg, b"setAllowsPictureInPictureMediaPlayback:", c_bool(False), argtypes=(c_bool,))\n'
         '                        pa.send_message(p_cfg, b"setAllowsAirPlayForMediaPlayback:", c_bool(False), argtypes=(c_bool,))\n'
         '                        pa.send_message(p_cfg, b"setMediaTypesRequiringUserActionForPlayback:", c_ulong(3), argtypes=(c_ulong,))'),
        ("                    pa.logger.trace('webview full init')",
         "                    _mediapocket.configure_webview(p_webview.value)\n"
         "                    pa.logger.trace('webview full init')"),
    ]
    for old, new in edits:
        if source.count(old) != 1:
            raise RuntimeError('Pinned WebKit source changed; resolver patch cannot be safely applied')
        source = source.replace(old, new, 1)
    return source


if __name__ == '__main__':
    path = Path(sys.argv[1])
    path.write_text(patch_api(path.read_text(encoding='utf-8')), encoding='utf-8')
