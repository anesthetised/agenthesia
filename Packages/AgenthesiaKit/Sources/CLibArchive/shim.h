// macOS ships libarchive but omits its headers from the SDK. Declare only the
// stable C ABI used by the reader, matching libarchive's archive{,_entry}.h.
// https://github.com/libarchive/libarchive/tree/master/libarchive
#include <stddef.h>
#include <stdint.h>
#include <sys/stat.h>
#include <sys/types.h>

struct archive;
struct archive_entry;

#define ARCHIVE_OK 0
#define ARCHIVE_EOF 1
#define AE_IFREG S_IFREG
#define AE_IFDIR S_IFDIR

struct archive *archive_read_new(void);
int archive_read_free(struct archive *);
int archive_read_support_filter_none(struct archive *);
int archive_read_support_filter_gzip(struct archive *);
int archive_read_support_filter_bzip2(struct archive *);
int archive_read_support_filter_xz(struct archive *);
int archive_read_support_format_tar(struct archive *);
int archive_read_support_format_zip(struct archive *);
int archive_read_open_filename(struct archive *, const char *, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *, size_t);
const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
mode_t archive_entry_perm(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
