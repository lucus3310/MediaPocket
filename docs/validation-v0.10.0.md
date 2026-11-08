# MediaPocket 0.10.0（11）驗證紀錄

日期：2026-11-08。App 原始碼 commit：`0479a7636cd38c20a1247c0c5d18d9e6981ae2fc`。

[成功的 GitHub Actions](https://github.com/lucus3310/MediaPocket/actions/runs/42459847501)，[IPA 與測試報告](https://github.com/lucus3310/MediaPocket/actions/runs/42459847501/artifacts/13609437915)。使用公開專案標準 `xcode-27` runner，無 Apple 付費帳號、付費後端或 a-Shell。

## 結果

- 29 項 Swift 核心測試通過：原位置來源、資料夾、書籤、來源重連、下載任務、取消／重試與移入檔案庫。
- 25 項桌面測試通過且無跳過：真實 FFmpeg、本機 HTTP／HLS、Range 續傳、格式選擇、4K60／8K 保留、合併與轉檔。
- iPhone 17／iOS 27 模擬器 Debug：8 項整合測試通過，包含系統／VLC 逐幀、8 倍顯示層縮放、A–B 循環、原位置播放、6 次 VLC 停止／重開，以及原生下載與 WebKit console。
- 模擬器 Release（`-O`）：2 項整合測試通過。實際在 App 的 CPython／FFmpeg 框架執行分段下載後合併 MP4、FFmpeg 直接 HTTP 下載 MKV、MP3 音訊轉檔及 ffprobe 軌道驗證；WebKit console 收到計算結果 `3`。
- 真實軟體鍵盤 XCUITest 通過：兩次收合、URL 保留、內建引擎就緒、設定頁可用且沒有外部授權操作。
- 終止後重開 App 的來源還原通過，兩筆來源解析至相同原檔、內容前綴與大小一致；書籤目錄為 3811 bytes。
- 下載後另行核對 ZIP SHA-256、IPA 完整性、版本、iPhoneOS／ARM64 框架、Python 套件與授權檔；Release IPA 不含測試模組或未轉換的 `.so`。

## 安裝檔

`MediaPocket-unsigned.ipa`：44,717,653 bytes，未簽名，需沿用免費自簽方式安裝。

SHA-256：`b68a8f63d3076caa97d689cffb5c07d603fa43209fd8745f7debe2df80ce940d`。

## 實測範圍

模擬器下載測試使用本機 HTTP 來源，沒有聲稱已在四個平台即時下載成功。實體 iPhone 16／iOS 27 的平台解析、登入權限、網路速度、硬體加速、雙指實際操作、HDR 及外部檔案提供者授權延續，仍需裝機試用。8K 真機下載與播放效能也未實測。

本版同時修正了原生 CLI 連續命令的執行緒設定殘留、最佳化時的 C 回呼物件生命週期、FFmpeg 紀錄等級，以及崩潰紀錄證實的 VLC 回呼內釋放問題。
