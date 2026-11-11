static void safe_copy(char *dst, size_t size, const char *src)
{
    if (!size) return;
    snprintf(dst, size, "%s", src ? src : "");
}

static int json_value(const char *json, const char *key, const char **value)
{
    char pattern[80];
    const char *p, *separator;
    size_t pattern_length;
    snprintf(pattern, sizeof(pattern), "\"%s\"", key);
    pattern_length = strlen(pattern);
    for (p = json; (p = strstr(p, pattern)) != NULL; p += pattern_length) {
        separator = p + pattern_length;
        while (*separator == ' ' || *separator == '\t' ||
               *separator == '\r' || *separator == '\n') separator++;
        if (*separator != ':') continue;
        for (separator++; *separator == ' ' || *separator == '\t' ||
             *separator == '\r' || *separator == '\n'; separator++) { }
        *value = separator;
        return 1;
    }
    return 0;
}

static int json_bool(const char *json, const char *key, int fallback)
{
    const char *p;
    if (!json_value(json, key, &p)) return fallback;
    if (!strncmp(p, "true", 4) || *p == '1') return 1;
    if (!strncmp(p, "false", 5) || *p == '0') return 0;
    return fallback;
}

static long json_long(const char *json, const char *key, long fallback)
{
    const char *p;
    char *end;
    long value;
    if (!json_value(json, key, &p)) return fallback;
    errno = 0;
    value = strtol(p, &end, 10);
    return (errno || end == p) ? fallback : value;
}

static int json_string(const char *json, const char *key, char *out, size_t size)
{
    const char *p;
    size_t used = 0;
    if (!size) return 0;
    out[0] = '\0';
    if (!json_value(json, key, &p) || *p++ != '"') return 0;
    while (*p && *p != '"' && used + 1 < size) {
        if (*p == '\\' && p[1]) {
            p++;
            out[used++] = *p == 'n' ? '\n' : (*p == 'r' ? '\r' : (*p == 't' ? '\t' : *p));
            p++;
        } else out[used++] = *p++;
    }
    out[used] = '\0';
    return 1;
}

static double json_double(const char *json, const char *key, double fallback,
                          int *valid)
{
    const char *p;
    char *end;
    double value;
    if (valid) *valid = 0;
    if (!json_value(json, key, &p)) return fallback;
    if (*p == '"') p++;
    errno = 0;
    value = strtod(p, &end);
    if (errno || end == p) return fallback;
    if (valid) *valid = 1;
    return value;
}

static unsigned long long json_ull(const char *json, const char *key,
                                   unsigned long long fallback)
{
    const char *p;
    char *end;
    unsigned long long value;
    if (!json_value(json, key, &p)) return fallback;
    if (*p == '"') p++;
    errno = 0;
    value = strtoull(p, &end, 10);
    return (errno || end == p) ? fallback : value;
}

static int copy_json_object(const char *start, char *out, size_t size)
{
    const char *p;
    int depth = 0, in_string = 0, escaped = 0;
    size_t length;
    if (!start || *start != '{' || !out || size < 3) return 0;
    for (p = start; *p; p++) {
        if (in_string) {
            if (escaped) escaped = 0;
            else if (*p == '\\') escaped = 1;
            else if (*p == '"') in_string = 0;
            continue;
        }
        if (*p == '"') in_string = 1;
        else if (*p == '{') depth++;
        else if (*p == '}' && --depth == 0) {
            length = (size_t)(p - start + 1);
            if (length >= size) return 0;
            memcpy(out, start, length);
            out[length] = '\0';
            return 1;
        }
    }
    return 0;
}

static int json_object(const char *json, const char *key, char *out, size_t size)
{
    const char *value;
    return json_value(json, key, &value) && copy_json_object(value, out, size);
}

static int copy_json_array(const char *start, char *out, size_t size)
{
    const char *p;
    int depth = 0, in_string = 0, escaped = 0;
    size_t length;
    if (!start || *start != '[' || !out || size < 3) return 0;
    for (p = start; *p; p++) {
        if (in_string) {
            if (escaped) escaped = 0;
            else if (*p == '\\') escaped = 1;
            else if (*p == '"') in_string = 0;
            continue;
        }
        if (*p == '"') in_string = 1;
        else if (*p == '[') depth++;
        else if (*p == ']' && --depth == 0) {
            length = (size_t)(p - start + 1);
            if (length >= size) return 0;
            memcpy(out, start, length);
            out[length] = '\0';
            return 1;
        }
    }
    return 0;
}

static int json_array(const char *json, const char *key, char *out, size_t size)
{
    const char *value;
    return json_value(json, key, &value) && copy_json_array(value, out, size);
}

static int json_string_array_join(const char *json, const char *key,
                                  char *out, size_t size)
{
    char array[1024], item[256];
    const char *p;
    size_t used = 0;
    int items = 0;
    if (!out || !size) return 0;
    out[0] = '\0';
    if (!json_array(json, key, array, sizeof(array))) return 0;
    p = array + 1;
    while (*p && *p != ']' && items < 2) {
        size_t item_used = 0;
        while (*p && *p != '"' && *p != ']') p++;
        if (*p != '"') break;
        p++;
        while (*p && *p != '"' && item_used + 1 < sizeof(item)) {
            if (*p == '\\' && p[1]) p++;
            item[item_used++] = *p++;
        }
        item[item_used] = '\0';
        if (*p == '"') p++;
        if (item_used) {
            int count = snprintf(out + used, size - used, "%s%s",
                                 items ? " · " : "", item);
            if (count < 0 || (size_t)count >= size - used) break;
            used += (size_t)count;
            items++;
        }
    }
    return items > 0;
}

static int ca_carrier_count(const char *value)
{
    int count = 0;
    const char *p;
    if (!value || !*value) return 0;
    count = 1;
    for (p = value; *p; p++) if (*p == ';') count++;
    return count;
}

static void parse_path_targets(const char *path, struct modem_status *status)
{
    char targets[4096], target[1024];
    const char *p, *start;
    int index = 0;
    if (!json_array(path, "targets", targets, sizeof(targets))) return;
    p = targets + 1;
    while (index < 3 && (start = strchr(p, '{')) != NULL &&
           copy_json_object(start, target, sizeof(target))) {
        json_string(target, "status", status->target_status[index],
                    sizeof(status->target_status[index]));
        index++;
        p = start + strlen(target);
    }
}

static int modem_json_object(const char *json, int index, char *out, size_t size)
{
    static const char *markers[NETWORK_MODEM_COUNT] = {
        "{\"id\":\"x75\",\"role\":\"integrated_5g\"",
        "{\"id\":\"v3e1\",\"role\":\"external_4g\"",
        "{\"id\":\"v3e2\",\"role\":\"external_4g\""
    };
    const char *start;
    if (index < 0 || index >= NETWORK_MODEM_COUNT) return 0;
    start = strstr(json, markers[index]);
    return start && copy_json_object(start, out, size);
}

static int json_object_by_id(const char *json, const char *id,
                             char *out, size_t size)
{
    char marker[64];
    const char *start;
    if (!json || !id || !*id) return 0;
    snprintf(marker, sizeof(marker), "{\"id\":\"%s\"", id);
    start = strstr(json, marker);
    return start && copy_json_object(start, out, size);
}

static int json_output_complete(const char *json);
