# MediaPocket 0.10.0：App 內建下載引擎

本版將 FFmpeg、ffprobe、CPython、yt-dlp、YouTube WebKit JS provider 及 Threads extractor 隨 IPA 打包，直接在 App 程序執行。無須安裝 a-Shell、設定捷徑或授權交接資料夾；不使用付費後端。

## 手機操作

1. 以相同 Bundle ID 自簽並覆蓋安裝新版，保留 App 資料。
2. 進「下載」，等待內建引擎檢查完成。
3. 貼上 YouTube、Instagram、Threads、Bilibili 等支援平台的單一影片／貼文 HTTPS 連結；可按「收起鍵盤」。
4. 按「取得可用畫質」，選來源解析度、fps、編碼及輸出格式，再按「開始下載與合併」。
5. 完成後開「播放／管理下載成品」，或至「檔案庫 → App 內檔案 → Downloads」。

原位置影片、整個來源資料夾、書籤重載、逐幀播放器、雙指 8 倍縮放及硬體優先解碼保留。既有外部工具任務仍可查看；未完成的舊任務需重新解析。

## 執行與容量

Swift → CPython C API → yt-dlp 取得實際來源 → App 內 FFmpeg 下載／合併／轉檔 → ffprobe 驗證軌道 → 原子移入檔案庫。分段模式用 yt-dlp 原生 HTTP/HLS/DASH 下載以支援並行與續傳，FFmpeg 負責合併／轉檔；關閉分段模式則由內建 FFmpeg 直接讀取媒體來源。所有程式都在同一個 App 程序。

畫質清單依來源提供的格式產生，不設定 4K／8K 上限、不放大補畫質。權限、地區及來源仍會限制可取得的格式。轉檔不能增加來源品質。VideoToolbox 編碼器優先，有可用軟體編碼器時才回退；HDR 預設保留原編碼。

請保持 App 在前景；iOS 可能暫停背景工作。切勿宣稱無限背景下載。失敗或中斷保留軌道暫存，可重試；成功後清理暫存。合併期間需同時容納來源軌道與成品。新下載的影片會佔容量；既有來源資料夾的原位置播放不產生影片副本。

需要登入的來源可自行放置 Netscape Cookie 檔於 App 的 MediaPocketBridge/cookies；Cookie 留在手機。App 不繞過 DRM。

## 免費編譯與授權

`bash scripts/build-ios.sh` 先核對 SHA-256，下載固定的原生框架及純 Python 套件，再以 XcodeGen 建置。GitHub Actions 僅允許公開專案，使用標準 macOS runner 產生未簽名 IPA，無 Apple 付費帳號或付費 runner。裝機仍需使用者的免費自簽工具重簽 App 與所有內嵌 frameworks。

MediaPocket 本版採 GPLv3，固定 FFmpeg 二進位本身亦採 GPLv3，非 LGPL-only。完整授權隨 App 附帶；依賴版本、校驗碼與來源重建位置見 `scripts/prepare-native.py`、`docs/native-engine-dependencies.md`，修改的橋接程式亦公開。CPython 採 PSF，VLCKit 保留其適用授權。

CI 將分開驗證桌面測試、iOS 模擬器內建 Python／WebKit JS／FFmpeg／ffprobe／下載合併轉檔，以及中文鍵盤收合。這些證據不等於實體 iPhone、平台即時回應或 4K 真機速度已驗證。
