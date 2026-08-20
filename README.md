# AS Music (TrollMusicApp)

مشغّل موسيقى شخصي لـ iOS مبني بـ SwiftUI و `AVAudioEngine`، مع مكتبة محلية،
قوائم تشغيل، مُعادِل صوت (EQ) بعشر نطاقات، ومتصفح ويب مدمج.

> **مشروع شخصي — غير مخصص للنشر.** مافيش توقيع (unsigned IPA)، والتثبيت
> بيتم عن طريق sideloading.

---

## البنية

⚠️ **كل الكود المصدري عايش داخل `.github/workflows/build.yml`.**

الـ workflow بيمسح ملفات `.swift` من نسخة الـ CI وبيعيد كتابتها من heredocs
جوّه الـ YAML، وبعدها بيبني بـ XcodeGen. ده اختيار مقصود للمشروع ده.

**يعني عند التعديل:** عدّل الكود جوّه `build.yml` — أي تعديل على ملفات
`TrollMusicApp/**/*.swift` مش هيوصل للبناء (بتتمسح في خطوة `Clean Environment`).

الملفات المولّدة من الـ workflow:

| الملف | المحتوى |
|---|---|
| `TrollMusicAppApp.swift` | نقطة الدخول، `AppDelegate`، إعداد جلسة الصوت |
| `MusicManager.swift` | محرك التشغيل، EQ، المكتبة، قوائم التشغيل، Now Playing |
| `Views.swift` | كل واجهات SwiftUI |
| `SmartDownloader.swift` | محرك البحث والتنزيل + `ChunkedDownloader` |
| `WebBrowser.swift` | متصفح `WKWebView` مع زر تنزيل محقون |

### سلسلة الصوت

```
AVAudioPlayerNode → AVAudioUnitEQ (10 bands) → preamp mixer
                  → AVAudioUnitReverb → AVAudioUnitTimePitch → mainMixerNode
```

كل تعديلات حالة المشغّل بتتسلسل على `playerQueue` (serial DispatchQueue)،
وكل نشر لـ `@Published` بيروح للـ main thread عبر `onMain(_:)`.

---

## البناء

البناء بيتم تلقائياً على GitHub Actions عند الـ push لـ `main` أو أي فرع
`arena/**`، وعلى الـ pull requests، أو يدوياً من تبويب Actions
(`workflow_dispatch`).

الناتج: artifact اسمه `TrollMusicApp-IPA` (محفوظ 14 يوم).

### التثبيت

الـ IPA غير موقّع — استخدم واحدة من:

- **TrollStore** (أفضل خيار — تثبيت دائم بدون إعادة توقيع)
- **Sideloadly** / **AltStore** (بيوقّعوا بحسابك، ويحتاجوا تجديد)

الحد الأدنى: **iOS 16.0**.

---

## ملاحظات

- التطبيق بيعتمد على خدمات استخراج صوت خارجية (`y2jar`، `cnvmp3`، Cloudflare
  Worker خاص، `thetacloud`). الروابط مكتوبة في `SmartDownloader.swift` تحت
  `// ---- Backend URLs ----` — لو خدمة وقعت، غيّر الرابط هناك وأعد البناء.
- الـ Cloudflare Worker المستخدم خاص بصاحب المشروع؛ الرابط مكشوف في الريبو.
- استخراج الصوت من YouTube مخالف لشروط استخدام YouTube — الاستخدام شخصي فقط.

## توثيق إضافي

- [`docs/CODE_REVIEW.md`](docs/CODE_REVIEW.md) — مراجعة كود كاملة وقائمة
  الإصلاحات المطبّقة.
