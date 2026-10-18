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
int roam_tcp_connect(const char *host, int port, int timeout_ms);
int roam_socket_poll(int socket, int read_ready, int write_ready, int timeout_ms);
void roam_socket_shutdown(int socket);
void roam_socket_close(int socket);
// Numeric address of a connected socket's peer, written into `host`. Returns zero on success.
int roam_socket_peer(int socket, char *host, int length);
// Atomic, same-volume move that refuses to replace any existing destination. Returns errno or zero.
int roam_move_exclusive(const char *source, const char *destination);
