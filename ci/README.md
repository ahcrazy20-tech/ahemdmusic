# نسخة محدّثة من ملف البناء

`ci/build.yml` هو **البديل الجاهز** لـ `.github/workflows/build.yml`.

## ليه موجود هنا بدل مكانه الطبيعي؟

الرفع الآلي على `.github/workflows/` اترفض من GitHub:

```
refusing to allow a GitHub App to create or update workflow
`.github/workflows/build.yml` without `workflows` permission
```

فاتحطت النسخة الجديدة في مسار عادي عشان توصلك، وتنقلها بنفسك.

## إزاي تطبّقها

### الطريقة الأسهل — من واجهة GitHub

1. افتح `ci/build.yml` على GitHub واضغط **Raw** ثم انسخ كل المحتوى.
2. افتح `.github/workflows/build.yml` واضغط أيقونة القلم (Edit).
3. امسح كل المحتوى القديم والصق الجديد.
4. **Commit changes**.

### أو من جهازك

```bash
git pull
cp ci/build.yml .github/workflows/build.yml
git add .github/workflows/build.yml
git commit -m "chore: apply reviewed build workflow"
git push
```

### أو تدي الصلاحية وخلاص

اعمل reconnect لـ GitHub من Arena واختار صلاحية `workflows` — وساعتها
التعديلات تترفع مباشرة من غير الخطوة اليدوية دي.

---

## بعد ما تطبّقها

احذف مجلد `ci/` — بقى مالوش لازمة:

```bash
git rm -r ci && git commit -m "chore: drop staged workflow copy" && git push
```

---

## اللي اتغيّر في النسخة دي

الملف الأصلي 4,875 سطر، الجديد 5,146 سطر. الفرق كله إصلاحات داخل كود
Swift المكتوب جوّه الـ heredocs، بالإضافة لتعديلات على الـ workflow نفسه.

### كود Swift

**`MusicManager.swift`**

- مُعرِّفات أغاني ثابتة مشتقة من اسم الملف (SHA-256) بدل `UUID()` عشوائي كل
  تشغيل — ده كان بيفضّي كل قوائم التشغيل و«Liked Songs» بعد أول restart.
- كل تعديلات `@Published` بقت تمر على الـ main thread عبر `onMain(_:)`.
- مراقبو `AVAudioSession` بيتسجّلوا مرة واحدة بس بدل كل استدعاء لـ
  `setupEngine()` (كانوا بيتضاعفوا بعد كل media-services reset).
- `setupEngine()` بتفكّ الـ tap وتوقف المحرك القديم قبل ما تبني جديد.
- إصلاح غلاف شاشة القفل: البيانات الأساسية تتنشر الأول والغلاف يترقّع بعدها،
  مع تجاهله لو المستخدم غيّر الأغنية.
- `artworkImage` بترجع دايماً على الـ main thread وبتفك ترميز الصور على
  thread خلفي.
- Smart Radio بقى يشتغل فعلاً (كان كود ميت وراء `return` مبكّر) وبياخد بيانات
  الأغنية الخارجة بدل `currentSong` المتسابق.
- `CADisplayLink` نزل لـ 12fps وبيتوقف وقت السكون.
- قياس المستوى بـ `vDSP` من غير أي dispatch من thread الصوت.
- `private init`، البحث عن «Liked Songs» بالاسم مش بالفهرس، و`deleteSong`
  بتنظّف المراجع الميتة.

**`SmartDownloader.swift`**

- ربط كل `URLSessionTask` بالـ `DownloadTask` بتاعها عبر `taskIdentifier` —
  كان ممكن ملف ينزل باسم أغنية تانية.
- `sanitize()`: شيل النقط البادئة (كانت بتخلي الأغنية تنزل وما تظهرش أبداً)،
  شيل محارف التحكم، وقص عند حد الـ 255 بايت.
- `seek(toOffset:)` اللي بيرمي أخطاء بدل الـ API القديم الصامت.
- شيل `removeItem` الزائد قبل `moveItem`.

**`Views.swift`**

- وقف تعديل `DownloadCenter.showBanner` أثناء بناء الواجهة، وقراءة القيمة
  الواردة بدل القديمة.

### الـ workflow نفسه

- ATS اتقيّد على محتوى الويب بس بدل `NSAllowsArbitraryLoads` على التطبيق كله.
- البناء بقى يشتغل على الـ pull requests وفروع `arena/**`.
- `concurrency` مع `cancel-in-progress` لإلغاء البناءات القديمة.
- تخطّي تثبيت XcodeGen لو موجود.

التفاصيل الكاملة في [`../docs/CODE_REVIEW.md`](../docs/CODE_REVIEW.md).

---

## ⚠️ لسه محتاج تجربة بناء

مافيش Swift compiler في البيئة اللي اتعمل فيها الشغل، فالتحقق كان مراجعة
يدوية + فحوص بنيوية (توازن الأقواس، صحة الـ YAML، واختبار
استخراج/إعادة-حقن الملفات الخمسة round-trip بنتيجة مطابقة تماماً).

**أول تشغيل للـ workflow بعد التطبيق هو اللي هيأكد إن الكود بيتجمّع.** لو ظهر
أي خطأ compile، ابعتلي اللوج وأصلحه.
