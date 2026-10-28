# Cấu hình build mobile cho dev / stag / prod — checklist của owner

Trang này là **thứ tự làm**. Cách tạo từng thứ đã có runbook đầy đủ, trang này chỉ trỏ tới:

- Firebase App Distribution + ký dev/stag: [secrets.md → Firebase App Distribution and dev/staging signing](secrets.md#firebase-app-distribution-and-devstaging-signing-gogo-infra271), bước 1–6.
- Ký và phát hành prod: [secrets.md → Store signing material](secrets.md#store-signing-material-gogo-infra231), bước 1–3.
- OneSignal, Tenjin, Maps: [provider-setup.md](provider-setup.md) §5–§7.
- Danh bạ tài khoản và vân tay ký: [accounts.md](accounts.md) → *Account register*, *App identity*.

Nguồn chốt: owner 2026-10-28 (`dev/owner-decisions.md` của workspace: #271, #286, #293, #350/#351, mục cấu hình build
mobile 3 môi trường). Kênh phát hành theo flavour: `dev`, `stag` → Firebase App Distribution (iOS + Android);
chỉ `prod` → TestFlight + Play internal. Lane fastlane thuộc GoGo-MobileApp#391 (dev/stag), #350, #351 (prod).

## Luật cho mọi bước

- **Chỉ owner** tạo tài khoản, key, keystore, Firebase project, app trên store, và ghi giá trị vào SSM.
- Giá trị **luôn qua stdin** (`put.sh` tự hỏi, hoặc `< file`). Không bao giờ là tham số dòng lệnh, không dán vào chat.
- **Giá trị riêng mỗi môi trường.** Không copy giá trị dev sang stag hay prod; chỉ clone cấu trúc. Ngoại lệ có chủ đích:
  `mobile/apple/team-id` (một team Apple), cert Apple Distribution (Apple chỉ có một loại cho App Store và Ad Hoc),
  APNs `.p8` (team-wide, chỉ nằm trong OneSignal). Sentry giữ **một project** `gogo-mobile`, phân biệt bằng tag
  `environment` (ADR-0011, owner 2026-10-28). Client key riêng mỗi môi trường để tắt riêng được là **khuyến nghị
  của agent, owner chưa chốt**; hôm nay một key dùng chung (environments.md, hàng Sentry).
- `put.sh prod …` hỏi xác nhận gõ tay **từ terminal**, nên `< file` vẫn giao đúng nội dung file. Đó là cách duy nhất
  để ghi một key nhiều dòng (`.p8`, JSON).

```bash
export AWS_PROFILE=gogobootstrap          # phiên SSO của owner; script không nhận --profile
cd GoGo-Infra
```

## Tên môi trường: `staging` trong script cho tới khi #286 PR-1 merge

Tên chốt là `dev / stag / prod` (GoGo-Infra#286). Hôm nay `scripts/secrets/common.sh` chỉ nhận `dev | staging | prod`,
nên **mọi lệnh stag phải chờ #286 PR-1 merge**. Không ghi tạm vào `/gogo/staging/…`: cây đó vừa được dọn
(2026-10-28) và #286 bỏ hẳn tên `staging`. Thứ tự làm: **dev → prod → stag**.

## Tổng quan theo môi trường

Cột SSM: `ci:` = `/gogo/ci/<env>/…`, `mobile:` = `/gogo/<env>/mobile/…`, `backend:` = `/gogo/<env>/backend/…`.
`put.sh <env> <path>` tự chọn namespace theo manifest.

| Cần có | dev | stag | prod | SSM |
| --- | --- | --- | --- | --- |
| Bundle id / package | `max.gogo.dev` | `max.gogo.stag` | `max.gogo.prod` | — |
| Apple App ID (Push Notifications bật) | cần | cần | cần | — |
| ASC Team key | `gogo-lane-dev` (Admin) | `gogo-lane-stag` (Admin) | role App Manager | `ci:signing/apple-asc-key`, `-key-id`, `-issuer-id` |
| Android keystore | `gogo-dev.p12` | `gogo-stag.p12` | upload keystore | `ci:signing/android-keystore`, `-keystore-password`, `-key-alias`, `-key-password` |
| Firebase project | `gogo-dev` (App Distribution + FCM) | `gogo-stag` (App Distribution + FCM) | `gogo-prod` (**chỉ FCM**) | dev/stag: `ci:firebase/app-distribution-service-account`, `ci:firebase/app-id-ios`, `ci:firebase/app-id-android` · prod: không có |
| App trên store | — | — | App Store Connect app + Play Console app | `ci:store/play-service-account` (prod) |
| OneSignal app (#299) | `GoGo Development` | `GoGo Staging` (mới) | `GoGo Production` | `backend:onesignal/app-id` (+ `rest-api-key` cho BE) |
| Maps key iOS / Android | key dev | key stag (#278) | key prod (#298) | `mobile:google/maps-ios-api-key`, `mobile:google/maps-android-api-key` |
| Sentry | project `gogo-mobile`, `environment=dev` | `environment=stag` | `environment=prod` | `mobile:sentry/dsn` · `ci:sentry/mobile-auth-token` (token riêng mỗi môi trường) |
| Adjust | app/token dev | app/token stag | app/token prod | `mobile:adjust/ios-app-token`, `mobile:adjust/android-app-token` |
| Tenjin | app dev | app stag | app prod | sau #291: `mobile:tenjin/ios-sdk-key`, `mobile:tenjin/android-sdk-key`; trước #291: `config/bootstrap.env` |
| Apple team id | một giá trị | cùng giá trị | cùng giá trị | sau #291: `mobile:apple/team-id`; trước #291: `config/bootstrap.env` |
| Hostname lane (`--api-url`, `--web-url`) | `https://api-dev.gogo.id.vn/v1`, `https://go-dev.gogo.id.vn` | `https://api-stag.gogo.id.vn/v1`, `https://go-stag.gogo.id.vn` | `https://api.gogo.id.vn/v1`, `https://go.gogo.id.vn` | không phải SSM; stag/prod theo tfvars, **chưa provision** |

Không thuộc môi trường nào, không clone: `ai-harness/*`, `github/agent-app-*` (GoGo-Infra#294).

## 0. Một lần cho cả team Apple (trước dev)

1. **App ID.** Apple Developer → Certificates, Identifiers & Profiles → Identifiers: kiểm tra `max.gogo.dev`,
   `max.gogo.stag`, `max.gogo.prod` đã đăng ký; thiếu thì tạo, bật **Push Notifications** cho cả ba. Profile Ad Hoc
   (dev/stag) và profile App Store (prod) đều cần App ID tồn tại trước.
2. **APNs key.** Apple Developer → Keys. Một `.p8` APNs dùng được cho mọi bundle id của team và Apple giới hạn số key
   APNs mỗi team, nên kiểm tra key đang có trước khi tạo thêm. `.p8` này **chỉ upload lên OneSignal** (provider-setup.md
   §5), không vào SSM, không vào Git.
3. **Thiết bị tester (UDID).** Apple Developer → Devices. Cần trước build Ad Hoc đầu tiên (dev/stag).

## 1. dev

Đã có (đo 2026-10-28, `validate.sh dev --strict --include-planned`): toàn bộ `mobile:` (Maps ×2, Sentry DSN, Adjust ×2) và
`backend:onesignal/app-id`. Còn thiếu 10 hàng `ci:` của Firebase + ký.

1. **Firebase `gogo-dev` + 10 hàng ci** — làm đúng [secrets.md](secrets.md#creating-and-storing-them-owner) bước 1–4
   (`put.sh dev firebase/…`, `put.sh dev signing/…`).
2. **Vân tay keystore** — bước 5 của cùng runbook:
   - SHA-1 → Google Cloud → key `google/maps-android-api-key` của dev → thêm `max.gogo.dev` + SHA-1. Ghi vào
     accounts.md → *App identity*.
   - SHA-256 → PR thêm vào `config/well-known/dev/assetlinks.json` (agent mở PR khi owner đưa vân tay; vân tay là public).
3. **OneSignal `GoGo Development` — FCM.** Kiểm tra app đã có FCM V1 chưa. Chưa thì: Google Cloud, project `gogo-dev`
   → service account JSON cho FCM V1 theo hướng dẫn của OneSignal (Firebase → Project settings → Service accounts →
   Generate new private key; **không** dùng key của SA `app-distribution`) → upload lên OneSignal → Settings → Push
   → Android → xoá file local (`rm -P`). Không vào SSM.
   APNs: upload `.p8` của §0 cho bundle `max.gogo.dev` nếu chưa có.
4. **Tenjin** — trước #291: `TENJIN_IOS_SDK_KEY_DEV`, `TENJIN_ANDROID_SDK_KEY_DEV` trong `config/bootstrap.env`
   (đã có). Sau #291: `put.sh dev tenjin/ios-sdk-key`, `put.sh dev tenjin/android-sdk-key`, `put.sh dev apple/team-id`
   (giá trị lấy từ `bootstrap.env`, qua stdin).
5. **Kiểm tra** — mục [Validate](#validate-theo-môi-trường).

## 2. prod

Hôm nay `/gogo/prod/` trống. Thứ tự theo phụ thuộc: app trên store phải có trước khi lấy được SHA-1 cho Maps Android.

1. **App Store Connect app.** App Store Connect → Apps → tạo app `max.gogo.prod` (cần App ID §0.1).
2. **ASC key prod + upload keystore** — [secrets.md → Store signing](secrets.md#creating-and-storing-them) bước 1–2
   (`put.sh prod signing/…`, có xác nhận `prod`).
3. **Play Console app** `max.gogo.prod` + Play App Signing (mặc định: Google sinh app signing key, keystore ở bước 2
   là upload key). Ghi phương án đã chọn lên GoGo-Infra#231.
4. **Play service account** — secrets.md bước 3 (`put.sh prod store/play-service-account < play-sa.json`).
5. **Maps key prod (#298).** Google Cloud → tạo hai client key (provider-setup.md §7, `param_hint` trong
   `common.sh` có ràng buộc):
   - iOS: restriction bundle `max.gogo.prod`, API = Maps SDK for iOS.
   - Android: package `max.gogo.prod` + **SHA-1 của app signing key** từ Play Console → Test and release → App
     integrity, **không phải** SHA-1 của upload keystore. API = Maps SDK for Android.
   ```bash
   ./scripts/secrets/put.sh prod google/maps-ios-api-key
   ./scripts/secrets/put.sh prod google/maps-android-api-key
   ```
6. **Firebase `gogo-prod` chỉ cho FCM.** Firebase console → project `gogo-prod` → thêm app Android `max.gogo.prod`
   → service account JSON FCM V1 như dev bước 3 → upload lên OneSignal `GoGo Production` → xoá local. **Không** có hàng SSM `firebase/*` ở prod. Ghi project
   vào accounts.md → *Account register*.
7. **OneSignal `GoGo Production`** — APNs `.p8` (§0.2) cho `max.gogo.prod`, FCM ở bước 6. Rồi:
   ```bash
   ./scripts/secrets/put.sh prod onesignal/app-id          # UUID, client config
   ./scripts/secrets/put.sh prod onesignal/rest-api-key    # BE dùng; mobile không đọc
   ```
8. **Sentry** — project `gogo-mobile` → Settings → Client Keys → DSN (key riêng `prod` nếu owner chốt khuyến nghị ở mục Luật); token upload là
   organization auth token mới cho prod (không dùng lại token dev):
   ```bash
   ./scripts/secrets/put.sh prod sentry/dsn                  # DSN, hoặc literal off
   ./scripts/secrets/put.sh prod sentry/mobile-auth-token
   ```
9. **Adjust** — tạo app prod (iOS + Android) trên Adjust, lấy app token. Trước lượt đo máy dùng token thật: cổng
   DPA GoGo-Infra#240.
   ```bash
   ./scripts/secrets/put.sh prod adjust/ios-app-token        # 8–32 chữ/số, hoặc off
   ./scripts/secrets/put.sh prod adjust/android-app-token
   ```
10. **Tenjin** — tạo app prod (iOS + Android), SDK Key ở Apps → app → SDK Key. Trước #291: `TENJIN_IOS_SDK_KEY_PROD`,
    `TENJIN_ANDROID_SDK_KEY_PROD` trong `config/bootstrap.env`. Sau #291: `put.sh prod tenjin/ios-sdk-key`,
    `put.sh prod tenjin/android-sdk-key`, `put.sh prod apple/team-id`.
11. **Kiểm tra** — mục [Validate](#validate-theo-môi-trường).

## 3. stag — chỉ sau #286 PR-1

Mọi lệnh dưới đây dùng `stag` và **chạy được khi #286 PR-1 đã merge**. Trước đó `put.sh` từ chối `stag`.

1. **Firebase `gogo-stag` + 10 hàng ci** — secrets.md bước 1–4, thay `dev` bằng `stag`, key ASC `gogo-lane-stag`,
   keystore `gogo-stag.p12` alias `gogo-stag`.
2. **Vân tay** — bước 5: SHA-1 stag dùng cho Maps stag (bước 3). `stag` không claim link nên không có `assetlinks.json`.
3. **Maps key stag (#278)** — hai client key: iOS bundle `max.gogo.stag`; Android `max.gogo.stag` + SHA-1 keystore stag.
   `put.sh stag google/maps-ios-api-key`, `put.sh stag google/maps-android-api-key`.
4. **OneSignal `GoGo Staging` (app mới)** — APNs `.p8` (§0.2) cho `max.gogo.stag`; FCM V1 từ project `gogo-stag`
   như dev bước 3. Rồi `put.sh stag onesignal/app-id`, `put.sh stag onesignal/rest-api-key`.
5. **Sentry** — DSN của `gogo-mobile` (key riêng `stag` nếu owner chốt); `put.sh stag sentry/dsn`, `put.sh stag sentry/mobile-auth-token` (token mới cho stag).
6. **Adjust, Tenjin** — app stag riêng; `put.sh stag adjust/ios-app-token`, `put.sh stag adjust/android-app-token`;
   Tenjin: trước #291 theo [tenjin-environments.md](tenjin-environments.md) (hậu tố mà `tenjin-mobile-env.py` đọc
   cho môi trường đó); sau #291 `put.sh stag tenjin/ios-sdk-key`, `put.sh stag tenjin/android-sdk-key`,
   `put.sh stag apple/team-id`.
7. **Kiểm tra** — mục [Validate](#validate-theo-môi-trường).

## Validate theo môi trường

Thay `<env>` bằng `dev`, `prod`, hoặc `stag` (sau #286 PR-1). Không lệnh nào in giá trị.

**(a) Manifest + capability.** Đọc các dòng `ci:` của `firebase_distribution_*` (dev, stag), `store_release_*` (prod)
và `sentry_mobile_uploads`. Ở prod/stag lệnh này còn liệt kê hàng backend chưa có — ngoài phạm vi trang này (#293).

```bash
./scripts/secrets/validate.sh <env> --strict --include-planned
```

**(b) Tên hàng mobile.** `validate.sh` chưa bắt buộc hàng `mobile:` ở stag/prod (manifest `required: [dev]`, đổi ở #293),
nên liệt kê trực tiếp — chỉ tên:

```bash
aws ssm get-parameters-by-path --path /gogo/<env>/mobile --recursive \
  --query 'Parameters[].Name' --output text --no-cli-pager | tr '\t' '\n' | sort
```

Kỳ vọng: `google/maps-ios-api-key`, `google/maps-android-api-key`, `sentry/dsn`, `adjust/ios-app-token`,
`adjust/android-app-token` (sau #291 thêm `tenjin/ios-sdk-key`, `tenjin/android-sdk-key`, `apple/team-id`).

**(c) Build env sinh được.** `mobile-env.py` từ chối khi thiếu `backend:onesignal/app-id`, hoặc (stag/prod) thiếu
Sentry DSN / Adjust token. Chỉ in tên biến:

```bash
out="$(mktemp)"
python3 scripts/secrets/mobile-env.py <env> --profile "$AWS_PROFILE" \
  --api-url <api-url> --web-url <web-url> --apns-mode production --out "$out" \
  && cut -d= -f1 "$out"
rm -f "$out"
```

`<api-url>`, `<web-url>`: cột hostname ở bảng tổng quan. Trước #286 PR-1 tham số môi trường của stag là `staging`.
Trước #290, Maps key không có trong file này (dán tay, provider-setup.md); trước #291, Tenjin key do
`tenjin-mobile-env.py <env> --bootstrap config/bootstrap.env --out "$out"` gộp vào.

**(d) Bộ ký resolve đủ.** `exec-with.sh` từ chối trước khi chạy lệnh nếu một hàng không có giá trị; lệnh được chạy là
`/usr/bin/true`, nên không gì in ra hay ghi xuống đĩa. prod hỏi xác nhận gõ tay.

```bash
# dev, stag — Firebase
./scripts/secrets/exec-with.sh <env> signing/apple-asc-key signing/apple-asc-key-id signing/apple-asc-issuer-id \
  firebase/app-distribution-service-account firebase/app-id-ios -- /usr/bin/true && echo "iOS set OK"
./scripts/secrets/exec-with.sh <env> signing/android-keystore signing/android-keystore-password \
  signing/android-key-alias signing/android-key-password \
  firebase/app-distribution-service-account firebase/app-id-android -- /usr/bin/true && echo "Android set OK"

# prod — store
./scripts/secrets/exec-with.sh prod signing/apple-asc-key signing/apple-asc-key-id signing/apple-asc-issuer-id \
  -- /usr/bin/true && echo "iOS set OK"
./scripts/secrets/exec-with.sh prod signing/android-keystore signing/android-keystore-password \
  signing/android-key-alias signing/android-key-password store/play-service-account \
  -- /usr/bin/true && echo "Android set OK"

# mọi môi trường — upload sourcemap/dSYM
./scripts/secrets/exec-with.sh <env> sentry/mobile-auth-token -- /usr/bin/true && echo "Sentry upload OK"
```

(a)–(d) chỉ chứng minh **tên và sự có mặt**. Giá trị đúng hay không chỉ đo được bằng lane thật: build lên Firebase
(GoGo-MobileApp#391) hoặc TestFlight/Play (#350, #351), bản đồ hiện trên máy (logcat không có `Authorization
failure`), push tới máy test.

## Sau khi validate xanh

- PR nhỏ lật `required` của các hàng Firebase (`[dev, stag]`), store (`[prod]`) — secrets.md, mục Readiness.
- #293 lật parity 58 hàng bắt buộc cả 3 môi trường; #290, #291 thêm Maps/Tenjin/team id vào `mobile-env.py`.

## Còn mở

- Hostname stag/prod mới là đề xuất theo `config/staging.tfvars` (`-stag.gogo.id.vn`) và ví dụ trong
  `config/prod.tfvars`; chưa có DNS hay origin. Lane stag/prod chưa gọi được API thật cho tới khi hạ tầng có.
- `EXPO_PUBLIC_ASSISTANT_ENTRY` / `EXPO_PUBLIC_ASSISTANT_MOCK` ở stag/prod: cờ build lane đặt; mock không bao giờ bật
  ở stag/prod — chờ SA xác nhận (GoGo-MobileApp#391, #350, #351).
