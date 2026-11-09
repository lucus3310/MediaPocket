# MediaPocket 0.10.2（13）：預設 FFmpeg 直接下載

0.10.1 預設由 yt-dlp 傳輸影音軌道，再用 FFmpeg 合併／轉檔。0.10.2 改為 FFmpeg 自己讀取媒體來源下載、合併與轉檔；yt-dlp 保留作平台網址與畫質解析，不負責預設模式的媒體傳輸。它仍會讀取平台頁面及必要的來源資訊，因此這個版本不是移除 yt-dlp 的版本。

## 使用

1. 沿用相同 Bundle ID 免費自簽並覆蓋安裝 **0.10.2（13）**。
2. 「下載 → 設定」應顯示「FFmpeg 直接下載（預設）」，「改用 yt-dlp 分段下載」保持關閉。升級不沿用舊版自動開啟的 fastDownloads 偏好；之後只有主動選擇的設定會保存。
3. 貼平台連結、取得畫質、選來源與輸出格式，再開始下載。FFmpeg 模式也可選自動 MP4／MKV、原編碼、H.264／HEVC 或音訊格式，取決於來源與可用編碼器。
4. 成品照常加入 Downloads，使用既有檔案庫與逐幀播放器。

選輸出格式不會隱性改用 yt-dlp 下載。重試舊任務也依目前設定決定傳輸模式。設定中仍保留明確標示的 yt-dlp 分段模式，只有自行開啟才使用；FFmpeg 失敗不自動回退到它。

## 限制

FFmpeg 輸入為解析後的 HTTP／HTTPS／HLS 或分離影音來源網址，不直接把 YouTube 影片頁當媒體讀取。片段清單形式的 DASH 格式未加入直接模式，這類來源不在直接模式的畫質選項中；若該影片只有這種來源，會回報沒有可用格式，不假裝已下載完整影片。

FFmpeg 可以合併與轉檔，但無法補出來源沒有的畫質。預設原編碼或相容時無損封裝；必要轉碼會耗時與耗電。HDR 遵循既有保留原編碼政策。FFmpeg 重試會重新讀取來源，不保證接續舊暫存。請保持 App 在前景。

來源資料夾原位置播放、書籤、逐幀、8 倍縮放、雙播放引擎與鍵盤收合保留。

## 驗證

2026-11-09：[GitHub Actions 全部通過](https://github.com/lucus3310/MediaPocket/actions/runs/42558328542)，[IPA 與測試報告](https://github.com/lucus3310/MediaPocket/actions/runs/42558328542/artifacts/13648956985)。App 原始碼 commit 為 `98cba53a40a144e7d86251571a28b2719cfe5567`。

- 29 項 Swift 核心測試通過，包含舊分段任務重試時切換為 FFmpeg，並保留選擇資料。
- 26 項桌面測試全部通過，無跳過。新增測試禁止呼叫 yt-dlp 軌道下載器，實際用 FFmpeg 下載與輸出 MP4、H.264、MP3、M4A，ffprobe 核對音／影片軌道。
- iPhone 17／iOS 27 模擬器 Debug 8 項、Release 2 項整合測試通過。App 內 CPython／FFmpeg 實際完成 FFmpeg HTTP 原編碼下載、自動 MP4 封裝及 MP3 轉檔。這三種模式會禁止 yt-dlp 軌道下載呼叫；另保留選用模式的 2 組測試。
- WebKit 防播放／全螢幕／導向與 JavaScript 回傳、逐幀、8 倍顯示層縮放、來源書籤還原及既有播放器測試通過。
- 真實軟體鍵盤測試通過，另外以舊 fastDownloads 偏好開啟啟動 App，確認「FFmpeg 直接下載（預設）」存在且 yt-dlp 開關為關閉。
- 取回後核對 ZIP SHA-256、IPA 完整性、版本、iPhoneOS／ARM64 框架、Python 與解析器防護資源，並檢查 Debug／Release 下載報告含 3 種直接 FFmpeg 情境。

`MediaPocket-unsigned.ipa`：44,727,117 bytes，版本 **0.10.2（13）**，未簽名。

IPA SHA-256：`3d93b65ebc5cac872ee51c46a82aa739ab06decfde17c90e8e2a6dd67f3f9d77`。

產物 ZIP SHA-256：`0777775cbebe183210abeda6002ea17d6ff20636277d1796e7f67ec663c3f696`。

上述下載整合使用本機 HTTP 媒體樣本，不等於四平台即時下載、實體 iPhone 或 4K／8K 真機速度已驗證。FFmpeg 實際可取得的來源仍受平台、地區及登入權限限制。
