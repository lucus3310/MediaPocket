# MediaPocket 0.8 試用

這版在 App 內貼連結、選畫質，直接交給免費完整版 a-Shell 執行 FFmpeg。不需要建立或執行捷徑；原 SMG 捷徑僅作參考。沿用原 Bundle ID 自簽覆蓋安裝，設定中的版本應為 0.8.0。

## 首次設定

1. 到「下載 → 右上齒輪」，先安裝／更新免費完整版 a-Shell。
2. 按「授權下載交接資料夾」，進入「我的 iPhone → MediaPocket → MediaPocketBridge」，按開啟。
3. 回 App 按「安裝／更新解析元件並檢查 FFmpeg」。完成後手動返回也可以。

使用 App 附帶的 `runner.py`，不呼叫你既有的 `v1.3.1.py`。已安裝的相同解析套件可沿用。a-Shell mini 的原捷徑設定與這套完整版交接資料夾是不同路線。

## 一次下載

1. 在 App 的下載頁貼上 YouTube、Instagram、Threads 或 Bilibili 的 HTTPS 影片／貼文連結，按「取得可用畫質」。
2. a-Shell 的 yt-dlp 解析來源，完成後嘗試返回 MediaPocket；也可手動返回並重新整理。此時不啟動 FFmpeg 媒體下載。
3. 在任務卡片的「畫質與音訊」選單選擇實際可用的解析度、最高可用畫質或純音訊，再按「交給 a-Shell 用 FFmpeg 下載」。
4. 下載期間保持 a-Shell 在前景；完成後返回 App，成品會經軌道驗證再匯入「檔案庫 → App 內檔案 → Downloads」。

選單會保留，重開 App 可以繼續選擇。多影片貼文的固定解析度必須每段都有提供；各片最高畫質則分別取各段最佳來源。來源未標示解析度時只提供最高可用選項，來源沒有音軌時不會憑空加入音訊選項。

開始下載時重新取得有效來源網址。固定解析度已不可用或貼文影片清單改變時會失敗，請重新取得畫質；不會自動換成較低解析度。畫質取決於公開／已登入帳號可見的來源，不承諾一定有 4K 或特定格式。原編碼封裝為 MKV／MKA，不重新壓縮。片段時間選取尚未移植到這個 App 流程。

## 排錯

終端第一行應為「MediaPocket 下載程式已啟動 v0.8.0」，接著顯示載入 yt-dlp、解析完成，以及下載階段的 FFmpeg 訊息。若看不到第一行，先記錄 Python 檔案或資料夾相關的終端錯誤，不能直接認定 yt-dlp 安裝失敗。

需要登入時，Netscape Cookie 檔放在「MediaPocket → MediaPocketBridge → cookies」，分平台命名。Cookie 留在手機；不要分享含 Cookie、Authorization 或 CDN 權杖的完整記錄。限流、平台驗證與來源權限仍可能導致失敗。不處理 DRM 或未支援的分片傳輸。

若自動返回失敗，手動返回 App 重新整理。若 iOS 終止 a-Shell，下載不會繼續；可在終端停止舊任務後重試，未完成媒體不匯入。

## 驗證範圍

本機測試涵蓋可用畫質產生、音軌選擇、過期畫質拒絕、舊紀錄相容。macOS CI 以本地 HTTP 樣本測試「解析 → 畫質清單 → App 選擇資料 → 真實 FFmpeg 下載」影片及音訊路徑，並做 iOS Simulator 播放、縮放、來源重啟與原生畫面檢查。這些不等於四平台真機下載成功，仍需你在 iPhone 試用回報。

設計依據：[a-Shell 原始專案](https://github.com/holzschu/a-shell)、[yt-dlp 原始專案](https://github.com/yt-dlp/yt-dlp)。
