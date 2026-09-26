#ifndef PASEO_NACL_H
#define PASEO_NACL_H

#include <stddef.h>
#include <stdint.h>

// Returns 0 on success. All buffers have fixed sizes except plaintext and cipher.
int paseo_nacl_client_session(const uint8_t peer_public_key[32],
                              uint8_t public_key[32], uint8_t shared_key[32]);
int paseo_nacl_public(const uint8_t secret_key[32], uint8_t public_key[32]);
int paseo_nacl_derive(const uint8_t secret_key[32], const uint8_t peer_public_key[32], uint8_t shared_key[32]);
int paseo_nacl_random(uint8_t *bytes, size_t count);
int paseo_nacl_encrypt(const uint8_t shared_key[32], const uint8_t nonce[24],
                       const uint8_t *plaintext, size_t plaintext_count,
                       uint8_t *ciphertext);
int paseo_nacl_decrypt(const uint8_t shared_key[32], const uint8_t nonce[24],
                       const uint8_t *ciphertext, size_t ciphertext_count,
                       uint8_t *plaintext);

#endif
