# Windows 自簽與裝機驗證

適用於只有 Windows、使用免費 Apple 帳號的個人安裝。IPA 必須先由 macOS／Xcode 編譯，Sideloadly 負責重簽與安裝。

## 準備

1. 從 [Sideloadly 官方網站](https://sideloadly.io/) 下載 Windows 版本，依當時官網指示準備 Apple 元件。若需替換既有 iTunes／iCloud，先確認自己的備份與同步需求。
2. 從 GitHub Actions 成功的執行紀錄下載產物 ZIP，解壓縮取得 `MediaPocket-unsigned.ipa`。
3. 用 USB 連接 iPhone，解鎖手機並在提示時選擇「信任此電腦」。

## 簽署與安裝

1. 開啟 Sideloadly，選擇已連線的 iPhone，拖入 IPA。
2. 在 Sideloadly 內輸入自己的 Apple 帳號並完成 Apple 驗證；不要把密碼或驗證碼傳到聊天或提交 GitHub。
3. 使用免費 Apple ID sideload 模式。保留固定 Bundle ID；若第一次安裝必須調整它，記下設定，之後沿用。
4. 按 Start，等待安裝完成。
5. 在 iPhone 依系統提示啟用「設定 → 隱私權與安全性 → 開發者模式」，必要時重新開機。
6. 依系統提示到「設定 → 一般 → VPN 與裝置管理」信任開發者，開啟 MediaPocket。

免費 profile 七天到期，每裝置最多三個此類 App；限制與更新規則見 [Apple 官方說明](https://developer.apple.com/help/account/basics/about-your-developer-account/)。Sideloadly 的自動刷新需要電腦與手機能連線；首次 USB 成功後再依官方指示設定 Wi-Fi 刷新。

## 第一次實機驗收

- [ ] App 能啟動，檔案庫、下載與設定分頁可操作。
- [ ] 在設定寫入一段測試備註。
- [ ] 匯入一個你有權使用的小型 H.264／AAC MP4，確認能播放、有聲音、可快轉和關閉播放器。
- [ ] 再匯入同名檔案，確認產生另一個檔名而沒有覆蓋原檔。
- [ ] 到「檔案 → 我的 iPhone → MediaPocket → Media」確認檔案可見。
- [ ] 結束 App 再開啟，確認檔案和備註仍保留。
- [ ] 用同一個 Bundle ID 重新簽署／覆蓋安裝，確認檔案和備註保留。
- [ ] 記錄 iOS 版本、App 版本及失敗步驟，作為下一階段依據。

更新時不要先刪除 App；刪除 App 會移除其本機資料。重要媒體請另外存一份到 App 外的目錄。
