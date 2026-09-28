// The part of libarchive's C API that Explorer uses. macOS ships libarchive
// (/usr/lib/libarchive.2.dylib, the one behind /usr/bin/tar) but not its
// header, so the declarations are repeated here from libarchive 3.7's
// archive.h and archive_entry.h. The API has been stable since 3.0.
#ifndef EXPLORER_CARCHIVE_H
#define EXPLORER_CARCHIVE_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

struct archive;
struct archive_entry;

#define ARCHIVE_EOF 1
#define ARCHIVE_OK 0
#define ARCHIVE_RETRY (-10)
#define ARCHIVE_WARN (-20)
#define ARCHIVE_FAILED (-25)
#define ARCHIVE_FATAL (-30)

#define ARCHIVE_EXTRACT_PERM (0x0002)
#define ARCHIVE_EXTRACT_TIME (0x0004)
#define ARCHIVE_EXTRACT_SECURE_SYMLINKS (0x0100)
#define ARCHIVE_EXTRACT_SECURE_NODOTDOT (0x0200)

struct archive *archive_read_new(void);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_all(struct archive *);
int archive_read_add_passphrase(struct archive *, const char *);
int archive_read_open_filename(struct archive *, const char *filename, size_t block_size);
int archive_read_next_header(struct archive *, struct archive_entry **);
int archive_read_data_block(struct archive *, const void **buffer, size_t *size, int64_t *offset);
int archive_read_data_skip(struct archive *);
int archive_read_free(struct archive *);
int64_t archive_filter_bytes(struct archive *, int n);
const char *archive_error_string(struct archive *);

struct archive *archive_write_disk_new(void);
int archive_write_disk_set_options(struct archive *, int flags);
int archive_write_disk_set_standard_lookup(struct archive *);
int archive_write_header(struct archive *, struct archive_entry *);
ssize_t archive_write_data_block(struct archive *, const void *, size_t, int64_t);
int archive_write_finish_entry(struct archive *);
int archive_write_close(struct archive *);
int archive_write_free(struct archive *);

const char *archive_entry_pathname_utf8(struct archive_entry *);
void archive_entry_set_pathname_utf8(struct archive_entry *, const char *);
const char *archive_entry_hardlink_utf8(struct archive_entry *);
void archive_entry_set_hardlink_utf8(struct archive_entry *, const char *);
int archive_entry_is_encrypted(struct archive_entry *);

#endif
