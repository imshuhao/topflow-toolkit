static int fetch_datad_state(char *out, size_t size)
{
    static const char request[] =
        "GET /state HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    struct sockaddr_in address;
    struct timeval timeout = {1, 0};
    const char *body;
    size_t used = 0, sent = 0, body_length;
    int fd;

    if (!out || size < 3) return 0;
    out[0] = '\0';
    fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(DATAD_PORT);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(fd);
        return 0;
    }
    while (sent < sizeof(request) - 1) {
        ssize_t count = send(fd, request + sent, sizeof(request) - 1 - sent, 0);
        if (count <= 0) { close(fd); return 0; }
        sent += (size_t)count;
    }
    while (used + 1 < size) {
        ssize_t count = recv(fd, out + used, size - 1 - used, 0);
        if (count == 0) break;
        if (count < 0) { close(fd); return 0; }
        used += (size_t)count;
    }
    close(fd);
    out[used] = '\0';
    if (strncmp(out, "HTTP/1.0 200", 12) && strncmp(out, "HTTP/1.1 200", 12))
        return 0;
    body = strstr(out, "\r\n\r\n");
    if (!body) return 0;
    body += 4;
    body_length = used - (size_t)(body - out);
    if (body_length + 1 > size) return 0;
    memmove(out, body, body_length);
    out[body_length] = '\0';
    return json_output_complete(out);
}

static int post_datad_control(const char *payload, char *out, size_t size)
{
    struct sockaddr_in address;
    struct timeval timeout = {2, 0};
    char request[1024], response[8192];
    const char *body;
    size_t request_length, sent = 0, used = 0, body_length;
    int fd, written;

    if (!payload || !out || size < 3) return 0;
    out[0] = '\0';
    written = snprintf(request, sizeof(request),
        "POST /control HTTP/1.0\r\nHost: 127.0.0.1\r\n"
        "Content-Type: application/json\r\nContent-Length: %zu\r\n"
        "Connection: close\r\n\r\n%s", strlen(payload), payload);
    if (written <= 0 || (size_t)written >= sizeof(request)) return 0;
    request_length = (size_t)written;
    fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(DATAD_PORT);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(fd);
        return 0;
    }
    while (sent < request_length) {
        ssize_t count = send(fd, request + sent, request_length - sent, 0);
        if (count <= 0) { close(fd); return 0; }
        sent += (size_t)count;
    }
    while (used + 1 < sizeof(response)) {
        ssize_t count = recv(fd, response + used, sizeof(response) - 1 - used, 0);
        if (count == 0) break;
        if (count < 0) { close(fd); return 0; }
        used += (size_t)count;
    }
    close(fd);
    response[used] = '\0';
    if (strncmp(response, "HTTP/1.0 200", 12) &&
        strncmp(response, "HTTP/1.1 200", 12)) return 0;
    body = strstr(response, "\r\n\r\n");
    if (!body) return 0;
    body += 4;
    body_length = used - (size_t)(body - response);
    if (body_length + 1 > size) return 0;
    memcpy(out, body, body_length);
    out[body_length] = '\0';
    return json_output_complete(out);
}

static int json_output_complete(const char *json)
{
    const char *start = json, *end;
    while (*start == ' ' || *start == '\t' || *start == '\r' || *start == '\n') start++;
    if (*start != '{') return 0;
    end = start + strlen(start);
    while (end > start && (end[-1] == ' ' || end[-1] == '\t' ||
                           end[-1] == '\r' || end[-1] == '\n')) end--;
    return end > start && end[-1] == '}';
}

static void touchui_mgr_trace(const char *phase, const char *arg1, const char *arg2, int rc)
{
    int logfd;
    char line[256];
    int n;
    logfd = open("/tmp/touchui-singbox-manager.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (logfd < 0) return;
    if (arg2)
        n = snprintf(line, sizeof(line), "%ld [touchui] %s %s %s rc=%d\n",
                     (long)time(NULL), phase, arg1 ? arg1 : "-", arg2, rc);
    else
        n = snprintf(line, sizeof(line), "%ld [touchui] %s %s rc=%d\n",
                     (long)time(NULL), phase, arg1 ? arg1 : "-", rc);
    if (n > 0) {
        if (n >= (int)sizeof(line)) n = (int)sizeof(line) - 1;
        (void)write(logfd, line, (size_t)n);
    }
    close(logfd);
}

/* Execute only the fixed manager path and fixed arguments; no shell is used. */
static int run_singbox_manager(char *output, size_t size, const char *arg1, const char *arg2)
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
    touchui_mgr_trace("begin", arg1, arg2, 0);
    if (pipe(pipefd) < 0) return -1;
    pid = fork();
    if (pid < 0) { close(pipefd[0]); close(pipefd[1]); return -1; }
    if (pid == 0) {
        int logfd;
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        close(pipefd[1]);
        logfd = open("/tmp/touchui-singbox-manager.log", O_WRONLY|O_CREAT|O_APPEND, 0644);
        if (logfd >= 0) { dup2(logfd, STDERR_FILENO); close(logfd); }
        if (arg2) {
            char *const argv[] = {(char *)SINGBOX_MANAGER, (char *)arg1, (char *)arg2, NULL};
            execve(SINGBOX_MANAGER, argv, clean_env);
        } else {
            char *const argv[] = {(char *)SINGBOX_MANAGER, (char *)arg1, NULL};
            execve(SINGBOX_MANAGER, argv, clean_env);
        }
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
        /* The stock UI has its own SIGCHLD handler and can reap our child
         * first. Pipe EOF plus a complete JSON document proves that the
         * command finished producing a usable response. */
        if (errno == ECHILD && json_output_complete(output)) {
            touchui_mgr_trace("done-echild", arg1, arg2, 0);
            return 0;
        }
        touchui_mgr_trace("waitpid-fail", arg1, arg2, -1);
        return -1;
    }
    if (!WIFEXITED(status)) {
        touchui_mgr_trace("bad-status", arg1, arg2, -1);
        return -1;
    }
    touchui_mgr_trace("done", arg1, arg2, WEXITSTATUS(status));
    return WEXITSTATUS(status);
}
