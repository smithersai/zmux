import crypto from "node:crypto";

const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

export const WS_OPCODE = {
  CONTINUATION: 0x0,
  TEXT: 0x1,
  BINARY: 0x2,
  CLOSE: 0x8,
  PING: 0x9,
  PONG: 0xa,
} as const;

export const WS_CLOSE_CODE = {
  NORMAL: 1000,
  GOING_AWAY: 1001,
  PROTOCOL_ERROR: 1002,
  POLICY_VIOLATION: 1008,
  MESSAGE_TOO_BIG: 1009,
  INTERNAL_ERROR: 1011,
} as const;

export interface DecodedWsMessage {
  opcode: number;
  payload: Uint8Array;
}

export class WsProtocolError extends Error {
  readonly closeCode: number;

  constructor(message: string, closeCode: number = WS_CLOSE_CODE.PROTOCOL_ERROR) {
    super(message);
    this.name = "WsProtocolError";
    this.closeCode = closeCode;
  }
}

/** Compute RFC 6455 Sec-WebSocket-Accept header value from Sec-WebSocket-Key. */
export function computeWebSocketAccept(secWebSocketKey: string): string {
  return crypto.createHash("sha1").update(secWebSocketKey.trim() + WS_GUID).digest("base64");
}

/** Encode a single RFC 6455 WebSocket frame. */
export function encodeWsFrame(
  opcode: number,
  payload: Uint8Array,
  options?: { fin?: boolean; mask?: Uint8Array },
): Uint8Array {
  const fin = options?.fin ?? true;
  const mask = options?.mask;
  if (mask && mask.byteLength !== 4) {
    throw new RangeError("WebSocket mask key must be exactly 4 bytes");
  }

  const len = payload.byteLength;
  let headerLen = 2;
  if (len >= 126 && len <= 0xffff) headerLen += 2;
  else if (len > 0xffff) headerLen += 8;
  if (mask) headerLen += 4;

  const frame = new Uint8Array(headerLen + len);
  frame[0] = (fin ? 0x80 : 0x00) | (opcode & 0x0f);

  const maskBit = mask ? 0x80 : 0x00;
  let offset = 2;
  if (len < 126) {
    frame[1] = maskBit | len;
  } else if (len <= 0xffff) {
    frame[1] = maskBit | 126;
    frame[2] = (len >>> 8) & 0xff;
    frame[3] = len & 0xff;
    offset = 4;
  } else {
    frame[1] = maskBit | 127;
    const big = BigInt(len);
    for (let i = 0; i < 8; i += 1) {
      frame[2 + i] = Number((big >> BigInt((7 - i) * 8)) & 0xffn);
    }
    offset = 10;
  }

  if (mask) {
    frame.set(mask, offset);
    offset += 4;
    for (let i = 0; i < len; i += 1) {
      frame[offset + i] = (payload[i] ?? 0) ^ (mask[i & 3] ?? 0);
    }
  } else {
    frame.set(payload, offset);
  }

  return frame;
}

/** Encode a RFC 6455 Close frame with status code and optional UTF-8 reason. */
export function encodeWsCloseFrame(
  code: number = WS_CLOSE_CODE.NORMAL,
  reason = "",
  mask?: Uint8Array,
): Uint8Array {
  const reasonBytes = new TextEncoder().encode(reason).subarray(0, 123);
  const payload = new Uint8Array(2 + reasonBytes.byteLength);
  payload[0] = (code >>> 8) & 0xff;
  payload[1] = code & 0xff;
  payload.set(reasonBytes, 2);
  return encodeWsFrame(WS_OPCODE.CLOSE, payload, { mask });
}

function concatChunks(chunks: Uint8Array[], total: number): Uint8Array {
  if (chunks.length === 1) return chunks[0]!;
  const out = new Uint8Array(total);
  let offset = 0;
  for (const c of chunks) {
    out.set(c, offset);
    offset += c.byteLength;
  }
  return out;
}

/**
 * Streaming RFC 6455 WebSocket frame decoder with fragmentation reassembly,
 * masking enforcement, and strict payload bounds.
 */
export class WsFrameDecoder {
  readonly maxPayloadBytes: number;
  readonly requireMasked: boolean;
  private buffer: Uint8Array = new Uint8Array(0);
  private fragOpcode: number | null = null;
  private fragChunks: Uint8Array[] = [];
  private fragBytes = 0;

  constructor(options?: { maxPayloadBytes?: number; requireMasked?: boolean }) {
    this.maxPayloadBytes = options?.maxPayloadBytes ?? 4 * 1024 * 1024;
    this.requireMasked = options?.requireMasked ?? true;
  }

  push(chunk: Uint8Array): DecodedWsMessage[] {
    if (chunk.byteLength === 0) return [];
    if (this.buffer.byteLength === 0) {
      this.buffer = chunk;
    } else {
      const merged = new Uint8Array(this.buffer.byteLength + chunk.byteLength);
      merged.set(this.buffer, 0);
      merged.set(chunk, this.buffer.byteLength);
      this.buffer = merged;
    }

    const messages: DecodedWsMessage[] = [];
    let offset = 0;

    while (this.buffer.byteLength - offset >= 2) {
      const b0 = this.buffer[offset]!;
      const b1 = this.buffer[offset + 1]!;
      const fin = (b0 & 0x80) !== 0;
      const rsv = b0 & 0x70;
      const opcode = b0 & 0x0f;
      const masked = (b1 & 0x80) !== 0;
      let payloadLen = b1 & 0x7f;

      if (rsv !== 0) {
        throw new WsProtocolError("Reserved WebSocket RSV bits must be 0", WS_CLOSE_CODE.PROTOCOL_ERROR);
      }
      if (this.requireMasked && !masked) {
        throw new WsProtocolError("Client WebSocket frames must be masked", WS_CLOSE_CODE.PROTOCOL_ERROR);
      }
      if (!this.requireMasked && masked) {
        throw new WsProtocolError("Server WebSocket frames must not be masked", WS_CLOSE_CODE.PROTOCOL_ERROR);
      }

      const isControl = (opcode & 0x08) !== 0;
      if (isControl && (!fin || payloadLen > 125)) {
        throw new WsProtocolError("Control frames cannot be fragmented or exceed 125 bytes", WS_CLOSE_CODE.PROTOCOL_ERROR);
      }

      let cursor = offset + 2;
      if (payloadLen === 126) {
        if (this.buffer.byteLength - cursor < 2) break;
        payloadLen = ((this.buffer[cursor]! << 8) | this.buffer[cursor + 1]!) >>> 0;
        cursor += 2;
      } else if (payloadLen === 127) {
        if (this.buffer.byteLength - cursor < 8) break;
        let big = 0n;
        for (let i = 0; i < 8; i += 1) {
          big = (big << 8n) | BigInt(this.buffer[cursor + i]!);
        }
        if (big > BigInt(Number.MAX_SAFE_INTEGER)) {
          throw new WsProtocolError("Frame payload length exceeds safe integer range", WS_CLOSE_CODE.MESSAGE_TOO_BIG);
        }
        payloadLen = Number(big);
        cursor += 8;
      }

      if (payloadLen > this.maxPayloadBytes) {
        throw new WsProtocolError(
          `WebSocket frame exceeds limit (${payloadLen} > ${this.maxPayloadBytes} bytes)`,
          WS_CLOSE_CODE.MESSAGE_TOO_BIG,
        );
      }

      const maskLen = masked ? 4 : 0;
      if (this.buffer.byteLength - cursor < maskLen + payloadLen) {
        break;
      }

      let payload: Uint8Array;
      if (masked) {
        const maskKey = this.buffer.subarray(cursor, cursor + 4);
        cursor += 4;
        payload = new Uint8Array(payloadLen);
        for (let i = 0; i < payloadLen; i += 1) {
          payload[i] = this.buffer[cursor + i]! ^ maskKey[i & 3]!;
        }
      } else {
        payload = this.buffer.slice(cursor, cursor + payloadLen);
      }
      cursor += payloadLen;
      offset = cursor;

      if (isControl) {
        if (
          opcode !== WS_OPCODE.CLOSE &&
          opcode !== WS_OPCODE.PING &&
          opcode !== WS_OPCODE.PONG
        ) {
          throw new WsProtocolError(`Unknown control opcode 0x${opcode.toString(16)}`, WS_CLOSE_CODE.PROTOCOL_ERROR);
        }
        messages.push({ opcode, payload });
        continue;
      }

      if (opcode === WS_OPCODE.CONTINUATION) {
        if (this.fragOpcode === null) {
          throw new WsProtocolError("Unexpected continuation frame", WS_CLOSE_CODE.PROTOCOL_ERROR);
        }
        if (this.fragBytes + payload.byteLength > this.maxPayloadBytes) {
          throw new WsProtocolError("Fragmented message exceeds max payload size", WS_CLOSE_CODE.MESSAGE_TOO_BIG);
        }
        this.fragChunks.push(payload);
        this.fragBytes += payload.byteLength;
        if (fin) {
          messages.push({
            opcode: this.fragOpcode,
            payload: concatChunks(this.fragChunks, this.fragBytes),
          });
          this.fragOpcode = null;
          this.fragChunks = [];
          this.fragBytes = 0;
        }
        continue;
      }

      if (opcode !== WS_OPCODE.TEXT && opcode !== WS_OPCODE.BINARY) {
        throw new WsProtocolError(`Unsupported data opcode 0x${opcode.toString(16)}`, WS_CLOSE_CODE.PROTOCOL_ERROR);
      }
      if (this.fragOpcode !== null) {
        throw new WsProtocolError("Received new data frame while fragmented message is active", WS_CLOSE_CODE.PROTOCOL_ERROR);
      }

      if (fin) {
        messages.push({ opcode, payload });
      } else {
        this.fragOpcode = opcode;
        this.fragChunks = [payload];
        this.fragBytes = payload.byteLength;
      }
    }

    if (offset > 0) {
      this.buffer = offset >= this.buffer.byteLength ? new Uint8Array(0) : this.buffer.slice(offset);
    }
    return messages;
  }
}
