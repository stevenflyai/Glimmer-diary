#ifndef VAULT_CRYPTO_H
#define VAULT_CRYPTO_H
#include <stddef.h>
#include <stdint.h>
int sg_argon2id(const uint8_t *password, size_t length, const uint8_t *salt, uint8_t *output);
void sg_zero(void *pointer, size_t length);
#endif
