#include "VaultCrypto.h"
#include <sodium.h>
int sg_argon2id(const uint8_t *password, size_t length, const uint8_t *salt, uint8_t *output) {
    if (sodium_init() < 0) return -1;
    return crypto_pwhash(output, 32, (const char *)password, length, salt,
                        3, 64 * 1024 * 1024, crypto_pwhash_ALG_ARGON2ID13);
}
void sg_zero(void *pointer, size_t length) { sodium_memzero(pointer, length); }
