# MoneyMate on Android (Flutter): integration guide

This guide is for the team building the Android app in Flutter. It covers the three things that are
specific to MoneyMate: **payment verification with a hardware key**, **push notifications (FCM)**, and
**talking to the backend**. Everything else (screens, glass UI) follows the design canvas.

> The rule: the agent never moves money by itself. Every payment, transfer, conversion and scheduled
> payment waits until the student verifies it on their phone. The phone proves it by signing a one-time
> challenge with a key that only fingerprint / face unlock can use.

---

## 1. Run the backend for the phone

```bash
cd backend && .venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000
```

| Where the app runs | API base URL |
|---|---|
| Android emulator | `http://10.0.2.2:8000/api` (10.0.2.2 is the host machine) |
| Real phone on the same Wi-Fi | `http://<your-laptop-LAN-IP>:8000/api` |

Plain `http` needs cleartext allowed in **debug only**: put
`android:usesCleartextTraffic="true"` in `android/app/src/debug/AndroidManifest.xml`, never in release.
CORS does not apply to native apps, so no backend change is needed.

Demo login: `ayesha` / the `DEMO_USER_PASSWORD` in `backend/.env` (sandbox only).

## 2. Packages (Android-focused)

```bash
flutter pub add dio flutter_riverpod go_router google_fonts lucide_icons_flutter flutter_animate animations firebase_core firebase_messaging flutter_local_notifications flutter_secure_storage qr_flutter share_plus image_picker lottie shimmer
```

| Need | Package |
|---|---|
| HTTP | `dio` |
| State | `flutter_riverpod` |
| Navigation and deep links from notifications | `go_router` |
| Font and icons from the design | `google_fonts` (Inter), `lucide_icons_flutter` |
| Animation | `flutter_animate`, `animations`, `lottie` (fingerprint success), `shimmer` (loading) |
| Push | `firebase_core`, `firebase_messaging`, `flutter_local_notifications` (foreground + channels) |
| Store the login token and device id | `flutter_secure_storage` |
| Receipt QR, share, scam screenshot | `qr_flutter`, `share_plus`, `image_picker` |

**Glass on Android:** use Flutter's `BackdropFilter(filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22))` with a
white overlay at 50–70 % opacity and a 1 px white border. Blur is expensive on low-end Android phones: use it
for the header, tab bar, input bar and bottom sheets only; cards and messages can be plain white at 90 %.

The payment key is **not** done with a pub package: a 70-line Kotlin platform channel (section 4) gives a
hardware-backed key that only BiometricPrompt can unlock, which pub packages usually don't guarantee.

## 3. App flow and API calls

```
Login ─► POST /api/auth/login                         -> access token (store in flutter_secure_storage)
Enrol ─► keystore.publicKey()  (creates the key once)
        POST /api/devices {name, key_type:"p256", public_key, push_token}   -> device_id (store it)
Chat  ─► POST /api/agent/chat {message, session_id}  -> reply + actions[] (+ reminders[])
         an action with status AWAITING_VERIFICATION means: show the verify sheet
Push  ◄─ FCM "Verify to complete your payment"  data: {action_id, kind, notification_id}
Verify─► GET  /api/agent/actions/{id}/challenge      -> {challenge, summary, expires_at}
         keystore.sign(challenge)  -> BiometricPrompt (fingerprint / face) -> signature
         POST /api/agent/actions/{id}/verify {device_id, signature}   -> VERIFIED + receipt
Reject─► POST /api/agent/actions/{id}/reject
```

Other screens: `GET /api/wallet`, `POST /api/wallet/convert`, `GET /api/tuition/invoices`,
`GET /api/tuition/reminders`, `POST /api/remittance/compare`, `POST /api/remittance/send`,
`POST /api/scam-check`, `GET /api/transactions`, `GET /api/transactions/{id}/receipt` (and `.pdf`),
`GET /api/notifications`, `POST /api/notifications/read-all`, `GET/POST /api/standing-instructions`.
Full list with schemas: `http://<host>:8000/docs`.

## 4. Hardware payment key (Kotlin platform channel)

`android/app/build.gradle`: `minSdk 23`, and add `implementation "androidx.biometric:biometric:1.1.0"`.
`AndroidManifest.xml`: `<uses-permission android:name="android.permission.USE_BIOMETRIC"/>`,
`INTERNET`, and `POST_NOTIFICATIONS` (Android 13+).

`android/app/src/main/kotlin/.../MainActivity.kt` (note: `FlutterFragmentActivity`, required by BiometricPrompt):

```kotlin
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec

class MainActivity : FlutterFragmentActivity() {
    private val alias = "moneymate_payment_key"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "moneymate/keystore")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "publicKey" -> result.success(publicKey())
                    "sign" -> sign(call.argument<String>("challenge")!!,
                                   call.argument<String>("reason") ?: "Verify payment", result)
                    "reset" -> { keyStore().deleteEntry(alias); result.success(true) }
                    else -> result.notImplemented()
                }
            }
    }

    private fun keyStore() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun createKey(strongBox: Boolean) {
        val spec = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))   // P-256
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setUserAuthenticationRequired(true)                          // unusable without biometric
            .setInvalidatedByBiometricEnrollment(true)                    // new fingerprint -> key dies
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            spec.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG) // every use
        }
        if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) spec.setIsStrongBoxBacked(true)
        KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore").apply {
            initialize(spec.build()); generateKeyPair()
        }
    }

    private fun publicKey(): String {
        val ks = keyStore()
        if (!ks.containsAlias(alias)) {
            try { createKey(strongBox = true) } catch (e: Exception) { createKey(strongBox = false) }
        }
        // X.509 SubjectPublicKeyInfo, exactly what the backend expects for key_type "p256"
        return Base64.encodeToString(ks.getCertificate(alias).publicKey.encoded, Base64.NO_WRAP)
    }

    private fun sign(challenge: String, reason: String, result: MethodChannel.Result) {
        val signature = try {
            Signature.getInstance("SHA256withECDSA").apply {
                initSign(keyStore().getKey(alias, null) as PrivateKey)
            }
        } catch (e: Exception) {   // e.g. KeyPermanentlyInvalidatedException after a new fingerprint
            result.error("KEY_INVALID", "Re-register this phone", null); return
        }
        val prompt = BiometricPrompt(this, ContextCompat.getMainExecutor(this),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(res: BiometricPrompt.AuthenticationResult) {
                    val s = res.cryptoObject!!.signature!!
                    s.update(challenge.toByteArray(Charsets.UTF_8))
                    result.success(Base64.encodeToString(s.sign(), Base64.NO_WRAP)) // DER signature
                }
                override fun onAuthenticationError(code: Int, msg: CharSequence) {
                    result.error("AUTH_ERROR", msg.toString(), code)
                }
            })
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle("Verify payment")
            .setSubtitle(reason)
            .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
            .setNegativeButtonText("Cancel")
            .build()
        prompt.authenticate(info, BiometricPrompt.CryptoObject(signature))
    }
}
```

Dart side:

```dart
class Keystore {
  static const _ch = MethodChannel('moneymate/keystore');
  Future<String> publicKey() async => (await _ch.invokeMethod<String>('publicKey'))!;
  Future<String> sign(String challenge, String reason) async =>
      (await _ch.invokeMethod<String>('sign', {'challenge': challenge, 'reason': reason}))!;
  Future<void> reset() => _ch.invokeMethod('reset');
}

Future<void> enrolPhone(Dio api, Keystore ks, FlutterSecureStorage store) async {
  final push = await FirebaseMessaging.instance.getToken();
  final res = await api.post('/devices', data: {
    'name': 'My Android phone', 'key_type': 'p256',
    'public_key': await ks.publicKey(), 'push_token': push,
  });
  final id = res.data['id'] as int;
  await store.write(key: 'device_id', value: '$id');
  FirebaseMessaging.instance.onTokenRefresh
      .listen((t) => api.post('/devices/$id/push-token', data: {'push_token': t}));
}

Future<Map> verifyPayment(Dio api, Keystore ks, int deviceId, int actionId) async {
  final ch = (await api.get('/agent/actions/$actionId/challenge')).data;
  final sig = await ks.sign(ch['challenge'], ch['summary']);           // shows BiometricPrompt
  final res = await api.post('/agent/actions/$actionId/verify',
      data: {'device_id': deviceId, 'signature': sig});
  return res.data;                                                    // status VERIFIED, result.receipt
}
```

Errors to handle: `403` = signature rejected (wrong phone or key changed: call `reset()`, enrol again);
`400` "expired" = ask the agent to prepare it again; `KEY_INVALID` from the channel = new fingerprint was
added, re-enrol. The backend also sends a `DEVICE_ADDED` notification whenever a phone is enrolled.

**Emulator testing:** in the emulator's Settings enrol a fingerprint, then use *Extended controls →
Fingerprint → Touch sensor* when BiometricPrompt appears. Emulators have no StrongBox; the code falls back to
the TEE automatically.

## 5. Push notifications (Firebase Cloud Messaging)

1. Firebase console: create a project, add the Android app (package name), download
   `google-services.json` into `android/app/`, run `flutterfire configure` (or add the Gradle plugin).
2. Backend: Firebase console → Project settings → Service accounts → *Generate new private key*. Save it as
   `backend/firebase-service-account.json` (git-ignored) and set in `backend/.env`:
   ```
   PUSH_ENABLED=true
   FCM_PROJECT_ID=<your-firebase-project-id>
   FCM_SERVICE_ACCOUNT_FILE=firebase-service-account.json
   ```
3. Create two Android notification channels at app start with `flutter_local_notifications`:
   `payments` (importance **high**: verify requests, blocks, mule alerts) and `updates` (default).
4. Handle taps: `FirebaseMessaging.instance.getInitialMessage()` and `FirebaseMessaging.onMessageOpenedApp`
   → read `message.data['action_id']` → `context.push('/verify/$actionId')` → show the verify sheet.
5. Foreground messages (`FirebaseMessaging.onMessage`) are not shown by Android automatically: show them
   with `flutter_local_notifications` on the matching channel.
6. Ask for `POST_NOTIFICATIONS` on Android 13+ during onboarding.

The backend sends each notification to every enrolled phone of the student; delivery is best effort and the
in-app list (`GET /api/notifications`) is always the source of truth.

## 6. Demo tips

- `POST /api/sandbox/reset` restores the demo student (wallets, invoice due in 6 days, standing instructions).
- `POST /api/monitor/run?day=2026-11-01` makes the daily monitor act as if it were 1 November (prepares the
  monthly payment to mother and sends the verify notification).
- `POST /api/sandbox/incoming` with a stranger as sender triggers the money-mule alert.
