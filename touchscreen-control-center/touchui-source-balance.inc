static void format_kb_human(long kb, char *out, size_t size)
{
    double v;
    if (!out || !size) return;
    if (kb < 0) kb = 0;
    if (kb < 1024) {
        snprintf(out, size, "%ldKB", kb);
        return;
    }
    if (kb < 1024L * 1024L) {
        v = (double)kb / 1024.0;
        snprintf(out, size, v >= 100 ? "%.0fMB" : "%.1fMB", v);
        return;
    }
    v = (double)kb / (1024.0 * 1024.0);
    snprintf(out, size, v >= 100 ? "%.0fGB" : "%.2fGB", v);
}

static int parse_balance_card(const char *obj, struct balance_card_status *card)
{
    memset(card, 0, sizeof(*card));
    if (!obj || !*obj) return 0;
    card->ok = json_bool(obj, "ok", 0);
    json_string(obj, "id", card->id, sizeof(card->id));
    json_string(obj, "operator", card->operator_name, sizeof(card->operator_name));
    json_string(obj, "label", card->label, sizeof(card->label));
    json_string(obj, "phone_tail", card->phone_tail, sizeof(card->phone_tail));
    json_string(obj, "error", card->error, sizeof(card->error));
    card->general_remain_kb = json_long(obj, "general_remain_kb", 0);
    card->general_total_kb = json_long(obj, "general_total_kb", 0);
    card->general_used_kb = json_long(obj, "general_used_kb", 0);
    card->directed_remain_kb = json_long(obj, "directed_remain_kb", 0);
    card->directed_total_kb = json_long(obj, "directed_total_kb", 0);
    card->directed_used_kb = json_long(obj, "directed_used_kb", 0);
    card->directed_unlimited = json_bool(obj, "directed_unlimited", 0);
    card->directed_unlimit_used_kb = json_long(obj, "directed_unlimit_used_kb", 0);
    card->jump_delta_kb = json_long(obj, "jump_delta_kb", 0);
    card->free_delta_kb = json_long(obj, "free_delta_kb", 0);
    card->jump_today_kb = json_long(obj, "jump_today_kb", 0);
    if (!card->label[0]) {
        if (!strcmp(card->operator_name, "unicom"))
            safe_copy(card->label, sizeof(card->label), "联通");
        else if (!strcmp(card->operator_name, "telecom"))
            safe_copy(card->label, sizeof(card->label), "电信");
        else
            safe_copy(card->label, sizeof(card->label), "卡");
    }
    return 1;
}

static int collect_balance_status(struct balance_status *status)
{
    char raw[8192], cards[6144], card[1536];
    const char *p, *start;
    FILE *file;
    size_t n;
    struct tm local;
    time_t wall;
    int index = 0;

    memset(status, 0, sizeof(*status));
    file = fopen(BALANCE_STATUS_PATH, "r");
    if (!file) return 0;
    n = fread(raw, 1, sizeof(raw) - 1, file);
    fclose(file);
    if (n == 0) return 0;
    raw[n] = '\0';

    status->ok = json_bool(raw, "ok", 0);
    json_string(raw, "updated", status->updated, sizeof(status->updated));
    json_string(raw, "next", status->next, sizeof(status->next));
    json_string(raw, "error", status->error, sizeof(status->error));
    status->interval_sec = (int)json_long(raw, "interval_sec", 900);
    if (!json_array(raw, "cards", cards, sizeof(cards))) {
        /* still valid file, just empty */
        wall = time(NULL);
        localtime_r(&wall, &local);
        if (!status->updated[0])
            snprintf(status->updated, sizeof(status->updated), "%02d:%02d:%02d",
                     local.tm_hour, local.tm_min, local.tm_sec);
        status->valid = 1;
        return 1;
    }
    p = cards + 1;
    while (index < BALANCE_CARD_COUNT &&
           (start = strchr(p, '{')) != NULL &&
           copy_json_object(start, card, sizeof(card))) {
        parse_balance_card(card, &status->cards[index]);
        index++;
        p = start + strlen(card);
    }
    status->card_count = index;
    if (!status->updated[0]) {
        wall = time(NULL);
        localtime_r(&wall, &local);
        snprintf(status->updated, sizeof(status->updated), "%02d:%02d:%02d",
                 local.tm_hour, local.tm_min, local.tm_sec);
    }
    status->valid = 1;
    return 1;
}

/* Fixed-path refresh; no shell, no credentials on argv. */
static int run_balance_watch_once(char *output, size_t size)
{
    static char *const clean_env[] = {
        "PATH=/usr/sbin:/usr/bin:/sbin:/bin",
        "HOME=/root",
        "LANG=C",
        NULL
    };
    int pipefd[2], status = -1;
    pid_t pid;
    size_t used = 0;
    ssize_t count;
    if (!size) return -1;
    output[0] = '\0';
    if (access(BALANCE_WATCH_SH, X_OK) != 0) return -1;
    if (pipe(pipefd) < 0) return -1;
    pid = fork();
    if (pid < 0) { close(pipefd[0]); close(pipefd[1]); return -1; }
    if (pid == 0) {
        char *const argv[] = {(char *)BALANCE_WATCH_SH, (char *)"once", NULL};
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        dup2(pipefd[1], STDERR_FILENO);
        close(pipefd[1]);
        execve(BALANCE_WATCH_SH, argv, clean_env);
        _exit(127);
    }
    close(pipefd[1]);
    while ((count = read(pipefd[0], output + used, size - used - 1)) > 0) {
        used += (size_t)count;
        if (used + 1 >= size) {
            char discard[512];
            while (read(pipefd[0], discard, sizeof(discard)) > 0) { }
            break;
        }
    }
    output[used] = '\0';
    close(pipefd[0]);
    if (waitpid(pid, &status, 0) < 0) {
        if (errno == ECHILD) return 0;
        return -1;
    }
    if (!WIFEXITED(status)) return -1;
    return WEXITSTATUS(status);
}
