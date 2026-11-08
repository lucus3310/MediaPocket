"""Shared resolver-only media policy; never installed in the actual player."""
from pathlib import Path

MEDIA_GUARD = Path(__file__).with_name('ResolverMediaGuard.js').read_text(encoding='utf-8')
