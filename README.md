# MediaPocket

以 SwiftUI 製作的個人 iPhone 影音工具。目標是整合本機檔案管理、多格式播放，以及透過 FFmpeg 處理平台影音下載。

目前版本 **0.9.1** 修正下載頁的鍵盤收合及初次設定指引：輸入框旁與鍵盤工具列提供收合按鈕，未就緒時主要動作直接開啟設定，連結保留。見 [0.9.1 操作步驟](docs/tryout-v0.9.1.md)。

下載功能沿用 0.9：在 App 貼連結，解析後可按解析度、fps、編碼篩選來源，選輸出格式，再交由本機 a-Shell 的 yt-dlp 與 FFmpeg 下載、合併及需要時轉碼，完成後直接管理／播放。不需要任何捷徑或付費服務。保留原位置檔案管理、來源資料夾書籤、逐幀、8 倍縮放及雙播放引擎。見 [0.9 試用步驟](docs/tryout-v0.9.md) 與 [技術方案研究](docs/download-architecture-v0.9.md)。

新增來源格式細項（4K／8K、不同 fps、H.264／HEVC／VP9／AV1、HDR，只有來源實際提供才出現），支援 YouTube、Instagram、Threads、Bilibili、TikTok、X／Twitter、Vimeo、Dailymotion。原畫質模式不設 1080p 或 4K 上限，不放大或補幀冒充來源品質；固定格式失效時不自動降級。輸出可選自動無損 MP4／MKV、MKV／MKA 原編碼、MP4 相容轉碼／H.264／HEVC、相容原編碼 WebM，以及 M4A／MP3／FLAC／WAV。轉碼會視 FFmpeg 編碼器能力先選 VideoToolbox，再選可用軟體編碼器；不保證每個硬體或 build 都有每種編碼器。HDR 需保留原編碼，避免沒有 tone mapping 的轉碼破壞色彩。

預設使用 yt-dlp 原生 HTTP／HLS／DASH 下載器，HLS／DASH 可選 1／2／4／8 個分段並行，下載軌道後由 FFmpeg 本機合併／轉碼；一般 HTTP 不強制分塊。顯示速度與剩餘時間，失敗／取消可重試同一任務並嘗試續傳。成功後清理軌道暫存，失敗時保留。亦保留直接 FFmpeg 原編碼模式作少暫存備選。分段模式合併期間需要暫存與成品空間；不會複製使用者已加入的原影片。App 仍需切換到 a-Shell 並保持其在前景；未內嵌 FFmpeg 或 CPython，不宣稱完全在 App 內執行。

取得畫質不啟動 FFmpeg 媒體下載。多影片貼文列出共同選項或各片最高畫質。清單只存政策、標題與來源識別，不持久化 CDN 影片網址或 Cookie；下載／重試時重新解析取得新網址。不處理 DRM、正在直播的串流或整份播放清單。

使用者提供的 SMG 捷徑僅作流程參考，0.7 的外部捷徑執行入口已移除。舊交接紀錄仍可讀，按重新解析即可改用 App 流程。App 不修改、執行既有的 `v1.3.1.py`，不需要匯入 SMG 捷徑或設定捷徑名稱。終端持續顯示程式啟動、yt-dlp 及 FFmpeg 階段，初始化失敗會寫回 App；手機上先前未見 yt-dlp 啟動的實際原因仍待終端回饋確認。

「加入整個資料夾」固定放在檔案庫最上方。進入目標資料夾，按 iOS 選擇器右上「開啟」即可加入；使用原位置選擇器（`asCopy: false`）。App 只在 Application Support 保存來源名稱與存取書籤；重開後可繼續讀取，不另存完整影片。來源失效時長按重新授權；移除來源只移除紀錄，保留原檔。

資料夾只讀清單與檔案資訊，選定檔案後才協調讀取並播放。播放／預覽期間保留該來源的安全存取權限。iCloud 或其他檔案提供者可能下載其原檔與快取，因此不宣稱完全零空間用量。下載成品和舊匯入副本仍在「App 內檔案」；只有該區的「複製檔案到 App（另存副本）」會主動建立影片副本，且不是預設入口。

CI 驗證來源書籤重載、子資料夾、原檔內容保留、來源移除、授權失效後重連、路徑邊界與失效紀錄保留。iOS Simulator 以真實 URL 書籤播放測試原檔，並終止／重新啟動 App 驗證還原；測試來源是 App 測試資料，真機外部檔案提供者的權限延續仍需裝機驗證。

0.5.0 依使用者提供的 FramePocket／Safari Media Grabber 參考調整播放器：採深色外觀、影片上的低矮控制台、可收起時間軸、前後一幀與可選 5／10／30／60 幀跨幀、0.1–2 倍速度記憶，以及 A–B 設點與循環。跨幀逐次要求引擎移動相鄰畫格；一般 A–B 循環經狀態檢查再 seek 回 A，不宣稱無縫或 B 幀精確停止。

按控制台左上 A–B 開啟片段面板，設定 A、B 時暫停；啟用循環後按播放。移到範圍外會關閉循環，關片清除範圍。控制台中間把手可收起／展開時間軸，右上速度選單可改速度與跨幀步長。參考檔案指紋、已落實項目與後續批次見 [原生移植對照](docs/reference-map.json)。縮圖時間軸、按住連續逐幀、擷取畫格、多來源查重與下載卡片仍列於後續批次。

0.4.0 加入的免費 a-Shell／FFmpeg 下載橋接繼續保留：App 建立本機任務，以 yt-dlp 及平台 extractor 解析 YouTube、Instagram、Threads、Bilibili，再由 a-Shell 的原生 FFmpeg 下載與合併。提供原畫質／1080p／720p、只取音訊、可選 Cookie、持久化狀態、取消旗標及完成後整批匯入。首次須授權 MediaPocketBridge 子資料夾並安裝免費解析元件；見 [手機下載設定步驟與限制](docs/tryout-v0.4.md)。

保留檔案管理、垃圾桶與雙播放引擎、自訂播放控制、真正的前／後一幀、毫秒時間、雙指 1–8 倍縮放、放大拖曳與雙擊重置。逐幀先暫停，再由引擎選擇相鄰畫格，不使用 `1 / 平均 fps` 的時間跳轉冒充逐幀。

系統引擎使用 `AVPlayerItem.step(byCount:)` 並檢查 `canStepForward`／`canStepBackward`。VLC 使用 `gotoNextFrame`／`gotoPreviousFrame`，等待其結果回呼；某來源不支援反向逐幀時會明確顯示訊息。VLC 優先選擇 VideoToolbox 解碼器並允許其他解碼器回退；系統引擎由 AVFoundation 選擇可用的硬體路徑。介面「硬體優先」描述選擇策略，不宣稱每個檔案目前都在硬體解碼。

縮放由 UIScrollView 直接變換 AVPlayerLayer／VLC 顯示層，不反覆產生放大點陣圖；旋轉螢幕時重設為 1 倍。iOS Simulator 整合測試會產生 CFR／VFR H.264 樣本，核對系統逐幀的相鄰時間戳、VLC 前後逐幀回呼，以及 8 倍顯示層縮放、拖曳與旋轉重置。實際雙指操作、硬體解碼、耗電、HDR 與每種來源的幀行為仍需 iPhone 實測。

FFmpeg 在免費完整版 a-Shell 中執行，下載時須保持 a-Shell 在前景。未內嵌 FFmpeg 或背景服務，不承諾 iOS 終止後繼續執行。CI 以真實 FFmpeg 和本地 HTTP 樣本測試影音分軌合併、HLS、音訊下載及錯誤處理；四平台的真機下載、書籤權限與 WebKit 行為仍待 iPhone 實測。個別容器／編碼、字幕、HDR 和音軌行為也需實測。

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
3. a-Shell FFmpeg：HTTPS／HLS 下載、分離影音合併、原編碼封裝。
4. a-Shell 任務交接與 YouTube／Instagram／Threads／Bilibili 解析已接入；等待真機逐站回饋。
5. 根據手機回饋修正來源解析、登入與中斷恢復。
6. 背景工作、中斷恢復、字幕與播放體驗。

請勿提交登入資料、Cookie、私人下載來源或個人媒體檔案。
