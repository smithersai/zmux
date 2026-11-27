# zmux Python SDK

Official zero-dependency Python 3.10+ SDK for the [zmux](https://github.com/smithersai/zmux) PTY session multiplexer daemon (`zmuxd`).

## Features

- Zero runtime dependencies (Python standard library only)
- Full PEP 561 type annotations (`py.typed`)
- Exact socket path resolution parity with `src/socket_path.zig` and `sun_path` byte-length checks
- Both synchronous (`ZmuxClient`) and `asyncio` (`AsyncZmuxClient`) clients over `AF_UNIX`
- Auto-spawn support for `zmuxd` with retry backoff and same-UID peer authentication
- Bounded 16 MiB NDJSON framing with request ID correlation and clean notification queuing
- Full coverage of all v0.4.0 D1-D6 RPC methods and notifications plus forward-compatible v0.5 and v0.6 helpers
- High-level `AttachedPane` and `AsyncAttachedPane` helpers with scrollback replay and offset deduplication, pattern or exit or idle waiting, and reconnect support

## Installation

Install from the repository root or from the package directory:

```sh
pip install ./sdk/python
```

For local development without installing:

```sh
PYTHONPATH=sdk/python python3 -c "import zmux; print(zmux.__version__)"
```

## Synchronous quickstart

```python
from zmux import ZmuxClient

with ZmuxClient.connect(spawn_daemon=True) as client:
    info = client.ping()
    print(f"Connected to zmuxd {info.version} (pid {info.pid})")

    created = client.create_session(
        "work",
        command="sh",
        rows=30,
        cols=100,
    )

    with client.attach(created.pane_id) as pane:
        pane.send("echo READY_FROM_ZMUX", enter=True)
        match = pane.wait_for(pattern="READY_FROM_ZMUX", timeout=5.0)
        print("Matched:", match.match)

    client.terminate_session(created.pane_id)
```

## Asyncio quickstart

```python
import asyncio
from zmux import AsyncZmuxClient


async def main() -> None:
    async with await AsyncZmuxClient.connect(spawn_daemon=True) as client:
        created = await client.create_session("async-demo", command="sh")
        async with await client.attach(created.pane_id) as pane:
            await pane.send("echo HELLO_ASYNC", enter=True)
            result = await pane.wait_for(pattern="HELLO_ASYNC", timeout=5.0)
            print("Matched:", result.match)
        await client.terminate_session(created.pane_id)


asyncio.run(main())
```

## Streaming pane output

Use `pane.output()` for streaming bytes cleanly with automatic deduplication against `replayBase64` and `replayEndOffset`:

```python
async with await client.attach(pane_id) as pane:
    async for chunk in pane.output():
        print(chunk.decode("utf-8", errors="replace"), end="", flush=True)
```

## Socket path resolution

`resolve_socket_path` follows the exact precedence implemented in `src/socket_path.zig`:

1. Explicit `socket_path` override
2. `$ZMUX_SOCKET`
3. `$SMITHERS_SESSION_SOCKET`
4. `$XDG_RUNTIME_DIR/smithers-sessions.sock`
5. `$HOME/.smithers/sessions.sock`
6. `/tmp/zmux-<euid>/sessions.sock`

Relative paths are resolved against the current working directory. Paths are validated for NUL bytes, trailing slashes, and the kernel `sockaddr_un.sun_path` limit (103 bytes on macOS and 107 bytes on Linux).

## Error handling

All SDK exceptions inherit from `ZmuxError`:

- `ZmuxRpcError(code, kind, message)` for JSON-RPC error responses from `zmuxd`
- `ZmuxConnectionError` for socket connection failures, unexpected disconnects, peer UID mismatches, and daemon spawn errors
- `ZmuxTimeoutError` for connect, RPC, read, and `wait_for` timeouts
- `ZmuxProtocolError` for malformed JSON frames or frames exceeding the 16 MiB cap
- `ZmuxSocketPathError` for invalid or over-long socket paths

## Running tests

Build `zmuxd` first, then run the full unit and live daemon integration test suite:

```sh
zig build
PYTHONPATH=sdk/python python3 -m unittest discover -s sdk/python/tests -v
```
