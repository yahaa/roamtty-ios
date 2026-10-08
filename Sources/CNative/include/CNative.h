#pragma once
#include <sqlite3.h>
#include <libssh2.h>
#include <libssh2_sftp.h>
#include <openssl/evp.h>
#include <openssl/sha.h>
#include <openssl/rand.h>
#include <zlib.h>
int roam_ocb(int encrypt, const unsigned char *key, const unsigned char *nonce,
             const unsigned char *input, int length, unsigned char *output, unsigned char *tag);
void roam_sha256(const unsigned char *input, size_t length, unsigned char *output);
