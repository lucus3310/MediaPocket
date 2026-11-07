# MediaPocket 0.4：免費 FFmpeg 下載試用

沿用 `io.github.lucus3310.MediaPocket`，以免費 Sideloadly 覆蓋安裝新版 IPA；簽署方式與七天期限不變。請保留重要媒體的備份。

## 手機首次設定

1. 在 App Store 安裝免費完整版 [a-Shell](https://apps.apple.com/app/a-shell/id1473805438)。
2. MediaPocket → 下載 → 首次使用 →「1. 授權下載交接資料夾」。選「瀏覽 → 我的 iPhone → MediaPocket → MediaPocketBridge」子資料夾，進入後按開啟。不要選 App 最外層或 Media；iOS 可能把最外層實際命名為 Documents，導致書籤名稱不符。這個步驟會重設舊的 MediaPocketBridge 書籤。
3. 返回 MediaPocket，按「2. 安裝／更新解析元件並檢查 FFmpeg」。等待 a-Shell 安裝純 Python 套件、檢查 FFmpeg 與 ffprobe；完成後會嘗試返回 App，也可手動返回。
4. 顯示「已就緒」後，貼上影片／貼文連結，選原畫質、1080p 或 720p，按「交給 a-Shell 下載」。只取音訊可開啟對應開關。
5. 下載期間保持 a-Shell 在前景。完成後返回 MediaPocket，必要時按重新整理。成品在「檔案庫 → Downloads → 任務編號」。

影片保存為 MKV、音訊保存為 MKA，以 FFmpeg stream copy 保留編碼，不重新壓縮；用 VLC 播放。分離影音會明確對應影片與音軌。單則多影片貼文最多 20 段。畫質是上限，實際受來源、帳號權限與可直接由 FFmpeg 取得的格式限制。目前不支援進行中的直播、整個頻道、整份播放清單或 DRM。

## 平台與登入

- YouTube：`watch`、`youtu.be`、Shorts、直播回放；使用 yt-dlp、EJS 與 Apple WebKit challenge provider，部分來源仍可能要求登入、額外驗證或 PO token。
- Instagram：影片貼文、Reels、含影片的多張貼文；來源可能要求 Cookie 或受限流影響。
- Threads：公開影片貼文與分享連結。必須確認原貼文代碼，絕不使用推薦影片作為找不到目標時的替代。網頁變更或登入牆可能使解析失效。
- Bilibili：BV／av 與 b23.tv；分離音軌合併並傳遞來源 Referer／Cookie。登入、會員、地區限制仍適用。

需要 Cookie 時，把 Netscape 格式檔案放入手機「MediaPocket → MediaPocketBridge → cookies」，分別命名為 `youtube.txt`、`instagram.txt`、`threads.txt`、`bilibili.txt`。Threads 目前僅處理公開來源，Cookie 不代表可下載私密貼文。Cookie 不送到雲端編譯，也不要提交到 GitHub。

## 失敗或中斷

任務狀態與 FFmpeg 日誌保存在「MediaPocketBridge → jobs → 任務編號」。失敗檔案不匯入檔案庫。錯誤日誌可能包含暫時來源網址，回報時請先遮住 Cookie、網址參數與登入資訊。

「要求取消」會寫入取消旗標；a-Shell 執行中的原生 FFmpeg 在返回安全檢查點後才會處理。要立即停止可在 a-Shell 使用 Ctrl+C。若 iOS 終止 a-Shell，可再次開啟原任務從頭下載；已完成的任務不會重複下載。失敗／取消後按「建立重試任務」，會重新解析來源。原始暫存保留供診斷，可在確認不再執行後透過「檔案」清理整個舊任務資料夾。

## 驗證範圍

CI 測試使用本地 HTTP 伺服器及真實 FFmpeg／ffprobe，驗證 Cookie／Referer、分離音軌合併、HLS、只取音訊、取消、失敗與輸出軌道。Swift 測試驗證網址邊界、持久化、整批匯入與重複回呼。既有逐幀／縮放 Simulator 測試保留。

這些測試不等於 iPhone 實測，也不保證四個平台目前每支公開影片都能解析。請優先回報：a-Shell 版本、步驟 2 的訊息、平台與任務狀態、能否看到成品及有無聲音。真機書籤、URL scheme、原生 FFmpeg、WebKit challenge 與平台實際下載仍需手機驗證。

## 免費與來源

不需要付費 API、伺服器或 Developer 會員。App 透過公開 GitHub 標準 macOS runner 編譯；下載與解析在手機的 a-Shell 執行。執行時會安裝固定版本的 [yt-dlp](https://github.com/yt-dlp/yt-dlp)、[EJS](https://github.com/yt-dlp/ejs)、[Apple WebKit provider](https://github.com/grqz/yt-dlp-apple-webkit-jsi) 與 [Threads extractor](https://github.com/tribixbite/yt-dlp-threads)。a-Shell 的跨 App 資料夾存取見[官方 Sandbox and Bookmarks 文件](https://github.com/holzschu/a-shell#sandbox-and-bookmarks)。
