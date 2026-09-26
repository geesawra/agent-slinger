#include "PaseoNaCl.h"
#include "tweetnacl.h"

#include <Security/SecRandom.h>
#include <stdlib.h>
#include <string.h>

static void secure_zero(void *pointer, size_t count) {
  volatile uint8_t *bytes = pointer;
  while (count--) *bytes++ = 0;
}

// The reference TweetNaCl object refers to randombytes even though Oesap
// supplies random material explicitly and never calls crypto_box_keypair.
void randombytes(unsigned char *bytes, unsigned long long count) {
  if (count > SIZE_MAX || SecRandomCopyBytes(kSecRandomDefault, (size_t)count, bytes) != errSecSuccess) {
    abort();
  }
}

int paseo_nacl_random(uint8_t *bytes, size_t count) {
  return SecRandomCopyBytes(kSecRandomDefault, count, bytes) == errSecSuccess ? 0 : -1;
}

int paseo_nacl_public(const uint8_t secret_key[32], uint8_t public_key[32]) {
  return crypto_scalarmult_base(public_key, secret_key);
}

int paseo_nacl_client_session(const uint8_t peer_public_key[32],
                              uint8_t public_key[32], uint8_t shared_key[32]) {
  uint8_t secret_key[32];
  if (paseo_nacl_random(secret_key, sizeof secret_key) != 0) return -1;
  int result = paseo_nacl_public(secret_key, public_key);
  if (result == 0) result = paseo_nacl_derive(secret_key, peer_public_key, shared_key);
  secure_zero(secret_key, sizeof secret_key);
  return result;
}

int paseo_nacl_derive(const uint8_t secret_key[32], const uint8_t peer_public_key[32], uint8_t shared_key[32]) {
  uint8_t raw[32];
  if (crypto_scalarmult(raw, secret_key, peer_public_key) != 0) return -1;
  uint8_t any_nonzero = 0;
  for (size_t i = 0; i < 32; i++) any_nonzero |= raw[i];
  secure_zero(raw, sizeof raw);
  if (any_nonzero == 0) return -1;
  return crypto_box_beforenm(shared_key, peer_public_key, secret_key);
}

int paseo_nacl_encrypt(const uint8_t shared_key[32], const uint8_t nonce[24],
                       const uint8_t *plaintext, size_t plaintext_count,
                       uint8_t *ciphertext) {
  if (plaintext_count > SIZE_MAX - 32) return -1;
  size_t padded_count = plaintext_count + 32;
  uint8_t *padded_plaintext = calloc(padded_count, 1);
  uint8_t *padded_ciphertext = malloc(padded_count);
  if (!padded_plaintext || !padded_ciphertext) {
    free(padded_plaintext);
    free(padded_ciphertext);
    return -1;
  }
  if (plaintext_count) memcpy(padded_plaintext + 32, plaintext, plaintext_count);
  int result = crypto_box_afternm(padded_ciphertext, padded_plaintext,
                                  padded_count, nonce, shared_key);
  if (result == 0) memcpy(ciphertext, padded_ciphertext + 16, plaintext_count + 16);
  secure_zero(padded_plaintext, padded_count);
  secure_zero(padded_ciphertext, padded_count);
  free(padded_plaintext);
  free(padded_ciphertext);
  return result;
}

int paseo_nacl_decrypt(const uint8_t shared_key[32], const uint8_t nonce[24],
                       const uint8_t *ciphertext, size_t ciphertext_count,
                       uint8_t *plaintext) {
  if (ciphertext_count < 16 || ciphertext_count > SIZE_MAX - 16) return -1;
  size_t padded_count = ciphertext_count + 16;
  uint8_t *padded_ciphertext = calloc(padded_count, 1);
  uint8_t *padded_plaintext = malloc(padded_count);
  if (!padded_ciphertext || !padded_plaintext) {
    free(padded_ciphertext);
    free(padded_plaintext);
    return -1;
  }
  memcpy(padded_ciphertext + 16, ciphertext, ciphertext_count);
  int result = crypto_box_open_afternm(padded_plaintext, padded_ciphertext,
                                       padded_count, nonce, shared_key);
  if (result == 0 && ciphertext_count > 16)
    memcpy(plaintext, padded_plaintext + 32, ciphertext_count - 16);
  secure_zero(padded_ciphertext, padded_count);
  secure_zero(padded_plaintext, padded_count);
  free(padded_ciphertext);
  free(padded_plaintext);
  return result;
}
