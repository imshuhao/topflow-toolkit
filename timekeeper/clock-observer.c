/* Record successful audited UTC clock writes. Never adjust their arguments. */
#define _GNU_SOURCE
#include "clock-event.h"
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static void record_write(void *caller, int calendar_write)
{
    int saved_errno = errno;
    char exe[256] = {0}, boot_id[38] = {0}, tmp[128], text[256];
    struct stat st;
    struct timespec real, boot;
    Dl_info info = {0};
    const char *source = "other";
    int fd = -1;
    uintptr_t offset;

    if (geteuid() != 0 || readlink("/proc/self/exe", exe, sizeof(exe)-1) < 0 ||
        !dladdr(caller, &info)) goto done;
    /* Reinstallation may leave an identical bind-mounted inode unlinked.
     * The shell guard verifies its actual /proc/PID/exe hash before saving. */
    size_t length = strlen(exe);
    if (length > 10 && !strcmp(exe + length - 10, " (deleted)")) exe[length - 10] = '\0';
    offset = (uintptr_t)caller - (uintptr_t)info.dli_fbase;
    if (!calendar_write && !strcmp(exe, "/usr/bin/zte_topsw_nwinfo") && offset == 0x31cac)
        source = "NITZ";
    else if (!calendar_write && !strcmp(exe, "/usr/bin/ntpclient") && offset == 0x4eb4)
        source = "SNTP";
    /* A manual write in either instrumented daemon invalidates the old event. */
    if (strcmp(exe, "/usr/bin/zte_topsw_nwinfo") && strcmp(exe, "/usr/bin/ntpclient") &&
        strcmp(exe, "/usr/bin/zte_topsw_ntp")) goto done;
    if (clock_gettime(CLOCK_REALTIME, &real) || clock_gettime(CLOCK_BOOTTIME, &boot)) goto done;
    fd = open("/proc/sys/kernel/random/boot_id", O_RDONLY|O_CLOEXEC);
    if (fd < 0) goto done;
    ssize_t n = read(fd, boot_id, 36);
    close(fd); fd = -1;
    if (n != 36) goto done;
    if (mkdir(EVENT_DIR, 0700) && errno != EEXIST) goto done;
    if (lstat(EVENT_DIR, &st) || !S_ISDIR(st.st_mode) || st.st_uid != 0 || (st.st_mode & 0077)) goto done;
    snprintf(tmp, sizeof(tmp), EVENT_DIR "/.event-XXXXXX");
    fd = mkstemp(tmp);
    if (fd < 0) goto done;
    int len = snprintf(text, sizeof(text), "v1 %s %s %lld %ld %lld %ld\n", boot_id, source,
        (long long)real.tv_sec, real.tv_nsec, (long long)boot.tv_sec, boot.tv_nsec);
    int ok = len > 0 && (size_t)len < sizeof(text) && write(fd, text, (size_t)len) == len;
    close(fd); fd = -1;
    if (ok) rename(tmp, EVENT_FILE);
    unlink(tmp);
done:
    if (fd >= 0) close(fd);
    errno = saved_errno;
}

int clock_settime(clockid_t id, const struct timespec *ts)
{
    int (*next)(clockid_t, const struct timespec *);
    *(void **)(&next) = dlsym(RTLD_NEXT, "clock_settime");
    if (!next) { errno = ENOSYS; return -1; }
    int result = next(id, ts);
    if (!result && id == CLOCK_REALTIME) record_write(__builtin_return_address(0), 0);
    return result;
}

int settimeofday(const struct timeval *tv, const struct timezone *tz)
{
    int (*next)(const struct timeval *, const struct timezone *);
    *(void **)(&next) = dlsym(RTLD_NEXT, "settimeofday");
    if (!next) { errno = ENOSYS; return -1; }
    int result = next(tv, tz);
    if (!result && tv) record_write(__builtin_return_address(0), 1);
    return result;
}
