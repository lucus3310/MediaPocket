# MediaPocket

以 SwiftUI 製作的個人 iPhone 影音工具。目標是整合本機檔案管理、多格式播放，以及透過 FFmpeg 處理平台影音下載。

目前版本 **0.3.0 為逐幀播放器試用版**：保留檔案管理、垃圾桶與雙播放引擎，改用自訂播放控制，加入真正的前／後一幀、毫秒時間、雙指 1–8 倍縮放、放大拖曳與雙擊重置。逐幀先暫停，再由引擎選擇相鄰畫格，不使用 `1 / 平均 fps` 的時間跳轉冒充逐幀。

系統引擎使用 `AVPlayerItem.step(byCount:)` 並檢查 `canStepForward`／`canStepBackward`。VLC 使用 `gotoNextFrame`／`gotoPreviousFrame`，等待其結果回呼；某來源不支援反向逐幀時會明確顯示訊息。VLC 優先選擇 VideoToolbox 解碼器並允許其他解碼器回退；系統引擎由 AVFoundation 選擇可用的硬體路徑。介面「硬體優先」描述選擇策略，不宣稱每個檔案目前都在硬體解碼。

縮放由 UIScrollView 直接變換 AVPlayerLayer／VLC 顯示層，不反覆產生放大點陣圖；旋轉螢幕時重設為 1 倍。iOS Simulator 整合測試會產生 CFR／VFR H.264 樣本，核對系統逐幀的相鄰時間戳、VLC 前後逐幀回呼，以及 8 倍顯示層縮放、拖曳與旋轉重置。實際雙指操作、硬體解碼、耗電、HDR 與每種來源的幀行為仍需 iPhone 實測。

FFmpeg 下載、多平台解析與背景處理尚未整合。個別容器／編碼、字幕、HDR 和音軌行為仍需 iPhone 實測；成功編譯不代表所有影片都能播放。

檔案副本與還原遇到同名檔案會自動編號，重新命名則遇到重名就拒絕。垃圾桶不會自動清空，內容仍佔用手機空間。使用 Swift Testing 測試路徑邊界、符號連結、資料夾循環、中文與空白檔名及同名檔案保存；CI 先跑 `swift test --parallel` 再編譯 iOS。

VLCKit 固定到官方 revision `6629ecb91e7e05e6b3fcbf77b17d0421cff37923`，由該版本 Swift Package checksum 驗證官方二進位檔。授權全文放在 App「設定 → VideoLAN VLCKit 與授權」及 `Sources/Resources/VLCKit-COPYING.txt`。可由 [VideoLAN 原始碼與建置流程](https://github.com/videolan/vlckit/tree/6629ecb91e7e05e6b3fcbf77b17d0421cff37923) 取得來源並重建套件，替換 `project.yml` 中的 dependency 後重編 MediaPocket。

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
