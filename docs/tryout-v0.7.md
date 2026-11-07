# MediaPocket 0.7 試用

這是舊版本說明。0.8 已移除捷徑執行入口，改用 App 內選畫質；請使用 [0.8 步驟](tryout-v0.8.md)。

沿用原 Bundle ID，用免費簽署工具覆蓋安裝；版本應顯示 0.7.0。無須購買 Apple Developer 會員。不要先刪除舊 App，以免連同其本機資料一起刪除。

## 加入整個資料夾

1. 開啟「檔案庫」，最上方固定顯示「加入整個資料夾」。
2. 進入要加入的資料夾，按右上「開啟」。這個選擇器選的是資料夾，可逐層瀏覽子資料夾。
3. 返回 App 後點該來源播放。關閉並重新開 App，來源清單應保留；如提供者收回授權，可長按重新授權。

不複製媒體。只儲存來源紀錄；雲端檔案提供者可能下載其原檔或快取。App 沒有對外部來源提供改名或刪除操作。

## 先試現有 SMG 捷徑

1. 保留你已匯入且能使用的 SMG 捷徑，以及 a-Shell mini 中既有的 `Documents/v1.3.1.py`。
2. 到「下載 → 捷徑名稱與免費下載設定」，確認名稱與捷徑 App 中一致；預設 `SMG YouTube`。原 Python 的兩階段回呼也使用這個名稱，單改 App 欄位不會改寫 Python。
3. 貼 YouTube 或 Bilibili 連結，下載方式選「現有 SMG 捷徑」，按「使用 SMG 捷徑下載」。應進入原捷徑的整支／片段選單，接著在 a-Shell mini 解析，回捷徑選格式，再下載。
4. 在下載頁按「加入下載成品資料夾（原位置）」，選「我的 iPhone → a-Shell mini → youtube」或 `bilibili`。資料夾尚未建立時可先加入整個 mini 資料夾；成品從檔案庫直接讀取。

原捷徑只有 YouTube／Bilibili 路線，沒有新增 Instagram／Threads 支援。交接任務不會收到最終完成通知，App 明確標示尚未驗證結果。重按「開啟 SMG 捷徑」會重新開始原捷徑，不能當作恢復進度。

呼叫採 Apple 的 [run-shortcut URL scheme](https://support.apple.com/en-au/guide/shortcuts/apd624386f42/9.0/ios/26)，以 text 傳入完整來源網址。App 不修改、重新簽署或公開你附的捷徑檔。對原捷徑做的是離線結構分析，尚未在實體 iPhone 跑完下載。

## App FFmpeg 的啟動診斷

這是另一條路線，使用免費完整版 a-Shell。首次先在下載設定授權 `MediaPocket/MediaPocketBridge` 子資料夾，再按安裝／更新。下載時保持 a-Shell 在前景。

終端階段依序應為：

1. `[MediaPocket] MediaPocket 下載程式已啟動 v0.7.0`。
2. 安裝元件，或開始下載時顯示「載入 yt-dlp」。
3. 「yt-dlp 已啟動，正在解析」。
4. 「解析完成」及「FFmpeg 下載與合併」。

若再次失敗，回報最後出現的階段與最後一段錯誤即可。缺少第一行只代表尚未觀察到 companion 啟動，不能據此認定 yt-dlp 安裝失敗。Cookie、Authorization 和含權杖的完整來源網址不要貼出。

App FFmpeg 的成品移入「檔案庫 → App 內檔案 → Downloads」。這個 App 管理區與直接連結 mini 成品資料夾是不同位置。

## 驗證範圍

本機測試涵蓋啟動失敗狀態與舊任務相容性；macOS CI 使用真實 FFmpeg 的本地 HTTP 樣本、Swift Core 測試，以及 iOS Simulator 的播放／縮放與重啟來源還原。四平台實際下載、已安裝捷徑、外部檔案提供者授權與硬體解碼仍需實體手機驗證。
