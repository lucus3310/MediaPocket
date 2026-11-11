# App 內下載引擎：可鎖定的原生依賴

查核日期：2026-11-08。這份文件記錄已查到的發行資產、實際封裝內容與實作限制；不代表已在 iPhone 或 Simulator 執行成功。

## 建議路線

將 CPython、yt-dlp 與 FFmpeg 動態框架隨 IPA 打包。Swift 呼叫同一個程序內的 Python C API；yt-dlp 負責取得平台資訊與可用媒體來源，Swift 執行下載及排程，FFmpegKit 的引數陣列 API 負責串流處理、合併、轉封裝及轉檔。全程在 App 程序內執行，無須 a-Shell、捷徑、付費伺服器或下載後再啟動的執行檔。

不能把桌面版 `subprocess.run(["ffmpeg", ...])` 直接搬進 iOS；必須把 yt-dlp 需要的探測／後處理改接 App 的 C／Swift 橋接。CPython 官方將 iOS 的執行方式定義為嵌入模式。[Python iOS 文件](https://docs.python.org/3.13/using/ios.html)

## 實作鎖定版本補充

實作採用較新的 BeeWare **3.13-b18**，同樣已實際下載檢查。資產 `Python-3.13-iOS-support.b18.tar.gz` 為 34,524,958 bytes，SHA-256 `d06acf2a9c7964a8689566353a0e707402eff822037de5e29ba0e16040f7047d`，目錄結構與以下 b14 查核相同。實作使用 `scripts/embed-python.py` 依官方 marker 格式封裝標準庫，支援 unsigned device build 與 ad-hoc Simulator 簽署；套件均隨 App 打包，不在手機 pip 安裝。FFmpeg 本機套件由固定 archive SHA-256 驗證，Swift 以 argv API 直接呼叫；平台解析與分段下載在內嵌 Python 執行。

以下 b14 記錄保留為比較查核；實際建置版本以 `scripts/prepare-native.py` 為準。

## 1. CPython：BeeWare Python-Apple-support 3.13-b14

使用已發行、可免費下載的固定資產，避免 GitHub Actions 每次從頭編譯 Python：

| 項目 | 值 |
| --- | --- |
| 發行 tag | `3.13-b14` |
| iOS 資產 | `Python-3.13-iOS-support.b14.tar.gz` |
| 大小 | `32387292` bytes |
| SHA-256 | `8b5cb76ef8d8a2946052479358eeec9d54b4496cb60920e175ec1489b5cf7963` |
| 下載 | [固定 iOS tar.gz](https://github.com/beeware/Python-Apple-support/releases/download/3.13-b14/Python-3.13-iOS-support.b14.tar.gz) |

來源：[發行頁](https://github.com/beeware/Python-Apple-support/releases/tag/3.13-b14)、[GitHub 發行 API，含 digest](https://api.github.com/repos/beeware/Python-Apple-support/releases/tags/3.13-b14)、[固定版本 README](https://github.com/beeware/Python-Apple-support/blob/3.13-b14/README.md)。本次實際下載 tar.gz，以 SHA-256 確認與上述 digest 相同，並直接解析其中的 `Info.plist`，不是只依賴 README。

實際 `Python.xcframework/Info.plist` 有兩個 iOS 切片：

| LibraryIdentifier | SupportedArchitectures | 目標 |
| --- | --- | --- |
| `ios-arm64` | `arm64` | iPhone／iPad 真機 |
| `ios-arm64_x86_64-simulator` | `arm64`, `x86_64` | Apple Silicon／Intel Simulator |

兩者的 `LibraryPath` 都是 `Python.framework`。壓縮檔還包含標準庫、標準庫 C 擴充與 Xcode 後處理工具；不是僅有可連結的 libpython。

### b14 實際目錄與打包

```text
Python.xcframework/
  Info.plist
  lib/python3.13/                         # 共用標準庫，含 encodings/
  ios-arm64/
    Python.framework/
    lib-arm64/python3.13/
      _sysconfigdata__ios_arm64-iphoneos.py
      lib-dynload/_ssl.cpython-313-iphoneos.so
      lib-dynload/_ctypes.cpython-313-iphoneos.so
      ...
  ios-arm64_x86_64-simulator/
    Python.framework/
    lib-arm64/python3.13/...
    lib-x86_64/python3.13/...
  build/
    utils.sh
    iOS-dylib-Info-template.plist
```

不要採用舊版「從 `Python.framework/Resources/lib` 複製標準庫」的路徑。b14 內附的 `build/utils.sh` 會依 `EFFECTIVE_PLATFORM_NAME`、`ARCHS` 選擇切片，再把共用標準庫與對應架構內容安裝到 `$CODESIGNING_FOLDER_PATH/python/lib/`。

Xcode 在 Copy Bundle Resources 之後、Embed Frameworks 之前執行，假設依賴位於 `Vendor/Python.xcframework`：

```bash
set -e
source "$PROJECT_DIR/Vendor/Python.xcframework/build/utils.sh"
install_python Vendor/Python.xcframework app app_packages
```

`app`、`app_packages` 是已複製進 App bundle 的程式及套件資料夾名稱。若專案使用其他名稱，需一併調整。**資產內的實檔名稱是 `utils.sh`**，其範例註解與部分官方文件寫成 `build_utils.sh`，請以固定資產內容為準。

後處理不能省略：iOS 的 `_ssl`、`_ctypes` 等 `.so` 必須移至 App 根目錄的 `Frameworks/*.framework`，原處替換成 `.fwork`，並於 framework 寫入 `.origin` 回指。b14 的 `install_python`／`process_dylibs` 已實作這個流程。[Python 官方二進位擴充說明](https://docs.python.org/3.13/using/ios.html#binary-extension-modules)

例如 `_ssl` 的成品為：

```text
MediaPocket.app/python/lib/python3.13/lib-dynload/_ssl.cpython-313-iphoneos.fwork
MediaPocket.app/Frameworks/_ssl.framework/_ssl
MediaPocket.app/Frameworks/_ssl.framework/_ssl.origin
```

`.fwork` 內容為 `Frameworks/_ssl.framework/_ssl`；`.origin` 內容為 App 相對路徑 `python/lib/python3.13/lib-dynload/_ssl.cpython-313-iphoneos.fwork`。原始 tar 裡沒有這些 marker，因為必須在建置 App 時產生。

**免費未簽名 CI 的注意事項**：上游 `install_dylib` 無條件執行 `codesign --sign "$EXPANDED_CODE_SIGN_IDENTITY"`。在 `CODE_SIGNING_ALLOWED=NO` 的未簽名裝置封裝工作中，這個變數可能為空，不能原封不動假定可用。需在受控的建置包裝流程中處理空 identity，例如打包時對框架使用 ad-hoc identity `-`，之後由使用者選擇的自簽工具重新簽署所有 nested frameworks；Simulator 亦需有效的 ad-hoc 簽署。每個最終 framework 都必須進入重簽範圍。這是建置整合工作，不是要求付費 Developer 會員。

### Python 初始化

固定資產內的 `testbed/TestbedTests/TestbedTests.m` 提供可參考的 Objective-C 初始化程式。實際路徑應由 `NSBundle.mainBundle.resourcePath` 取得：

```text
PyConfig.home                 = <App bundle>/python
標準庫 sys.path               = <App bundle>/python/lib/python3.13
二進位 marker sys.path        = <App bundle>/python/lib/python3.13/lib-dynload
App Python 程式 sys.path      = <App bundle>/app
第三方 Python 套件 sys.path   = <App bundle>/app_packages
```

建議 `PyPreConfig_InitIsolatedConfig`、`utf8_mode=1`，再 `PyConfig_InitIsolatedConfig`、`buffered_stdio=0`、`write_bytecode=0`；用 `PyConfig_SetString` 設定 home，檢查每個 `PyStatus`，呼叫 `Py_InitializeFromConfig` 並清理 config。不可寫入已簽署的 App bundle。若套件依賴 `.pth`，用 `site.addsitedir(app_packages)`，不能只附加 sys.path。這些路徑與初始化順序亦可對照 [Python 嵌入設定 API](https://docs.python.org/3.13/c-api/init_config.html)。

App 建議只初始化一次，專用背景序列佇列持有 Python 工作；不要每次解析連結都初始化／終結 interpreter，也不要讓解析或 FFmpeg 阻塞主執行緒。橋接需明確管理 GIL 與回呼的執行緒。

## 2. FFmpeg：jaywcjlove/ffmpeg-kit 的固定版本

2026-11-11 補正：下列預編譯檔的原始封裝與 ABI 查核沒有驗證 HTTPS。0.10.2 實際交付的 libavformat 關閉了 SecureTransport 與 OpenSSL，缺少平台下載需要的 TLS 後端；本機 HTTP 樣本無法發現此問題。從 0.10.3 起，`scripts/enable-native-https.py` 使用固定來源開啟 SecureTransport，只替換 ABI 相符的 ARM64 libavformat，保留既有 codec／CLI 函式庫。打包檢查實際編譯設定，啟動時以原生 API 枚舉 `https`／`tls`，並要求真正的模擬器 HTTPS 下載測試。重建來源版本、configure SHA-256 與產物雜湊記錄於 `Native-LICENSES/native-build.json`；詳見 [問題診斷與驗證](download-diagnosis-v0.10.3.md)。

固定 revision：`0bd85df8f9693061f6f979414662baaf876a3e20`。

此 fork 的 [Package.swift](https://github.com/jaywcjlove/ffmpeg-kit/blob/0bd85df8f9693061f6f979414662baaf876a3e20/Package.swift) 宣告 iOS 12+、Swift tools 5.9，實際 product/module 名稱為 **`ffmpegkit` 小寫**；Swift target 依賴 `CFFmpegBridge`。八個 binary targets 直接指向 repo 中的 XCFramework：`ffmpegkit`、`libavcodec`、`libavdevice`、`libavfilter`、`libavformat`、`libavutil`、`libswresample`、`libswscale`。

本次查核 [完整 Git tree API](https://api.github.com/repos/jaywcjlove/ffmpeg-kit/git/trees/0bd85df8f9693061f6f979414662baaf876a3e20?recursive=1) 與 [ffmpegkit Info.plist](https://github.com/jaywcjlove/ffmpeg-kit/blob/0bd85df8f9693061f6f979414662baaf876a3e20/Frameworks/ffmpegkit.xcframework/Info.plist)：

- `ffmpegkit` 有真機 `ios-arm64` 和 Simulator `ios-arm64_x86_64-simulator`，另含 macOS 切片。
- 真機 framework binary 是 397,128 bytes、Simulator 是 869,784 bytes。
- `libavcodec` 真機 binary 是 11,580,856 bytes、Simulator 是 27,802,616 bytes。
- 這些是實際二進位 Git blobs，並非只有空資料夾、README 或 Git LFS pointer。

### 可直接使用的 API

以下依固定版本 [FFmpegKit.swift](https://github.com/jaywcjlove/ffmpeg-kit/blob/0bd85df8f9693061f6f979414662baaf876a3e20/Sources/FFmpegKit/FFmpegKit.swift)、[FFprobeKit.swift](https://github.com/jaywcjlove/ffmpeg-kit/blob/0bd85df8f9693061f6f979414662baaf876a3e20/Sources/FFmpegKit/FFprobeKit.swift)：

```swift
import ffmpegkit

// 同步 API，應放在引擎背景佇列。
let session = FFmpegKit.executeWithArguments([
    "-nostdin", "-y", "-i", videoPath, "-i", audioPath,
    "-map", "0:v:0", "-map", "1:a:0", "-c", "copy", outputPath
])

// 也有 executeWithArgumentsAsync，接受完成、log、statistics 回呼。
// 取消可用 FFmpegKit.cancel(sessionId) 或 session.cancel()。
// FFprobeKit.executeWithArguments([String]) 回傳 FFprobeSession。
```

`FFprobeKit` 還提供 `getMediaInformation(path)`，以及 `getMediaInformationFromCommandArgumentsAsync` 的完成／log callback 與 timeout。其媒體探測預設使用 JSON `-show_format -show_streams -show_chapters`。

請使用引數陣列，不要把來源 URL、headers、檔名組成 shell 字串。回呼可將 FFmpeg 的 frame/fps/time/size/bitrate/speed 對應成 App 進度；UI 更新仍需回主 actor。

[Execution.swift](https://github.com/jaywcjlove/ffmpeg-kit/blob/0bd85df8f9693061f6f979414662baaf876a3e20/Sources/FFmpegKit/Execution.swift) 在 NativeExecutionBackend 內用 `NSLock` 序列化執行；[CFFmpegBridge.c](https://github.com/jaywcjlove/ffmpeg-kit/blob/0bd85df8f9693061f6f979414662baaf876a3e20/Sources/CFFmpegBridge/CFFmpegBridge.c) 以 `dlsym` 取得 `ffmpeg_execute`、`ffprobe_execute`，取消呼叫 `cancel_operation`。缺少原生符號時返回 `-127`。所以「Swift import 成功」不足以驗證整合，Debug 與 Release 成品都必須實際跑 `-version`／ffprobe。若 Release dead-strip 導致 framework 沒有載入，需檢查最終 load commands 與 linker 設定，而不是把缺少原生引擎誤報成下載失敗。

### 授權與來源保存

**這份固定版本附帶的實際預編譯 framework 使用 GPL v3**：[binary LICENSE](https://github.com/jaywcjlove/ffmpeg-kit/blob/0bd85df8f9693061f6f979414662baaf876a3e20/Frameworks/ffmpegkit.xcframework/ios-arm64/ffmpegkit.framework/LICENSE)、[binary SOURCE](https://github.com/jaywcjlove/ffmpeg-kit/blob/0bd85df8f9693061f6f979414662baaf876a3e20/Frameworks/ffmpegkit.xcframework/ios-arm64/ffmpegkit.framework/SOURCE)。不能只依專案概括介紹而標記成 LGPL。公開原始碼與使用免費工具符合使用者方向，但發布時仍需保留完整授權、各第三方 notice，以及對應原始碼／建置資訊；SOURCE 的歷史 wiki 連結不能取代實際核對相應源碼。

原維護者的 [FFmpegKitNext source repo](https://github.com/arthenica/ffmpeg-kit-next) 可作為後續自行建置的路線，不應誤認為已提供與上述 fork 相同的現成 iOS binary。短期先固定目前已查到的 binary fork，以 CI 實際執行驗證；未來若要縮小體積或調整授權／codec 組合，再改成自建 XCFramework。

## 3. 必須留在實作與驗證範圍的事項

1. 在 CI 鎖定 Python SHA、FFmpeg Git revision、yt-dlp 版本及其純 Python 相依套件；不得於 App 首次啟動時要求 pip 安裝原生套件。
2. 解析器不等於下載器：YouTube signature／JavaScript challenge 仍需要相容的 JS runtime 或 App 內等效橋接。不能宣稱打包 yt-dlp 就保證所有 YouTube 連結可解析；若採額外 JS 引擎，必須納入相同的固定版本及離線封裝流程。
3. 四平台的登入、來源提供的格式／解析度／幀率、地區與帳號限制仍會影響結果。畫質選單由實際回傳 formats 建立；不要用升頻冒充 4K／8K。
4. 優先 `-c copy` 保留來源品質並節省時間／耗電，容器不相容時明確提示轉檔。硬體轉碼能力須以成品的 `-encoders` 與實際短片驗證，不能由 FFmpeg 套件名稱推定。
5. Simulator 做嵌入 Python import 自測（`ssl`、`ctypes`、`socket`、`hashlib`、yt-dlp）、FFmpeg `-version`、雙流合併與取消測試；Release 裝置 IPA 驗證框架切片、marker、簽署及未攜入桌面執行檔。最後另由真機驗證來源解析／4K 播放、切到背景與自簽安裝。Windows 靜態檢查不可記成 iPhone 成功。

這條路線的依賴可免費取得，也具有 macOS GitHub Actions 能使用的 Simulator／device 切片；目前確認的是資產與 API 可用性，完整 App 的可執行性仍以專案的 CI 與真機結果為準。
