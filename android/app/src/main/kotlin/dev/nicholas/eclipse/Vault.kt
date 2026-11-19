package dev.nicholas.eclipse

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

object Vault {
    private val executor = Executors.newSingleThreadExecutor()
    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, "eclipse/vault").setMethodCallHandler { call, reply ->
            executor.execute {
                try {
                    fun bytes(k: String) = requireNotNull(call.argument<ByteArray>(k))
                    val output = when (call.method) {
                        "derive" -> {
                            val spec = PBEKeySpec(bytes("password").toString(Charsets.UTF_8).toCharArray(), bytes("salt"), 600000, 256)
                            try { SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded }
                            finally { spec.clearPassword() }
                        }
                        "encrypt", "decrypt" -> {
                            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                            cipher.init(if (call.method == "encrypt") Cipher.ENCRYPT_MODE else Cipher.DECRYPT_MODE,
                                SecretKeySpec(bytes("key"), "AES"), GCMParameterSpec(128, bytes("iv")))
                            cipher.updateAAD(bytes("name"))
                            cipher.doFinal(bytes("data"))
                        }
                        else -> throw IllegalArgumentException()
                    }
                    Handler(Looper.getMainLooper()).post { reply.success(output) }
                } catch (e: Exception) {
                    Handler(Looper.getMainLooper()).post { reply.error("vault", "Could not unlock or process this file", null) }
                }
            }
        }
    }
}
