/**
 * @file zmux.h
 * @brief C99 ABI for embedding zmux scrollback and UNIX-socket JSON-RPC clients.
 *
 * All functions are safe across the FFI boundary: invalid pointers and invalid
 * status values return explicit error codes instead of aborting. Heap-allocated
 * strings returned by this library must be released with zmux_string_free().
 */

#ifndef ZMUX_H
#define ZMUX_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Status codes returned by libzmux C ABI functions.
 */
typedef enum zmux_status {
    /** Operation completed successfully. */
    ZMUX_OK = 0,
    /** Caller passed a NULL pointer, empty required string, or invalid JSON. */
    ZMUX_ERR_INVALID_ARG = 1,
    /** Memory allocation failed. */
    ZMUX_ERR_OOM = 2,
    /** Operating system I/O or socket error. */
    ZMUX_ERR_IO = 3,
    /** Operation exceeded the caller-supplied timeout. */
    ZMUX_ERR_TIMEOUT = 4,
    /** Peer violated JSON-RPC 2.0 framing or envelope rules. */
    ZMUX_ERR_PROTOCOL = 5,
    /** Peer returned a JSON-RPC 2.0 error object (payload returned in out_json). */
    ZMUX_ERR_RPC = 6,
    /** Resolved socket path or output buffer exceeded capacity limits. */
    ZMUX_ERR_PATH_TOO_LONG = 7,
    /** Connection closed cleanly or reset by peer before completion. */
    ZMUX_ERR_CLOSED = 8,
    /** Target socket path or directory does not exist. */
    ZMUX_ERR_NOT_FOUND = 9,
    /** Peer UID could not be verified or did not match the calling process UID. */
    ZMUX_ERR_PEER_AUTH = 10
} zmux_status_t;

/** Opaque handle to a bounded byte-ring scrollback buffer. */
typedef struct zmux_scrollback zmux_scrollback_t;

/** Opaque handle to an authenticated UNIX-socket zmux JSON-RPC client. */
typedef struct zmux_client zmux_client_t;

/**
 * Return the static NUL-terminated zmux wire protocol version (for example "0.4.0").
 * The returned pointer is statically allocated and must not be freed.
 */
const char *zmux_version(void);

/**
 * Return a static NUL-terminated human-readable description for a status code.
 * Unrecognized status integers return "unknown status". Must not be freed.
 */
const char *zmux_status_string(zmux_status_t status);

/**
 * Resolve the default zmux UNIX socket path using standard environment precedence
 * (ZMUX_SOCKET > SMITHERS_SESSION_SOCKET > XDG_RUNTIME_DIR > HOME > /tmp/zmux-<euid>).
 *
 * @param buf     Destination buffer, or NULL to query the required byte length.
 * @param buf_len Size of @p buf in bytes (including room for the trailing NUL).
 * @param out_len Optional output receiving the path length excluding the trailing NUL.
 * @return ZMUX_OK on success, ZMUX_ERR_PATH_TOO_LONG if @p buf is too small
 *         (in which case @p out_len is still populated), or an error status.
 */
zmux_status_t zmux_default_socket_path(char *buf, size_t buf_len, size_t *out_len);

/**
 * Free a NUL-terminated string allocated by libzmux (such as capture output or
 * JSON-RPC responses). Safe to call with NULL.
 */
void zmux_string_free(char *ptr);

/* -------------------------------------------------------------------------
 * Scrollback ring buffer
 * ------------------------------------------------------------------------- */

/**
 * Allocate a new scrollback ring buffer of @p capacity_bytes (clamped to [1, 64 MiB]).
 *
 * @param capacity_bytes Desired ring capacity in bytes.
 * @return Newly allocated scrollback handle, or NULL on out-of-memory.
 */
zmux_scrollback_t *zmux_scrollback_new(size_t capacity_bytes);

/**
 * Destroy a scrollback buffer created with zmux_scrollback_new(). Safe with NULL.
 */
void zmux_scrollback_free(zmux_scrollback_t *sb);

/**
 * Append @p len raw bytes from @p data to the scrollback ring, evicting oldest
 * retained bytes when full.
 *
 * @param sb   Scrollback handle (must not be NULL).
 * @param data Pointer to bytes to append (may be NULL only when @p len == 0).
 * @param len  Byte count to append.
 * @return ZMUX_OK or ZMUX_ERR_INVALID_ARG.
 */
zmux_status_t zmux_scrollback_append(
    zmux_scrollback_t *sb,
    const uint8_t *data,
    size_t len
);

/**
 * Return the monotonic stream offset one past the newest appended byte.
 * Returns 0 if @p sb is NULL.
 */
uint64_t zmux_scrollback_end_offset(const zmux_scrollback_t *sb);

/**
 * Return the stream offset of the oldest byte still retained in the ring.
 * Returns 0 if @p sb is NULL.
 */
uint64_t zmux_scrollback_start_offset(const zmux_scrollback_t *sb);

/**
 * Capture up to the last @p max_lines lines from the scrollback ring.
 *
 * @param sb        Scrollback handle (must not be NULL).
 * @param max_lines Maximum number of lines to capture.
 * @param max_bytes Maximum byte window to inspect, or 0 to use the full ring capacity.
 * @param out_buf   Receives a newly allocated NUL-terminated buffer; free with zmux_string_free().
 * @param out_len   Optional output receiving the exact captured byte count (excluding NUL).
 * @return ZMUX_OK, ZMUX_ERR_INVALID_ARG, or ZMUX_ERR_OOM.
 */
zmux_status_t zmux_scrollback_capture_lines(
    const zmux_scrollback_t *sb,
    size_t max_lines,
    size_t max_bytes,
    char **out_buf,
    size_t *out_len
);

/* -------------------------------------------------------------------------
 * UNIX-socket JSON-RPC client
 * ------------------------------------------------------------------------- */

/**
 * Connect to a zmux daemon UNIX socket and verify same-UID peer credentials via
 * getpeereid() (macOS/BSD) or SO_PEERCRED (Linux).
 *
 * @param socket_path Explicit socket path, or NULL to use zmux_default_socket_path().
 * @param timeout_ms  Connection timeout in milliseconds (0 uses default 5000 ms).
 * @param out         Receives the connected client handle on ZMUX_OK (set to NULL on error).
 * @return ZMUX_OK, ZMUX_ERR_INVALID_ARG, ZMUX_ERR_NOT_FOUND, ZMUX_ERR_PATH_TOO_LONG,
 *         ZMUX_ERR_TIMEOUT, ZMUX_ERR_PEER_AUTH, ZMUX_ERR_OOM, or ZMUX_ERR_IO.
 */
zmux_status_t zmux_client_connect(
    const char *socket_path,
    uint32_t timeout_ms,
    zmux_client_t **out
);

/**
 * Close the client socket and free all associated resources. Safe with NULL.
 */
void zmux_client_close(zmux_client_t *client);

/**
 * Send a JSON-RPC 2.0 request and wait for the matching response frame.
 * Interleaved server notifications (frames without an "id" field) are skipped.
 *
 * When the daemon replies with a JSON-RPC error object, this function returns
 * ZMUX_ERR_RPC AND populates @p out_json with the raw JSON error frame so the
 * caller can inspect error.code and error.message. Always call zmux_string_free()
 * on @p *out_json when it is non-NULL.
 *
 * @param client      Connected client handle (must not be NULL).
 * @param method      Non-empty JSON-RPC method name (for example "daemon.ping").
 * @param params_json Valid JSON object, array, or null string (NULL defaults to "{}").
 * @param timeout_ms  Total request timeout in milliseconds (0 waits without a timeout).
 * @param out_json    Receives the newly allocated NUL-terminated JSON response line (no trailing '\n').
 * @param out_len     Optional output receiving the byte length of @p *out_json (excluding NUL).
 * @return ZMUX_OK, ZMUX_ERR_RPC, or an error status.
 */
zmux_status_t zmux_client_call_raw(
    zmux_client_t *client,
    const char *method,
    const char *params_json,
    uint32_t timeout_ms,
    char **out_json,
    size_t *out_len
);

/**
 * Convenience wrapper for calling "daemon.ping" with empty params "{}".
 *
 * @param client     Connected client handle (must not be NULL).
 * @param timeout_ms Request timeout in milliseconds (0 waits without a timeout).
 * @param out_json   Receives the newly allocated NUL-terminated JSON response; free with zmux_string_free().
 * @param out_len    Optional output receiving the byte length (excluding NUL).
 * @return ZMUX_OK, ZMUX_ERR_RPC, or an error status.
 */
zmux_status_t zmux_client_ping(
    zmux_client_t *client,
    uint32_t timeout_ms,
    char **out_json,
    size_t *out_len
);

/**
 * Read the next newline-delimited JSON frame from the daemon socket (such as
 * streaming pane_output or session_exited notifications).
 *
 * @param client     Connected client handle (must not be NULL).
 * @param timeout_ms Read timeout in milliseconds (0 waits without a timeout).
 * @param out_json   Receives the newly allocated NUL-terminated JSON frame (no trailing '\n').
 * @param out_len    Optional output receiving the byte length (excluding NUL).
 * @return ZMUX_OK, ZMUX_ERR_TIMEOUT, ZMUX_ERR_CLOSED, ZMUX_ERR_PROTOCOL, or an error status.
 */
zmux_status_t zmux_client_read_frame(
    zmux_client_t *client,
    uint32_t timeout_ms,
    char **out_json,
    size_t *out_len
);

#ifdef __cplusplus
}
#endif

#endif /* ZMUX_H */
