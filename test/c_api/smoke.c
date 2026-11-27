#include "zmux.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void fail(const char *msg, int line) {
    fprintf(stderr, "FAIL (line %d): %s\n", line, msg);
    exit(1);
}

#define CHECK(cond)                                    \
    do {                                               \
        if (!(cond)) {                                 \
            fail(#cond, __LINE__);                     \
        }                                              \
    } while (0)

static void test_version_and_status(void) {
    const char *ver = zmux_version();
    CHECK(ver != NULL);
    CHECK(strcmp(ver, "0.5.0") == 0);

    const zmux_status_t codes[] = {
        ZMUX_OK,
        ZMUX_ERR_INVALID_ARG,
        ZMUX_ERR_OOM,
        ZMUX_ERR_IO,
        ZMUX_ERR_TIMEOUT,
        ZMUX_ERR_PROTOCOL,
        ZMUX_ERR_RPC,
        ZMUX_ERR_PATH_TOO_LONG,
        ZMUX_ERR_CLOSED,
        ZMUX_ERR_NOT_FOUND,
        ZMUX_ERR_PEER_AUTH
    };
    for (size_t i = 0; i < sizeof(codes) / sizeof(codes[0]); ++i) {
        const char *s = zmux_status_string(codes[i]);
        CHECK(s != NULL);
        CHECK(strlen(s) > 0);
        CHECK(strcmp(s, "unknown status") != 0);
    }

    const char *unk = zmux_status_string((zmux_status_t)999);
    CHECK(unk != NULL);
    CHECK(strcmp(unk, "unknown status") == 0);
}

static void test_default_socket_path(void) {
    CHECK(zmux_default_socket_path(NULL, 0, NULL) == ZMUX_ERR_INVALID_ARG);
    CHECK(zmux_default_socket_path(NULL, 16, NULL) == ZMUX_ERR_INVALID_ARG);

    size_t needed = 0;
    CHECK(zmux_default_socket_path(NULL, 0, &needed) == ZMUX_OK);
    CHECK(needed > 0);

    char tiny[4];
    size_t tiny_out = 0;
    CHECK(zmux_default_socket_path(tiny, sizeof(tiny), &tiny_out) == ZMUX_ERR_PATH_TOO_LONG);
    CHECK(tiny_out == needed);
    CHECK(tiny[0] == '\0');

    char path[256];
    size_t written = 0;
    CHECK(zmux_default_socket_path(path, sizeof(path), &written) == ZMUX_OK);
    CHECK(written == needed);
    CHECK(path[0] == '/');
    CHECK(strlen(path) == written);
}

static void test_scrollback(void) {
    zmux_scrollback_free(NULL);
    zmux_string_free(NULL);
    CHECK(zmux_scrollback_end_offset(NULL) == 0);
    CHECK(zmux_scrollback_start_offset(NULL) == 0);
    CHECK(zmux_scrollback_append(NULL, (const uint8_t *)"a", 1) == ZMUX_ERR_INVALID_ARG);

    zmux_scrollback_t *sb = zmux_scrollback_new(16);
    CHECK(sb != NULL);
    CHECK(zmux_scrollback_start_offset(sb) == 0);
    CHECK(zmux_scrollback_end_offset(sb) == 0);

    CHECK(zmux_scrollback_append(sb, NULL, 0) == ZMUX_OK);
    CHECK(zmux_scrollback_append(sb, NULL, 4) == ZMUX_ERR_INVALID_ARG);

    const char *text = "one\ntwo\nthree\nfour\n";
    const size_t text_len = strlen(text);
    CHECK(zmux_scrollback_append(sb, (const uint8_t *)text, text_len) == ZMUX_OK);
    CHECK(zmux_scrollback_end_offset(sb) == (uint64_t)text_len);
    CHECK(zmux_scrollback_start_offset(sb) == (uint64_t)(text_len - 16));

    char *captured = NULL;
    size_t cap_len = 0;
    CHECK(zmux_scrollback_capture_lines(sb, 2, 0, &captured, &cap_len) == ZMUX_OK);
    CHECK(captured != NULL);
    CHECK(cap_len == strlen("three\nfour\n"));
    CHECK(strcmp(captured, "three\nfour\n") == 0);
    zmux_string_free(captured);

    captured = NULL;
    cap_len = 0;
    CHECK(zmux_scrollback_capture_lines(sb, 5, 5, &captured, &cap_len) == ZMUX_OK);
    CHECK(captured != NULL);
    CHECK(cap_len == 5);
    CHECK(strcmp(captured, "four\n") == 0);
    zmux_string_free(captured);

    CHECK(zmux_scrollback_capture_lines(NULL, 1, 0, &captured, &cap_len) == ZMUX_ERR_INVALID_ARG);
    CHECK(zmux_scrollback_capture_lines(sb, 1, 0, NULL, NULL) == ZMUX_ERR_INVALID_ARG);

    zmux_scrollback_free(sb);
}

static void test_client_errors(void) {
    zmux_client_close(NULL);

    CHECK(zmux_client_connect("/tmp/x.sock", 50, NULL) == ZMUX_ERR_INVALID_ARG);

    zmux_client_t *client = (zmux_client_t *)0x1;
    CHECK(zmux_client_connect("", 50, &client) == ZMUX_ERR_INVALID_ARG);
    CHECK(client == NULL);

    CHECK(
        zmux_client_connect("/tmp/zmux-c99-nonexistent-smoke.sock", 50, &client)
        == ZMUX_ERR_NOT_FOUND
    );
    CHECK(client == NULL);

    char too_long[200];
    too_long[0] = '/';
    memset(too_long + 1, 's', sizeof(too_long) - 2);
    too_long[sizeof(too_long) - 1] = '\0';
    CHECK(zmux_client_connect(too_long, 50, &client) == ZMUX_ERR_PATH_TOO_LONG);
    CHECK(client == NULL);

    char *json = (char *)0x1;
    size_t len = 42;
    CHECK(zmux_client_ping(NULL, 50, &json, &len) == ZMUX_ERR_INVALID_ARG);
    CHECK(json == NULL);
    CHECK(len == 0);
    CHECK(zmux_client_call_raw(NULL, "daemon.ping", "{}", 50, &json, &len) == ZMUX_ERR_INVALID_ARG);
    CHECK(zmux_client_read_frame(NULL, 50, &json, &len) == ZMUX_ERR_INVALID_ARG);
}

static void test_live_daemon(const char *sock_path) {
    zmux_client_t *client = NULL;
    zmux_status_t st = zmux_client_connect(sock_path, 2000, &client);
    CHECK(st == ZMUX_OK);
    CHECK(client != NULL);

    char *json = NULL;
    size_t len = 0;
    st = zmux_client_ping(client, 2000, &json, &len);
    CHECK(st == ZMUX_OK);
    CHECK(json != NULL);
    CHECK(len == strlen(json));
    CHECK(strstr(json, "\"result\"") != NULL);
    CHECK(strstr(json, "\"0.5.0\"") != NULL);
    zmux_string_free(json);

    json = NULL;
    len = 0;
    st = zmux_client_call_raw(client, "mux.snapshot", "{}", 2000, &json, &len);
    CHECK(st == ZMUX_OK);
    CHECK(json != NULL);
    CHECK(len == strlen(json));
    CHECK(strstr(json, "\"sessions\"") != NULL);
    zmux_string_free(json);

    json = NULL;
    len = 0;
    st = zmux_client_call_raw(client, "session.list", "{}", 2000, &json, &len);
    CHECK(st == ZMUX_OK);
    CHECK(json != NULL);
    CHECK(len == strlen(json));
    CHECK(strstr(json, "\"result\"") != NULL);
    zmux_string_free(json);

    json = NULL;
    len = 0;
    st = zmux_client_call_raw(client, "nonexistent.method", "{}", 2000, &json, &len);
    CHECK(st == ZMUX_ERR_RPC);
    CHECK(json != NULL);
    CHECK(len == strlen(json));
    CHECK(strstr(json, "-32601") != NULL);
    zmux_string_free(json);

    json = NULL;
    len = 0;
    st = zmux_client_read_frame(client, 20, &json, &len);
    CHECK(st == ZMUX_ERR_TIMEOUT);
    CHECK(json == NULL);
    CHECK(len == 0);

    zmux_client_close(client);
    printf("libzmux live daemon ping + RPC checks passed (%s)\n", sock_path);
}

static void test_vt_engine(void) {
    CHECK(zmux_vt_new(0, 80, 16) == NULL);
    zmux_vt_free(NULL);

    zmux_vt_t *vt = zmux_vt_new(6, 40, 32);
    CHECK(vt != NULL);

    const char *stream = "\x1b]2;c99-demo\x07\x1b[32mhello\x1b[0m\r\nworld";
    CHECK(zmux_vt_feed(vt, (const uint8_t *)stream, strlen(stream)) == ZMUX_OK);

    char *plain = NULL;
    size_t plain_len = 0;
    CHECK(zmux_vt_plain_text(vt, 0, &plain, &plain_len) == ZMUX_OK);
    CHECK(plain != NULL && plain_len == strlen(plain));
    CHECK(strstr(plain, "hello") != NULL && strstr(plain, "world") != NULL);
    zmux_string_free(plain);

    char *ansi = NULL;
    size_t ansi_len = 0;
    CHECK(zmux_vt_ansi_restore(vt, &ansi, &ansi_len) == ZMUX_OK);
    CHECK(ansi != NULL && ansi_len > 0);
    zmux_string_free(ansi);

    char *json = NULL;
    size_t json_len = 0;
    CHECK(zmux_vt_screen_json(vt, 0, &json, &json_len) == ZMUX_OK);
    CHECK(json != NULL && json_len == strlen(json));
    CHECK(strstr(json, "\"title\":\"c99-demo\"") != NULL);
    zmux_string_free(json);

    CHECK(zmux_vt_resize(vt, 12, 80) == ZMUX_OK);
    zmux_vt_free(vt);
}

int main(void) {
    test_version_and_status();
    test_default_socket_path();
    test_scrollback();
    test_vt_engine();
    test_client_errors();

    const char *live_sock = getenv("ZMUX_TEST_SOCKET");
    if (live_sock != NULL && live_sock[0] != '\0') {
        test_live_daemon(live_sock);
    }

    printf("libzmux C99 smoke test passed\n");
    return 0;
}
