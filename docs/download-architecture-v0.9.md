# iOS 下載架構研究與 0.9 選擇

研究日期：2026-11-08。以下外部事實引用第一手文件；架構取捨是依本專案「免費、無 Mac、自簽、已有原生播放器」條件所做的評估，不代表其他方案無法實作。

## 選擇

**FFmpeg 不限於 a-Shell。** 本版採原生 SwiftUI 管理連結、畫質及檔案，由手機上的 a-Shell 執行 Python／yt-dlp 與 FFmpeg，不使用原 SMG 捷徑或遠端服務。a-Shell 提供 Python、套件及跨 App 資料夾授權；這讓現有解析器可繼續使用，但仍須切換前景，並非完全在 MediaPocket 程序內執行。[a-Shell 原始專案](https://github.com/holzschu/a-shell)

| 方案 | 適用性與取捨 |
| --- | --- |
| 本次：App UI＋a-Shell 執行 | 沿用現有 Python／JavaScript 解析環境，無伺服器費用；增加分段下載、續傳及本機 FFmpeg 處理。代價是首次資料夾授權、前景切換與外部 App 版本相依。 |
| 直接內嵌 FFmpeg | 能減少合併／轉碼階段的切換，並可自訂工作控制；但單獨 FFmpeg 不提供完整的平台網頁解析。需另外驗證解析器、建置、取消及反覆執行。可用的原生封裝包括 [FFmpegKitNext](https://github.com/arthenica/ffmpeg-kit-next)。 |
| 內嵌 CPython＋yt-dlp＋FFmpeg | 有機會完成單一 App 體驗，但需打包直譯器、標準函式庫及相依元件；Python 官方明確以嵌入模式支援 iOS。另須驗證 JavaScript 執行環境與現有插件，不能將桌面可執行檔直接移植。[Python iOS 文件](https://docs.python.org/3/using/ios.html) |
| 遠端解析／下載／轉檔 | 本專案評估：可降低手機運算量，但新增主機、流量、Cookie 傳送及維運負擔；無法據此保證長期零費用，故本次不採用。 |

## 引擎與畫質策略

`runner.py` 負責交接及任務狀態，`download_engine.py` 集中格式選擇、傳輸與 FFmpeg 輸出政策。schema 2 保存解析度、fps、編碼、容器、HDR 等選擇條件；開始下載時重新解析取得有效網址，指定條件失效就報錯，不悄悄降級。多影片貼文提供共同選項或各片最佳來源。

加速模式使用 yt-dlp 原生 HTTP／HLS／DASH 下載器，再交給 FFmpeg 合併／轉碼。1／2／4／8 的並行數針對 HLS／DASH 分段；**一般 HTTP 檔案不強制分塊，也不保證每個平台加倍提速**。保留未完成軌道與分段紀錄以供重試，來源失效時重新解析。[yt-dlp 下載選項](https://github.com/yt-dlp/yt-dlp#download-options)、[HTTP 下載器實作](https://github.com/yt-dlp/yt-dlp/blob/master/yt_dlp/downloader/http.py)

預設自動選無損 MP4／MKV；原編碼為 MKV／MKA，另提供 MP4 必要時轉碼、H.264／HEVC、相容串流的 WebM，以及 M4A／MP3／FLAC／WAV。`-c copy` 不重新編碼，適合優先保留品質與降低處理成本。轉碼不會增加原始細節，FLAC 也不能修復原本有損音訊；4K／8K 以上只有來源確實提供才可選，不以放大或補幀冒充。[FFmpeg streamcopy／transcoding](https://ffmpeg.org/ffmpeg.html#Streamcopy)

H.264／HEVC 轉碼優先選可用的 VideoToolbox 編碼器，但實際能力受 FFmpeg build、系統與裝置限制，不能將「硬體優先」當作每次都使用硬體的證明。缺少編碼器會在傳輸前報錯；HDR 預設保留原編碼，避免未實作色調映射的轉碼破壞色彩。[FFmpeg VideoToolbox 編碼器](https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/videotoolboxenc.c)

## 內嵌元件的現況

舊 FFmpegKit 已退役，但官方於 2026-07 指向原作者延續的 **`arthenica/ffmpeg-kit-next`**，不是 `arthenica/FFmpegKitNext`。官方目前提供來源建置路線，不能繼續假設歷史預編譯套件永久可取。[官方現況](https://arthenica.github.io/ffmpeg-kit/)

`kingslay/FFmpegKit` 支援 SPM，但 README 指公開版本採 GPL、LGPL 版本另洽付費，因此不能把它當成免費 LGPL 依賴。[該專案授權說明](https://github.com/kingslay/FFmpegKit#license)

`jaywcjlove/ffmpeg-kit` 提供 Swift／C bridge、XCFramework 與重建腳本，預設 core build 為 LGPL，啟用 x264／GPL 元件會改變發行條件。它是可評估的嵌入選項；其 README 也指出完整 iOS 建置可能需一至數小時。本次不增加尚未驗證的二進位依賴或以該時間數字當作本專案實測。[建置與 API](https://github.com/jaywcjlove/ffmpeg-kit)

## 驗證與保留功能

維持檔案原位置讀取、資料夾書籤、逐幀播放器與 8 倍縮放。成品需通過軌道驗證才移入檔案庫；成功清理軌道暫存，失敗保留供續傳。分段模式合併時會暫時同時佔用軌道與成品空間，不等同複製既有來源影片。

公開 repo 使用標準 `xcode-27` runner，依 GitHub 現行規則此類公開專案標準 runner 免費；不啟用付費 larger runner。CI 涵蓋本地 HTTP／HLS、續傳、轉碼及高解析度樣本，再編譯 iOS 與測試播放器。這些證據不等於 YouTube 登入、各站 4K、真機背景執行或硬體編碼已通過。[GitHub 標準 runner 規則](https://docs.github.com/en/actions/reference/runners/github-hosted-runners#standard-github-hosted-runners-for-public-repositories)
