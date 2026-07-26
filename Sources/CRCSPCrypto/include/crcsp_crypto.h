#ifndef CRCSP_CRYPTO_H
#define CRCSP_CRYPTO_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Loads libjl_bluetooth.so from soPath, applies relocations and the
 * TPIDR_EL0/W^X patches needed to run it natively on Apple Silicon, and
 * calls its JNI_OnLoad to capture the real getRandomAuthData /
 * getEncryptedAuthData / nativeInit function pointers.
 * Returns 0 on success, nonzero on failure. Must be called once before
 * any other rcsp_crypto_* function. Not thread-safe. */
int rcsp_crypto_load(const char *soPath);

/* Fills out[17] with a fresh RCSP challenge: out[0] = 0x00 followed by
 * 16 random bytes. Does not require the vendor's nativeInit RNG — any
 * CSPRNG is fine here, this is just a nonce. */
void rcsp_crypto_random_challenge(uint8_t out[17]);

/* Runs the vendor's getEncryptedAuthData on in[17] (marker byte + 16
 * payload bytes) and writes the 17-byte result (marker=0x01 + 16
 * encrypted bytes) into out[17]. Returns 0 on success. */
int rcsp_crypto_encrypt(const uint8_t in_[17], uint8_t out[17]);

#ifdef __cplusplus
}
#endif

#endif
