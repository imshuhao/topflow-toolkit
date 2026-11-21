#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NETWORK_MODEM_COUNT 3

struct modem_status {
    char target_status[3][16];
};

#include "../touchui-json.inc"

/* Explicit fail returns so NDEBUG cannot greenwash the test. */
static int check_storage(const char *state)
{
    char runtime[8192], storage[1024];

    if (!json_object(state, "runtime", runtime, sizeof(runtime))) {
        fprintf(stderr, "json-key-match: FAIL runtime object\n");
        return 0;
    }
    if (!json_object(runtime, "storage", storage, sizeof(storage))) {
        fprintf(stderr, "json-key-match: FAIL storage object\n");
        return 0;
    }
    if (!(json_ull(storage, "total", 0) > 0)) {
        fprintf(stderr, "json-key-match: FAIL storage.total\n");
        return 0;
    }
    if (!(json_ull(storage, "used", 0) > 0)) {
        fprintf(stderr, "json-key-match: FAIL storage.used\n");
        return 0;
    }
    if (!(json_ull(storage, "available", 0) > 0)) {
        fprintf(stderr, "json-key-match: FAIL storage.available\n");
        return 0;
    }
    return 1;
}

int main(void)
{
    const char *state =
        "{\"aggregation\":{\"server\":{\"source\":\"runtime\"}},"
        "\"runtime\" : {\"storage\":{\"total\":4096,"
        "\"used\":1024,\"available\":3072}}}";

    if (!check_storage(state))
        return 1;
    puts("json-key-match: ok");
    return 0;
}
