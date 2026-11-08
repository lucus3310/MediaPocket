// Resolver pages compute metadata/signatures; media playback belongs to the
// app's real player. This runs before each solver script and in new frames.
(() => {
    if (globalThis.__mediaPocketResolverGuard) return;
    Object.defineProperty(globalThis, '__mediaPocketResolverGuard', { value: true });
    const denied = () => Promise.reject(new DOMException('Playback is disabled in the link resolver', 'NotAllowedError'));
    const protect = (prototype, name, value) => {
        if (!prototype || !(name in prototype)) return;
        Object.defineProperty(prototype, name, { value, writable: false, configurable: false });
    };
    protect(globalThis.HTMLMediaElement?.prototype, 'play', denied);
    for (const name of ['requestFullscreen', 'webkitRequestFullscreen', 'webkitRequestFullScreen']) {
        protect(globalThis.Element?.prototype, name, denied);
    }
    for (const name of ['webkitEnterFullscreen', 'webkitEnterFullScreen']) {
        protect(globalThis.HTMLVideoElement?.prototype, name, () => {});
    }
})();
