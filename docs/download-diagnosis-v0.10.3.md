# 0.10.3：畫質可選、按下載卻失敗的調查

日期：2026-11-11。使用者提供 `v1.3.1.py`（內部版本 3.26.0）與 `SMG+YouTube.shortcut`，並確認 App 可以列出畫質／格式，開始下載後失敗。

## 已確認的根本缺陷

直接檢查已交付的 0.10.2（13）IPA，`Frameworks/libavformat.framework/libavformat` 的實際編譯設定包含：

```text
--disable-autodetect --disable-securetransport --disable-openssl
```

該二進位也沒有 Apple SecureTransport、GnuTLS、OpenSSL 或 mbedTLS 握手函式參照。FFmpeg 的 HTTPS 輸入需要 TLS 後端，單純把 `https` 放進 protocol whitelist 不會增加編譯時缺少的能力。

平台頁面／格式由 CPython 與 yt-dlp 解析，其 HTTPS 能力與 FFmpeg 相互獨立。因此能產生畫質清單，同時 FFmpeg 仍無法開啟實際 HTTPS 媒體網址。原來的原生整合測試只使用 `http://127.0.0.1`，所以沒有發現這個缺陷。

受檢查的舊 IPA SHA-256：`3d93b65ebc5cac872ee51c46a82aa739ab06decfde17c90e8e2a6dd67f3f9d77`。這是舊交付檔案的證據，不是從使用者手機匯出的錯誤紀錄；仍不能宣稱平台權限、簽章與限流等其他問題都已排除。

## 與成功捷徑的實際差異

捷徑解碼後共有 53 個動作，包含 a-Shell mini 的 ExecuteCommandIntent／GetFileIntent，並引用 `v1.3.1.py`。Python 腳本最後呼叫 `yt_dlp.main(args)`，設定 `-N 4` 與指定格式，沒有強制 `--downloader ffmpeg`。它讓 yt-dlp 根據來源選擇下載器，FFmpeg 也用於合併、片段下載或成品驗證。

App 預設由 yt-dlp 解析、FFmpeg 直接傳輸，並使用自己內嵌的函式庫；不會繼承 a-Shell 的命令、TLS 能力或 Cookie。兩者不是同一套執行環境。

參考腳本另有平台專用 Referer，以及 Bilibili `Range: bytes=0-`。本次補齊 Bilibili／Instagram 的解析標頭。直接 FFmpeg 模式仍讓 FFmpeg 自行管理 Range：FFmpeg 會為初次讀取及後續跳位產生對應 Range，不能把參數清單未轉送 Range 當成 HTTP 請求一定沒有 Range，也不能固定覆寫所有跳位請求為零。

附件識別：

- Python SHA-256：`970e4d4f90d4cd2343b002a4a0fd9e2d25f5b23ce16a23927e66a59ed4476a7c`。
- Shortcut SHA-256：`0abe0f6f428253674ee5ae7af628f838ac01235152051889a4299c934b2770cb`。

原附件與既有捷徑未被修改或執行；公開專案只保存比較結論。

## 修正

- 從固定 FFmpegKit 來源啟用 Apple SecureTransport，重建 iPhone／Simulator ARM64 的 libavformat；核對 Mach-O ABI major 和 framework install name 後替換。保留原本 CLI、編碼器及其餘函式庫，避免重建最小版本而失去既有編碼器。
- 原生 C API 直接呼叫該 libavformat 的 `avio_enum_protocols`。啟動檢查必須包含 `https` 與 `tls`，否則不能顯示引擎就緒。
- 打包時檢查實際 framework 是否帶有啟用 SecureTransport 的編譯設定。
- 模擬器以 CI 臨時產生的 loopback 身分實際建立 HTTPS 伺服器，僅在該模擬器信任此測試根。FFmpeg 使用 `tls_verify=1` 下載分離影音並合併 MP4，ffprobe 核對軌道。正式 IPA 不含測試憑證或私鑰。
- 錯誤訊息列出退出碼、已辨識的 HTTP 401／403／404／429、TLS、逾時、編碼器與空間錯誤；不直接顯示可能含 Token 的原始紀錄。ffprobe 驗證失敗另行標示，畫面提供「複製錯誤」。
- 額外以真實 FFmpeg HTTP 403 驗證失敗訊息與未完成成品不匯入。

## 驗證與交付

Windows 合約測試：16 項通過，12 項需要 macOS／真實 FFmpeg 的項目跳過。

[本次 GitHub Actions 全部通過](https://github.com/lucus3310/MediaPocket/actions/runs/42970354736)，[IPA 與測試報告](https://github.com/lucus3310/MediaPocket/actions/runs/42970354736/artifacts/13833774184)。App 原始碼 commit：`95b22a5ec1855bc682296b5da630c296d1929054`。

- 29 項 Swift 核心、28 項桌面測試全部通過；桌面測試無跳過。
- iPhone 17／iOS 27 模擬器 Debug 8 項、Release 2 項整合測試通過。兩種配置都完成開啟憑證驗證的原生 FFmpeg HTTPS 分離影音下載、MP4 合併及 ffprobe 軌道驗證；下載呼叫禁止回退到 yt-dlp。
- Debug／Release 的 C API 原生輸入協定清單均包含 `https` 與 `tls`，保存在 `native-protocols.txt` 與 `native-release-protocols.txt`。
- 真實 FFmpeg HTTP 403 會在任務訊息顯示 HTTP 403，未完成成品不匯入。這是受控失敗案例，不是使用者真機錯誤紀錄。
- 原有 HTTP 下載、MP4／MKV 合併、MP3、WebKit 防播放／導向、逐幀、8 倍顯示層縮放、A–B 及鍵盤測試通過。
- 原位置來源終止後重啟還原 2 筆，原始網址與內容一致，目錄為 3811 bytes；測試使用 App 所有的檔案，未宣稱外部 File Provider 授權已驗證。
- 取回後核對 GitHub ZIP SHA-256、IPA 完整性、版本、ARM64 框架、資源與原始碼一致性，以及 Device libavformat 的 `--enable-securetransport` 設定和 `SSLHandshake` 參照。正式 IPA 不含 loopback 憑證或私鑰。

實際 libavformat 重建來源為 FFmpeg 6.0、commit `ea3d24bbe3c58b171e55fe2151fc7ffaca3ab3d2`，configure SHA-256 為 `aa932bed735a0e36de9a7bf6ea9a60b5d3b79eec4ef87c5cb862a2b734b1092a`。重建資訊與兩個 ARM64 二進位雜湊均隨 App 的 native-build.json 保存。

## 安裝與回報

`MediaPocket-unsigned.ipa`：44,730,925 bytes，**0.10.3（14）**，未簽名，沿用免費自簽方式、相同 Bundle ID 覆蓋安裝。

IPA SHA-256：`0fd1c125965ddd04241654f60dd5b483dc131c076333324d2688b5a5cb2def03`。

產物 ZIP SHA-256：`5f55648eea8793a96c45bc811498bf82b2b6089766ea94d4223e672ed79b662f`。

更新後重新取得畫質再下載。如果仍失敗，按提示中的「複製錯誤」，可回報實際失敗類別；不需另外執行捷徑或 a-Shell。原始 ffmpeg-error.txt 仍可能包含私人 CDN 網址，不必整份公開。

此版維持 App 內執行與免費公開 GitHub Actions。原位置檔案、來源資料夾、逐幀播放器、8 倍縮放與鍵盤功能保留。真機平台下載仍需更新後試用；如果還有失敗，複製的新錯誤可區分下一個阻礙。
