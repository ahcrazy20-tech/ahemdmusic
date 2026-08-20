# مراجعة كود مشروع AS Music (TrollMusicApp)

**تاريخ المراجعة:** 2026-08-20
**الفرع:** `arena/01a020ef-ahemdmusic`
**نطاق المراجعة:** كل الكود المصدري الفعلي (~4,700 سطر Swift) + الـ CI workflow

---

## ✅ حالة التنفيذ

كل الإصلاحات اتطبّقت **داخل `build.yml`** (البنية اتساب زي ما هي بناءً على طلب صاحب المشروع
— الكود يفضل في ملف واحد).

| البند | الحالة |
|---|---|
| 1.1 استخراج الكود من `build.yml` | ⏸️ **مؤجَّل بقرار** — البنية اتسابت زي ما هي |
| 1.2 ثبات مُعرِّفات الأغاني (ضياع القوائم) | ✅ تم |
| 1.3 تعديل `@Published` من threads خلفية | ✅ تم |
| 1.4 تكرار مراقبي الإشعارات | ✅ تم |
| 1.5 غلاف الأغنية في شاشة القفل | ✅ تم |
| 2.1 Smart Radio كود ميت | ✅ تم |
| 2.2 نسب التنزيلات للمهمة الصح | ✅ تم |
| 2.3 `MusicManager` مُهيّئ خاص | ✅ تم |
| 2.4 تقييد ATS | ✅ تم |
| 2.5 تردد الـ CADisplayLink | ✅ تم |
| 2.6 حساب المستوى بـ vDSP | ✅ تم |
| 2.7 تنظيف أسماء الملفات | ✅ تم |
| 3.1 Liked Songs بالاسم مش بالفهرس | ✅ تم |
| 3.2 تحقق ميت في `loadPrefs` | ✅ تم |
| 3.3 `activeCount` no-op | ✅ تم |
| 3.4 `removeItem` الزائد | ✅ تم |
| 3.6 `FileHandle.seek` يرمي أخطاء | ✅ تم |
| 3.7 ذاكرة الـ ChunkedDownloader | ⏸️ مؤجَّل (يحتاج إعادة كتابة تدفقية) |
| 3.8 Backends قابلة للتحديث عن بُعد | ⏸️ مؤجَّل (يحتاج endpoint من صاحب المشروع) |
| 3.9 APIs مهجورة في الواجهة | ⏸️ مؤجَّل (شغالة على هدف iOS 16) |
| 4.1 بناء على PR والفروع | ✅ تم |
| 4.3 `.gitignore` | ✅ تم |
| 4.4 `README.md` | ✅ تم |

إصلاحات إضافية اتعملت أثناء الشغل ومكانتش في المراجعة الأصلية:

- **تسريب ذاكرة المحرك:** `setupEngine()` دلوقتي بتفكّ الـ tap وتوقف المحرك القديم قبل ما تبني واحد جديد.
- **مراجع ميتة في القوائم:** `deleteSong` بقت تشيل الـ ID من كل القوائم ومن الميتاداتا ومن كاش الأغلفة.
- **قراءة الأغلفة على الـ main thread:** `artworkImage` بقت تفك ترميز الصور على thread خلفي (تمرير أنعم في المكتبة).
- **تعديل حالة أثناء بناء الواجهة:** `MainTabView.onReceive(dc.$tasks)` كانت بتكتب في `dc.showBanner` جوّه دورة التحديث، وكمان بتقرأ `dc.tasks` القديمة (`@Published` بيرسل *قبل* التعيين).
- **موضع التشغيل عند الإغلاق:** `saveResumePosition()` بقت تحدّث `lastSongId/lastSongTime` في الذاكرة كمان مش بس في `UserDefaults`.
- **`concurrency` في الـ workflow:** إلغاء البناءات القديمة تلقائياً عند push جديد.

---

## 0. ملخص تنفيذي

المشروع تطبيق iOS (SwiftUI + AVAudioEngine) لتشغيل وتنزيل الموسيقى، يتبنى كـ IPA غير موقّع عبر GitHub Actions.
الكود فيه شغل هندسي محترم فعلاً — خصوصاً `ChunkedDownloader` (تنزيل متوازي بـ Range requests) و«سباق» الـ backends، وطبقة الصوت بـ EQ 10 باند + preamp + reverb + timePitch.

لكن فيه **مشكلة معمارية واحدة كبيرة** تسبق كل حاجة تانية، وبعدها مجموعة باجات حقيقية في إدارة الحالة والـ threading.

| الأولوية | العدد | أهم بند |
|---|---|---|
| 🔴 حرجة | 5 | الكود الحقيقي مدفون داخل `build.yml` + ضياع الـ Playlists عند إعادة التشغيل |
| 🟠 عالية | 7 | تعديل `@Published` من threads خلفية، مراقبون مكرّرون، صورة الغلاف في شاشة القفل |
| 🟡 متوسطة | 9 | استهلاك بطارية، منطق ميت، أسماء ملفات |
| 🔵 تحسينات | 6 | CI، توثيق، اختبارات |

---

## 1. 🔴 مشاكل حرجة

### 1.1 الكود المصدري الحقيقي عايش جوّه ملف الـ CI

> **قرار:** اتساب زي ما هو بطلب صاحب المشروع — الكود يفضل في ملف واحد داخل
> `build.yml`. القسم ده متسجّل للتوثيق ولو حبيت تغيّر رأيك لاحقاً.

ده أخطر بند في المشروع كله.

`.github/workflows/build.yml` (4,875 سطر) بيعمل الآتي قبل البناء:

```yaml
- name: Clean Environment
  run: |
    find . -name "Info.plist" -delete
    find . -name "*.swift" -delete          # ← بيمسح كل كود الريبو
    rm -rf TrollMusicApp/*.xcodeproj
```

وبعدها بيعيد كتابة الملفات من heredocs جوّه الـ YAML نفسه.

**النتيجة العملية:**

| الملف في الريبو | الأسطر | الملف الحقيقي في build.yml | الأسطر |
|---|---|---|---|
| `MusicManager.swift` | 148 | `MusicManager.swift` | 926 |
| `Views.swift` | 332 | `Views.swift` | 1,366 |
| — | — | `SmartDownloader.swift` | 2,108 |
| — | — | `WebBrowser.swift` | 264 |

ملفات الريبو مش بس قديمة — دي **نسخة معمارية مختلفة تماماً** (بتستخدم `AVAudioPlayer` البسيط بدل `AVAudioEngine`). يعني حالياً:

- ✗ ما تقدرش تفتح المشروع في Xcode وتشتغل — هتشتغل على كود ميت.
- ✗ ما فيش syntax highlighting ولا autocomplete ولا compiler errors وأنت بتعدّل (كله نص جوّه YAML).
- ✗ `git diff` مالوش معنى — أي تغيير بيبان كتغيير في ملف CI.
- ✗ أي تعديل على ملفات `.swift` الحقيقية **بيتمسح صامتاً** في البناء.
- ✗ خطر heredoc: أي سطر جوّه الكود مكتوب فيه `SWIFT` لوحده بيقطع الملف نُصّين.

**الإصلاح المقترح** (أهم خطوة يمكن عملها في المشروع):

1. استخرج الملفات الخمسة من `build.yml` إلى `TrollMusicApp/TrollMusicApp/`.
2. احذف خطوتَي `Clean Environment` و`Write Swift Files` بالكامل.
3. سيب `project.yml` كملف حقيقي في الريبو بدل ما يتولّد.
4. الـ workflow يبقى: checkout → xcodegen → xcodebuild → package.

الـ workflow هيقلّ من ~4,875 سطر لـ ~60 سطر، والمشروع يبقى قابل للفتح في Xcode.

> ملاحظة: أنا استخرجت الملفات فعلاً أثناء المراجعة للتأكد إنها تتفصل نضيف — العملية آمنة وبتشتغل. قوللي لو عايزني أنفّذها.

---

### 1.2 الـ Playlists و«Liked Songs» بتضيع بعد كل إعادة تشغيل

`MusicManager.loadSongs()`:

```swift
let (t,a) = TitleCleaner.clean(rawName)
return Song(id: UUID(), title: t, url: url, artist: a, ...)   // ← UUID جديد كل مرة
```

والـ Playlists بتتخزن كـ **مصفوفة UUIDs**:

```swift
struct Playlist: Codable { var id: UUID; var name: String; var songIDs: [UUID] }
```

أي أغنية مش موجودة في `.asmusic_meta.json` بتاخد `UUID` جديد كل تشغيل. و`saveSongMeta()` بتتنادى **بس** من `registerDownloadedSong` و`renameSong` — مش من `loadSongs`.

**النتيجة:** أي أغنية اتحطت يدوياً (AirDrop / Files / iTunes) بتخرج من كل الـ playlists ومن Liked Songs بعد أول restart، والـ `songIDs` بتبقى مؤشرات ميتة بتتراكم للأبد.

كمان `resumeLastSongIfAvailable()` بتعتمد على نفس الـ ID فبتفشل لنفس السبب.

**الإصلاح** — استخدم مفتاح مستقر (اسم الملف) بدل UUID عشوائي، أو ثبّت الـ UUID فور اكتشافه:

```swift
// خيار أ (الأبسط): ID مشتق من اسم الملف
let stableID = UUID(uuidString: stableUUIDString(from: url.lastPathComponent))
             ?? UUID()

// خيار ب: احفظ الميتاداتا فور اكتشاف ملف جديد
DispatchQueue.main.async {
    self.songs = mapped
    if mapped.contains(where: { meta[$0.url.lastPathComponent] == nil }) {
        self.saveSongMeta()          // ← ثبّت الـ IDs الجديدة على القرص
    }
}
```

وكمان: خزّن الـ playlists في ملف JSON جنب الميتاداتا بدل `UserDefaults` (أنضف وأسهل في الـ backup).

---

### 1.3 تعديل `@Published` من threads خلفية

في كذا مكان بيتم تعديل خصائص `@Published` من غير الـ main thread — ده سبب معروف لكراشات SwiftUI (`Publishing changes from background threads is not allowed`) وسلوك UI عشوائي:

| المكان | السطر | المشكلة |
|---|---|---|
| `playCurrent(resumeFrom:)` | ~370 | `isPlaying = true` بيتنفذ على `playerQueue` |
| `handleInterruption(_:)` | ~237 | `isPlaying = false/true` على thread الإشعار |
| `handleRouteChange(_:)` | ~247 | `isPlaying = false` نفس المشكلة |
| `handleMediaReset(_:)` | ~253 | قراءة/كتابة `isPlaying` على `playerQueue` |
| `playNext(autoAdvance:)` | متعدد | `isPlaying`, `currentSong`, `upNextQueue` من سياق غير مضمون |
| `endSeek(to:)` | ~415 | `self.isPlaying = false` داخل `playerQueue.async` |

**الإصلاح:** أضف helper واحد واستخدمه في كل مكان:

```swift
@inline(__always)
private func onMain(_ work: @escaping () -> Void) {
    if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
}
```

الأنضف على المدى الطويل: علّم `MusicManager` بـ `@MainActor` وخلي عمليات الـ engine بس هي اللي تروح لـ `playerQueue`.

---

### 1.4 مراقبو الإشعارات بيتضاعفوا مع كل إعادة تهيئة للمحرك

`setupEngine()` بتسجّل ٣ مراقبين:

```swift
func setupEngine() {
    engine = AVAudioEngine()
    ...
    NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption(_:)), ...)
    NotificationCenter.default.addObserver(self, selector: #selector(handleRouteChange(_:)), ...)
    NotificationCenter.default.addObserver(self, selector: #selector(handleMediaReset(_:)), ...)
}
```

و`handleMediaReset(_:)` بتنادي `setupEngine()` تاني — **من غير ما تشيل المراقبين القدام**.

**النتيجة:** بعد أول `mediaServicesWereReset`، كل انقطاع (مكالمة/إشعار) بيشغّل الـ handler مرتين. وبعد التاني، ٤ مرات… وهكذا (تضاعف أسّي). ده بيدّي سلوك «التطبيق بيرجع يشتغل لوحده» أو «بيقف مرتين». كمان الـ engine القديم بكل الـ nodes والـ tap بيتسرّب.

**الإصلاح:**

```swift
func setupEngine() {
    // فكّ الارتباط بالمحرك القديم أولاً
    if let old = engine {
        old.mainMixerNode.removeTap(onBus: 0)
        old.stop()
    }
    NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
    NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
    NotificationCenter.default.removeObserver(self, name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    ...
}
```

أو الأفضل: افصل تسجيل المراقبين في `registerObservers()` تتنادى مرة واحدة من `init` بس.

---

### 1.5 صورة الغلاف ما بتظهرش في شاشة القفل (race مضمون)

`updateNowPlayingInfo()`:

```swift
artworkImage(for: c, size: 600) { img in
    if let img = img {
        info[MPMediaItemPropertyArtwork] = art
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info   // (أ)
    }
}
MPNowPlayingInfoCenter.default().nowPlayingInfo = info            // (ب)
```

و`artworkImage` بتنادي الـ completion **بشكل متزامن** لما الصورة تكون مخزّنة محلياً:

```swift
if let img = UIImage(contentsOfFile: sidecar.path) { completion(img); return }  // متزامن!
```

يعني في الحالة الشائعة (الصورة موجودة على القرص) الترتيب بيبقى (أ) ثم (ب) — والسطر (ب) بيكتب فوق النسخة اللي فيها الغلاف بنسخة من غير غلاف. **الغلاف عمره ما هيظهر للأغاني المحمّلة.**

كمان: `info` متغير قيمة (`var`) متقاطة نسخة منه في الـ closure — التعديل جوّه الـ closure مالوش أي أثر على النسخة برّه.

**الإصلاح:**

```swift
func updateNowPlayingInfo() {
    guard let c = currentSong else {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return
    }
    let base: [String: Any] = [ ... ]
    MPNowPlayingInfoCenter.default().nowPlayingInfo = base       // انشر الأساس فوراً
    let songID = c.id
    artworkImage(for: c, size: 600) { [weak self] img in
        guard let img, self?.currentSong?.id == songID else { return }   // تجاهل النتائج القديمة
        DispatchQueue.main.async {
            var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? base
            updated[MPMediaItemPropertyArtwork] =
                MPMediaItemArtwork(boundsSize: img.size) { _ in img }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
        }
    }
}
```

وخلي `artworkImage` **دايماً** ترجع على الـ main thread (اتساق الـ contract).

---

## 2. 🟠 مشاكل عالية الأولوية

### 2.1 وضع «Smart Radio» ما بيبحثش فعلاً — كود ميت

في `playNext(autoAdvance:)`:

```swift
if isShuffle || smartRadioMode {
    ...
    if let s = candidates.randomElement() ?? songs.randomElement() { playSong(s); return }  // ← return
}
...
if smartRadioMode && !didAutoSearchForRadio {          // ← لا يُنفَّذ أبداً وقت تشغيل الراديو
    didAutoSearchForRadio = true
    NotificationCenter.default.post(name: .smartRadioAutoSearch, ...)
}
```

لما `smartRadioMode == true` الدالة بترجع قبل ما توصل لبلوك البحث التلقائي. يعني الميزة الأساسية بتاعة Smart Radio (إنه ينزّل أغاني جديدة لنفس الفنان) **مش شغالة إطلاقاً**.

وحتى لو وصل التنفيذ للبلوك، بيقرأ `currentSong?.artist` بعد `playSong` مباشرة — و`playSong` بتحدّث `currentSong` عبر `DispatchQueue.main.async`، فالقيمة المقروءة بتاعة الأغنية **القديمة**.

**الإصلاح:** اطلع الفنان/العنوان في متغيرات قبل أي `playSong`، وحط البحث في `defer` أو في دالة مستقلة تتنادى من كل المسارات.

---

### 2.2 `DownloadCenter` بيعتمد على `activeTask` في callbacks الـ URLSession

```swift
func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                didFinishDownloadingTo location: URL) {
    guard let task = activeTask else { return }   // ← أي مهمة نشطة، مش المهمة صاحبة الملف
```

نفس الشيء في `didWriteData` و`didCompleteWithError`. مع نظام «السباق» اللي بيشغّل عدة backends بالتوازي، ملف نزل من مهمة A ممكن يتنسب لمهمة B لو `activeTask` اتغيّر (إلغاء / انتقال للتالي) والـ callback وصل متأخر. النتيجة: **ملف باسم أغنية تانية**.

**الإصلاح:** خريطة `[Int: DownloadTask]` بـ `URLSessionTask.taskIdentifier`:

```swift
private var taskMap: [Int: DownloadTask] = [:]
private let mapLock = NSLock()
// عند الإنشاء:
mapLock.lock(); taskMap[urlTask.taskIdentifier] = task; mapLock.unlock()
// في الـ delegate:
guard let task = lookup(downloadTask.taskIdentifier) else { return }
```

---

### 2.3 `MusicManager` singleton بمُهيّئ عام

```swift
class MusicManager: NSObject, ObservableObject {
    static let shared = MusicManager()
    override init() { ... }        // ← مش private
```

أي `MusicManager()` بالغلط بينشئ **`AVAudioEngine` تاني** + `CADisplayLink` تاني + مراقبين إضافيين → صوت مزدوج واستهلاك مضاعف. لاحظ إن `DownloadCenter` عامل الصح: `override private init()`.

**الإصلاح:** `override private init()`.

---

### 2.4 `NSAllowsArbitraryLoads: true` على مستوى التطبيق

في `Info.plist`:

```xml
<key>NSAppTransportSecurity</key>
<dict><key>NSAllowsArbitraryLoads</key><true/></dict>
```

ده بيلغي ATS بالكامل — يشمل الـ `WKWebView` اللي بيفتح أي موقع. أي صفحة HTTP عادي تقدر تتحقن. وبما إن التطبيق شخصي/sideload فمافيش مراجعة App Store هتوقفه، بس الخطر الأمني حقيقي.

**الإصلاح:** لو الـ backends بتدعم HTTPS (وكلها بتدعم: `y2jar.cc`، `cnvmp3.com`، `workers.dev`، `thetacloud.org`)، شيل المفتاح ده خالص. لو محتاج استثناء، خصّصه بـ `NSExceptionDomains`.

---

### 2.5 `CADisplayLink` بيشتغل ٦٠–١٢٠ مرة/ثانية دايماً

```swift
private func startLevelMeter() {
    let dl = CADisplayLink(target: DisplayLinkProxy { [weak self] in self?.tick() }, ...)
    dl.add(to: .main, forMode: .common)
}
```

- بيشتغل حتى والتشغيل متوقف أو التطبيق في الخلفية (بيتوقف في الخلفية، بس بيفضل شغال والمشغّل واقف).
- كل tick بيعمل `DispatchQueue.main.async` لتحديث `currentTime` و`duration` → ١٢٠ دورة SwiftUI في الثانية لعرض «2:34».
- عمره ما بيتـ `invalidate` (`deinit` بيشيل مراقبي الإشعارات بس).
- `DisplayLinkProxy.tick()` بينادي `MusicManager.shared.checkEndOfTrack()` بشكل مباشر — اقتران صلب بالـ singleton جوّه كلاس مساعد.

**الإصلاح:**

```swift
dl.preferredFramesPerSecond = 10        // كفاية جداً لعدّاد وقت + مؤشر مستوى
// وفي pausePlayback / playSong:
displayLink?.isPaused = !isPlaying
```

ولو مش محتاج visualizer سلس، `Timer` كل 0.25 ثانية أوفر بكتير.

---

### 2.6 حساب مستوى الصوت في حلقة Swift داخل الـ audio tap

```swift
for i in 0..<frames {
    let l = data[0][i]
    sumSqL += l*l
    if chCount >= 2 { sumSqR += data[1][i]*data[1][i] }
}
```

دي بتتنفذ على thread الـ render الصوتي (real-time، ممنوع فيه أي شغل غير محدد الزمن)، وفيها فرع شرطي جوّه الحلقة. الأسوأ: `DispatchQueue.main.async` جوّه callback الـ tap (~٤٣ مرة/ثانية) — تخصيص ذاكرة على thread حساس للزمن، وده سبب معروف لـ audio glitches.

**الإصلاح:** استخدم `vDSP` واكتب في متغير ذرّي، وخلي الـ UI يقراه من الـ display link:

```swift
import Accelerate
var rms: Float = 0
vDSP_measqv(data[0], 1, &rms, vDSP_Length(frames))
rms = sqrt(rms)
atomicLevelL.store(rms)          // من غير أي dispatch من الـ audio thread
```

---

### 2.7 أسماء الملفات: نقطة بادئة = أغنية مختفية

```swift
private func sanitize(_ s: String) -> String {
    var out = s.replacingOccurrences(of: "/", with: "-")
    let invalid = CharacterSet(charactersIn: "\\:*?\"<>|")
    out = out.components(separatedBy: invalid).joined(separator: "-")
    out = out.trimmingCharacters(in: .whitespacesAndNewlines)
    if out.isEmpty { out = "Track" }
    return out
}
```

مشكلتان:

1. عنوان زي `".45 - Track"` أو `"...Baby One More Time"` بينتج ملف مخفي — و`loadSongs()` بتفلتره:
   `!$0.lastPathComponent.hasPrefix(".")` → **الأغنية تنزل بنجاح وما تظهرش في المكتبة أبداً**.
2. مافيش حد أقصى للطول. حد HFS+/APFS هو 255 بايت، والعناوين العربية UTF-8 بتاخد 2 بايت للحرف → عنوان 130 حرف بيفشل الحفظ.

**الإصلاح:**

```swift
private func sanitize(_ s: String) -> String {
    var out = s.replacingOccurrences(of: "/", with: "-")
    out = out.components(separatedBy: CharacterSet(charactersIn: "\\:*?\"<>|")).joined(separator: "-")
    out = out.trimmingCharacters(in: .whitespacesAndNewlines)
    while out.hasPrefix(".") { out.removeFirst() }          // (1)
    // (2) اقصص مع الحفاظ على الامتداد وحدود UTF-8
    let ext = (out as NSString).pathExtension
    var stem = (out as NSString).deletingPathExtension
    while stem.utf8.count > 200 { stem.removeLast() }
    out = ext.isEmpty ? stem : "\(stem).\(ext)"
    return out.isEmpty ? "Track" : out
}
```

---

## 3. 🟡 مشاكل متوسطة

**3.1 — `toggleFavorite` ممكن تضيّع الـ Liked Songs**
```swift
if playlists.isEmpty || playlists[0].name != "Liked Songs" {
    playlists.insert(Playlist(id: UUID(), name: "Liked Songs", songIDs: []), at: 0)
}
```
لو المستخدم أنشأ playlist وترتيبها خلاها في المقدمة، الكود بيدرج «Liked Songs» جديدة فاضية والقديمة تتدفن. اعتمد على البحث بالاسم أو بـ ID ثابت مخزّن، مش على `[0]`.

**3.2 — تحقق ميت في `loadPrefs`**
```swift
if let r = UserDefaults.standard.integer(forKey: "asmusic_repeat") as Int?, ...
```
`integer(forKey:)` بترجع `Int` غير اختياري — الـ `as Int?` والـ `if let` مالهمش أي معنى (دايماً ينجحوا، و0 لما المفتاح مش موجود). استخدم `object(forKey:) as? Int`.

**3.3 — `activeCount -= 1; activeCount += 1` في `ChunkedDownloader`**
سطر متكرر ٤ مرات في مسارات إعادة المحاولة، ومحصلته صفر. لو المقصود «سيب العداد زي ما هو أثناء إعادة المحاولة» فاكتب تعليق واحذف السطرين — دلوقتي بيوحي إن فيه منطق مفقود.

**3.4 — `try? fm.removeItem(at: destPath)` بعد حلقة التفريد**
الحلقة بتضمن إن `destPath` مش موجود، فالـ remove no-op. لكنه خطر لو الحلقة اتعدّلت مستقبلاً (ممكن يمسح ملف موجود). احذفه.

**3.5 — `checkEndOfTrack` مربوط بالـ display link**
شبكة أمان معقولة، لكنه بيقرأ ٥ خصائص `@Published` كل frame. لو نفّذت 2.5 (تقليل التردد) هتتحل تلقائياً.

**3.6 — `FileHandle.seek(toFileOffset:)` قديم**
API قديم لا يرمي أخطاء ومخلوط مع `write(contentsOf:)` الحديث. استخدم `try fileHandle.seek(toOffset:)` وعالج الخطأ — فشل الـ seek دلوقتي بيكتب في المكان الغلط بصمت (= ملف تالف).

**3.7 — استهلاك الذاكرة في `ChunkedDownloader`**
6 اتصالات × 2 ميجا = ~12 ميجا في الذاكرة في الذروة، وكل chunk بيتجمّع كامل قبل الكتابة. مقبول على أجهزة حديثة، بس مع ملف طويل ونظام تحت ضغط ممكن يتقتل التطبيق. استخدام `URLSessionDataDelegate` مع كتابة تدفقية بيلغي المشكلة.

**3.8 — Backends مبرمجة صلبة في الكود**
```swift
private let workerURLs = ["https://fancy-sea-5d3d.holy-breeze-fec5.workers.dev/?m=i"]
private let y2jarInfoURL = "https://v2.y2jar.cc/i/"
private let cnvmp3ConvertURL = "https://cnvmp3.com/download_video_ucep.php"
private let thetaMirrors = ["theta","ocococ","cocooo", ...]
```
- الـ Cloudflare Worker ده يبدو خاص بيك — وهو مكشوف في ريبو، فأي حد يقدر يستنزف حصتك.
- المواقع دي بتتغير/تموت باستمرار، وكل تغيير = بناء IPA جديد وإعادة تثبيت.
- **مقترح:** حط الإعدادات في JSON بعيد (GitHub Gist مثلاً) يتقرأ عند الإقلاع مع fallback مدمج — تحدّث الروابط من غير ما تعيد البناء.

**3.9 — استخدام APIs مهجورة في الواجهة**
`UIScreen.main.scale` و`onChange(of:) { _ in }` (صيغة iOS 16). شغالة مع هدف iOS 16، بس هتحذّر/تتكسر مع أهداف أحدث. لما تحدّث الحد الأدنى، انقل لـ `onChange(of:) { _, _ in }` و`@Environment(\.displayScale)`.

---

## 4. 🔵 البنية التحتية والـ CI

**4.1 — البناء بيتم على `main` بس**
```yaml
on:
  push:
    branches: ["main"]
```
يعني أي شغل على فرع مش بيتبني ولا بيتحقق منه إلا بعد الدمج. أضف `pull_request:` على الأقل.

**4.2 — مافيش cache**
كل تشغيل بينصّب XcodeGen عبر Homebrew من الصفر (دقيقة+). استخدم `actions/cache` أو `mint`/binary release.

**4.3 — مافيش `.gitignore`**
لا `build/`، ولا `*.xcarchive`، ولا `Payload/`، ولا `xcuserdata/`، ولا `.DS_Store`. مقترح ملف مبدئي في نهاية التقرير.

**4.4 — مافيش README**
لا شرح للبناء، لا خطوات التثبيت (TrollStore؟ AltStore؟ Sideloadly؟)، لا لقطات شاشة، لا ملاحظات معمارية.

**4.5 — مافيش إصدارات (Releases)**
الـ IPA بيتحفظ كـ artifact بـ `retention-days: 14` وبعدين يختفي. أضف خطوة تعمل GitHub Release عند وسم tag عشان يبقى عندك أرشيف دائم.

**4.6 — مافيش اختبارات ولا فحص ثابت**
مع ~4,700 سطر ومنطق تزامن معقد، حتى اختبارات وحدة لـ `TitleCleaner` و`sanitize` و`decodeWorkerURL` هتمسك انحدارات كتير. `swiftlint` كمان يستاهل.

---

## 5. الحاجات اللي اتعملت صح 👏

عشان الصورة تبقى متوازنة — فيه شغل هندسي كويس فعلاً:

- **`scheduleGeneration`** لتجاهل الـ completion handlers القديمة — ده بالظبط الحل الصح لمشكلة «الأغنية تخطّت لوحدها بعد الـ seek». حل ناضج.
- **`ChunkedDownloader`** — تحليل صح لخنق Cloudflare للاتصال الواحد، وحل عملي بـ Range requests متوازية مع إعادة محاولة لكل chunk وتحقق من الحجم النهائي.
- **التحقق من الملف بالـ magic bytes** قبل الحفظ (ID3 / MPEG sync / ftyp / OggS / RIFF) — يمنع حفظ صفحات HTML كأغاني. ممتاز.
- **سباق الـ backends** مع `probeForAudio` قبل إعلان الفوز — أذكى بكتير من التجريب التسلسلي.
- **`playerQueue`** كـ serial queue لكل تعديلات حالة المشغّل — الفكرة صح تماماً (التنفيذ محتاج بس يلتزم بالـ main thread للنشر).
- **سلسلة الصوت** `player → EQ → preamp → reverb → timePitch → mixer` منطقية ومرتّبة، والاتصال بـ `format: nil` اختيار صحيح للتفاوض التلقائي.
- **`TitleCleaner`** بأنماط regex شاملة + دعم تخمين الفنان — تفصيلة UX لطيفة.
- **التعليقات التفسيرية** في الأماكن الصعبة (ليه `scheduleGeneration`، ليه chunked، ليه إعادة الجدولة عند تغيير السرعة) — نادرة وقيّمة.

---

## 6. خطة تنفيذ مقترحة

| # | المهمة | الأثر | الجهد |
|---|---|---|---|
| 1 | استخراج الكود من `build.yml` لملفات حقيقية | 🔴 يفتح الباب لكل حاجة تانية | ~1 ساعة |
| 2 | إصلاح ثبات الـ Song IDs (1.2) | 🔴 وقف ضياع بيانات المستخدم | ~30 د |
| 3 | نقل تعديلات `@Published` للـ main thread (1.3) | 🔴 وقف الكراشات | ~45 د |
| 4 | إصلاح تكرار المراقبين (1.4) | 🔴 وقف السلوك المزدوج | ~15 د |
| 5 | إصلاح غلاف شاشة القفل (1.5) | 🟠 UX مرئي فوراً | ~20 د |
| 6 | تفعيل Smart Radio فعلياً (2.1) | 🟠 ميزة معطلة | ~30 د |
| 7 | خريطة taskIdentifier في DownloadCenter (2.2) | 🟠 وقف خلط الملفات | ~30 د |
| 8 | تقليل تردد الـ display link + vDSP (2.5, 2.6) | 🟡 بطارية وسلاسة | ~30 د |
| 9 | `.gitignore` + README + PR builds | 🔵 صحة المستودع | ~30 د |

---

## ملحق: `.gitignore` مقترح

```gitignore
# Xcode
build/
DerivedData/
*.xcarchive
*.ipa
Payload/
xcuserdata/
*.xcuserstate
*.xcscmblueprint

# XcodeGen (لو الـ project بيتولّد)
*.xcodeproj/

# macOS
.DS_Store

# ملفات مؤقتة
*.swp
*~
```

---

## ملاحظة أخيرة

الأدوات الخارجية اللي التطبيق بيعتمد عليها (mp3juice / y2jar / cnvmp3) بتستخرج صوت من YouTube، وده مخالف لشروط استخدام YouTube بغض النظر عن نية الاستخدام الشخصي. ده مش رأي قانوني — بس يستاهل تكون واخد بالك منه، خصوصاً لو الريبو عام: أي حد يقدر يشوف الـ Worker endpoint الخاص بيك ويستخدمه.
