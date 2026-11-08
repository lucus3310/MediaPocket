# MediaPocket 0.10.1（12）驗證紀錄

日期：2026-11-08。App 原始碼 commit：`fbfc31f859caafc7e40a03d020dbd5cd0539e045`。

[成功的 GitHub Actions](https://github.com/lucus3310/MediaPocket/actions/runs/42495393257)，[IPA 與測試報告](https://github.com/lucus3310/MediaPocket/actions/runs/42495393257/artifacts/13624085863)。公開專案使用標準 `xcode-27` runner，輸出未簽名 iPhoneOS IPA，不使用付費帳號或外部下載 App。

## 問題與修正

使用者回報所有 YouTube 連結按「取得可用畫質」都會跳轉或開啟黑色播放器。原本內建 WebKit 提供者沒有下載解析專用的導向、開視窗及媒體播放限制。

本版透過 Swift `WKNavigationDelegate`／`WKUIDelegate`、公開播放設定、媒體暫停 API 和頁面起始注入腳本限制解析器。保留空白文件、JavaScript 運算、console 回傳與 `canPlayType` 能力查詢；正常 AVPlayer／VLC 不套用這些限制。解析失敗會在下載頁顯示錯誤。

第一次模擬器回歸測試發現 `blockedNavigations` 沒有增加。編譯器同時警告舊式 completion handler 的方法簽名未符合協定。改用非同步導向協定方法後，以相同測試重跑，沒有移除原有斷言。

## 驗證結果

- 29 項 Swift 核心測試、25 項真實 FFmpeg 桌面測試全部通過；桌面測試無跳過。
- iPhone 17／iOS 27 模擬器 Debug 的 8 項整合測試全部通過，包含逐幀、A–B、8 倍顯示層縮放、原位置播放及內建下載引擎。
- Release（`-O`）的 2 項原生引擎測試全部通過，不重用 Debug 結果。實際呼叫 App 內 CPython、WebKit、FFmpeg 和 ffprobe。
- Debug 與 Release 的解析器報告均為：影片／音訊播放回傳 `NotAllowedError`，新視窗被阻擋、媒體維持暫停、沒有全螢幕、網址維持 `about:blank`，格式能力查詢保留。JavaScript 訊息正確回傳 `3`；Swift 另外確認原生導向攔截計數增加，且沒有呈現新控制器。標準 Fullscreen API 在該模擬器回報 unavailable；另有呼叫存在時的 WebKit 影片全螢幕 API。
- 內建下載測試完成本機 HTTP 分離影音下載及 MP4 合併、FFmpeg 直接下載 MKV、MP3 轉檔；ffprobe 確認預期軌道。
- 真實軟體鍵盤 XCUITest 通過，收合兩次、保留輸入 URL，設定頁顯示內建引擎。
- App 終止後重啟還原 2 筆原位置來源，原檔網址與內容一致；來源目錄 3811 bytes。此測試使用 App 所有的樣本檔案。
- 取回產物後核對 GitHub ZIP SHA-256、IPA ZIP 完整性、版本／build、iPhoneOS／ARM64 框架、內嵌 Python 套件、解析器防護資源與實際套件修補內容。Release IPA 不含測試 fixture 或未轉換的 `.so`／`.pyc`。

## 安裝檔

`MediaPocket-unsigned.ipa`：44,725,040 bytes，版本 **0.10.1（12）**，未簽名，沿用免費自簽方式安裝。

SHA-256：`d523e69787b10772d6ec97988aa09102a779bc5248d318e9ded8c63d16f80f6f`。

產物 ZIP SHA-256：`610cc48591bd4885634cb57857b29e4412c0f3e1f69b15560786633382fcf6d4`。

## 實測範圍

WebKit 測試主動執行媒體播放、全螢幕、開新視窗、`youtube://` 與 YouTube HTTPS 導向，再核對 JavaScript 結果、原生攔截紀錄與沒有新呈現的控制器。它驗證解析器隔離策略，不等於已在實體 iPhone 重現並排除使用者的同一個畫面。

下載整合使用本機 HTTP 媒體樣本。四平台即時解析、實體 iPhone 16／iOS 27 的完整下載、4K／8K 效能，以及外部檔案提供者的長期授權仍需裝機試用。原位置來源、逐幀、縮放與播放器的既有驗證範圍見 [0.10.0 紀錄](validation-v0.10.0.md)。
