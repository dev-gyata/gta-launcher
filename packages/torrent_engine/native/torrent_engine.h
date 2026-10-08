// Copyright (c) 2026 PlayGTA5. BSD-3-Clause; see LICENSE.
#ifndef PLAYGTA5_TORRENT_ENGINE_H
#define PLAYGTA5_TORRENT_ENGINE_H
#include <stdint.h>
#ifdef _WIN32
#define TE_API __declspec(dllexport)
#else
#define TE_API __attribute__((visibility("default")))
#endif
#ifdef __cplusplus
extern "C" {
#endif
TE_API void* te_open(const char* magnet, const char* cache);
TE_API const char* te_error(void* engine);
TE_API int te_poll(void* engine);
TE_API int te_file_count(void* engine);
TE_API const char* te_file_path(void* engine, int file);
TE_API int64_t te_file_size(void* engine, int file);
TE_API int64_t te_file_offset(void* engine, int file);
TE_API int te_piece_length(void* engine);
TE_API int te_piece_size(void* engine, int piece);
TE_API int64_t te_downloaded(void* engine);
TE_API int64_t te_cached_bytes(void* engine);
TE_API void te_request_piece(void* engine, int piece);
TE_API int te_copy_piece(void* engine, int piece, uint8_t* buffer, int capacity);
TE_API void te_release_piece(void* engine, int piece);
TE_API void te_close(void* engine);
TE_API int64_t te_disk_usage(const char* path);
#ifdef __cplusplus
}
#endif
#endif
