# MediaPocket

以 SwiftUI 製作的個人 iPhone 影音工具。目標是整合本機檔案管理、多格式播放，以及透過 FFmpeg 處理平台影音下載。

目前版本 **0.1.0 為安裝驗證版**：可從系統「檔案」選擇影片／音訊並複製到本機媒體庫，使用 AVPlayer 播放系統支援的媒體；「設定」內的備註可用來驗證更新後資料是否保留。

FFmpeg、VLCKit、多平台下載與背景處理尚未整合。成功編譯不代表已通過 iPhone 實測。

## 免費編譯

公開 repository 使用 GitHub Actions 的標準 `xcode-27` runner，不使用付費 larger runners、Apple 簽署憑證或雲端 Apple 登入。流程編譯 Simulator 與 iPhone device 版本，再輸出未簽署 IPA。

1. 開啟本專案的 **Actions → Build unsigned iOS IPA**。
2. 選擇成功的執行紀錄；也可以按 **Run workflow** 手動編譯。
3. 在 Artifacts 下載 `MediaPocket-unsigned-<編號>` ZIP 並解壓縮。
4. 取得 `MediaPocket-unsigned.ipa`、SHA-256 與版本資訊。

Artifacts 僅保留一天，以控制儲存量；需要時可重新編譯。GitHub 的免費標準 runner 規則見 [官方文件](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)。

有 Mac 時可安裝 Xcode、XcodeGen 後執行 `bash scripts/build-ios.sh`。Windows 只負責編輯與自簽，無法在本機執行 Apple SDK 編譯。

## 安裝到自己的 iPhone

見 [Windows 自簽與裝機驗證](docs/install-windows.md)。免費簽署有效七天，需要透過電腦定期刷新；它不等於永久簽署。

## 開發順序

1. 免費雲端編譯、Windows 簽署與 iPhone 更新驗證。
2. 擴充檔案管理與 VLCKit 格式支援。
3. App 內 FFmpeg：HTTPS／HLS 下載、分離影音合併、轉封裝。
4. a-Shell 任務交接與平台解析環境驗證。
5. YouTube、Instagram、Threads、Bilibili 逐站實測。
6. 背景工作、中斷恢復、字幕與播放體驗。

請勿提交登入資料、Cookie、私人下載來源或個人媒體檔案。
