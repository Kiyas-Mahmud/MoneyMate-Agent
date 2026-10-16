package com.moneymate.moneymate

import android.content.Intent
import android.os.Build
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
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

/**
 * Payment key: a P-256 key in the Android Keystore that only a strong biometric (fingerprint / face)
 * can unlock, once per signature. The private key never leaves the secure hardware; the backend only
 * stores the public key and checks each payment's one-time challenge signature.
 */
class MainActivity : FlutterFragmentActivity() {
    private val alias = "moneymate_payment_key"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "moneymate/keystore")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "status" -> result.success(status())
                    "publicKey" -> try {
                        result.success(publicKey())
                    } catch (e: Exception) {
                        result.error("NO_BIOMETRIC", "Set up fingerprint unlock on this phone first", e.message)
                    }
                    "sign" -> sign(call.argument<String>("challenge")!!,
                                   call.argument<String>("reason") ?: "Verify payment", result)
                    "reset" -> { keyStore().deleteEntry(alias); result.success(true) }
                    "openEnroll" -> { openEnroll(); result.success(true) }
                    else -> result.notImplemented()
                }
            }
    }

    /** "ready", "none_enrolled" (no fingerprint set up yet) or "unavailable" (no suitable sensor). */
    private fun status(): String = when (BiometricManager.from(this).canAuthenticate(BIOMETRIC_STRONG)) {
        BiometricManager.BIOMETRIC_SUCCESS -> "ready"
        BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> "none_enrolled"
        else -> "unavailable"
    }

    /** Opens the system screen where the student adds a fingerprint themselves. */
    private fun openEnroll() {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Intent(Settings.ACTION_BIOMETRIC_ENROLL).putExtra(Settings.EXTRA_BIOMETRIC_AUTHENTICATORS_ALLOWED, BIOMETRIC_STRONG)
        } else {
            Intent(Settings.ACTION_SECURITY_SETTINGS)
        }
        startActivity(intent)
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
            result.error("KEY_INVALID", "This phone's payment key changed. Register it again.", e.message); return
        }
        val prompt = BiometricPrompt(this, ContextCompat.getMainExecutor(this),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(res: BiometricPrompt.AuthenticationResult) {
                    val s = res.cryptoObject!!.signature!!
                    s.update(challenge.toByteArray(Charsets.UTF_8))
                    result.success(Base64.encodeToString(s.sign(), Base64.NO_WRAP)) // DER signature
                }
                override fun onAuthenticationError(code: Int, msg: CharSequence) {
                    val cancelled = code == BiometricPrompt.ERROR_NEGATIVE_BUTTON ||
                        code == BiometricPrompt.ERROR_USER_CANCELED || code == BiometricPrompt.ERROR_CANCELED
                    result.error(if (cancelled) "CANCELLED" else "AUTH_ERROR", msg.toString(), code)
                }
            })
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle("Verify payment")
            .setSubtitle(reason)
            .setAllowedAuthenticators(BIOMETRIC_STRONG)
            .setNegativeButtonText("Cancel")
            .build()
        prompt.authenticate(info, BiometricPrompt.CryptoObject(signature))
    }
}
