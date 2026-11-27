import { ZmuxFrameError } from "./errors.ts";

/** Maximum response frame length enforced by zmuxd (16 MiB). */
export const DEFAULT_MAX_FRAME_BYTES = 16 * 1024 * 1024;

const textDecoder = new TextDecoder("utf-8", { fatal: false });
const textEncoder = new TextEncoder();

/**
 * Bounded newline-delimited JSON (NDJSON) frame parser.
 * Handles arbitrary TCP/UNIX chunk boundaries, multi-line bursts, and CRLF,
 * while throwing `ZmuxFrameError` if any line exceeds `maxFrameBytes`.
 */
export class NdjsonFrameParser {
  readonly maxFrameBytes: number;
  private chunks: Uint8Array[] = [];
  private bufferedBytes = 0;

  constructor(maxFrameBytes: number = DEFAULT_MAX_FRAME_BYTES) {
    if (!Number.isInteger(maxFrameBytes) || maxFrameBytes < 1) {
      throw new RangeError("maxFrameBytes must be a positive integer");
    }
    this.maxFrameBytes = maxFrameBytes;
  }

  get pendingBytes(): number {
    return this.bufferedBytes;
  }

  reset(): void {
    this.chunks = [];
    this.bufferedBytes = 0;
  }

  /**
   * Feed a raw byte chunk or UTF-8 string and return all complete non-empty frames.
   */
  push(input: Uint8Array | string): string[] {
    const data = typeof input === "string" ? textEncoder.encode(input) : input;
    if (data.byteLength === 0) return [];

    const frames: string[] = [];
    let sliceStart = 0;

    for (let i = 0; i < data.byteLength; i += 1) {
      if (data[i] !== 0x0a) continue; // '\n'

      const segment = data.subarray(sliceStart, i);
      const totalBytes = this.bufferedBytes + segment.byteLength;
      if (totalBytes > this.maxFrameBytes) {
        this.reset();
        throw new ZmuxFrameError(
          `NDJSON frame exceeds limit (${totalBytes} > ${this.maxFrameBytes} bytes)`,
          totalBytes,
        );
      }

      const combined = this.takeBufferedWith(segment, totalBytes);
      const trimmedLen =
        combined.byteLength > 0 && combined[combined.byteLength - 1] === 0x0d
          ? combined.byteLength - 1
          : combined.byteLength;
      if (trimmedLen > 0) {
        const line = textDecoder.decode(combined.subarray(0, trimmedLen));
        if (line.trim().length > 0) {
          frames.push(line);
        }
      }
      sliceStart = i + 1;
    }

    if (sliceStart < data.byteLength) {
      const remainder = data.subarray(sliceStart);
      const nextTotal = this.bufferedBytes + remainder.byteLength;
      if (nextTotal > this.maxFrameBytes) {
        this.reset();
        throw new ZmuxFrameError(
          `NDJSON incomplete frame exceeds limit (${nextTotal} > ${this.maxFrameBytes} bytes)`,
          nextTotal,
        );
      }
      // Copy remainder so callers reusing a read buffer cannot mutate pending state.
      const copy = new Uint8Array(remainder.byteLength);
      copy.set(remainder);
      this.chunks.push(copy);
      this.bufferedBytes = nextTotal;
    }

    return frames;
  }

  private takeBufferedWith(tail: Uint8Array, totalBytes: number): Uint8Array {
    if (this.chunks.length === 0) return tail;
    const out = new Uint8Array(totalBytes);
    let offset = 0;
    for (const chunk of this.chunks) {
      out.set(chunk, offset);
      offset += chunk.byteLength;
    }
    if (tail.byteLength > 0) {
      out.set(tail, offset);
    }
    this.chunks = [];
    this.bufferedBytes = 0;
    return out;
  }
}

const B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const B64_LOOKUP = (() => {
  const table = new Int16Array(128).fill(-1);
  for (let i = 0; i < B64_ALPHABET.length; i += 1) {
    table[B64_ALPHABET.charCodeAt(i)] = i;
  }
  return table;
})();

const hasNodeBuffer =
  typeof globalThis.Buffer === "function" && typeof globalThis.Buffer.from === "function";

/** Encode raw bytes into standard base64 (works identically in Node, Bun, and browsers). */
export function encodeBase64(bytes: Uint8Array): string {
  if (bytes.byteLength === 0) return "";
  if (hasNodeBuffer) {
    return globalThis.Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength).toString("base64");
  }
  let out = "";
  const len = bytes.byteLength;
  for (let i = 0; i < len; i += 3) {
    const b0 = bytes[i] ?? 0;
    const b1 = bytes[i + 1] ?? 0;
    const b2 = bytes[i + 2] ?? 0;
    const triplet = (b0 << 16) | (b1 << 8) | b2;
    out += B64_ALPHABET[(triplet >>> 18) & 63];
    out += B64_ALPHABET[(triplet >>> 12) & 63];
    out += i + 1 < len ? B64_ALPHABET[(triplet >>> 6) & 63] : "=";
    out += i + 2 < len ? B64_ALPHABET[triplet & 63] : "=";
  }
  return out;
}

/** Decode standard base64 into raw bytes (works identically in Node, Bun, and browsers). */
export function decodeBase64(encoded: string): Uint8Array {
  if (encoded.length === 0) return new Uint8Array(0);
  if (hasNodeBuffer) {
    const buf = globalThis.Buffer.from(encoded, "base64");
    return new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
  }
  const clean = encoded.replace(/[\r\n\s]/g, "");
  const pad = clean.endsWith("==") ? 2 : clean.endsWith("=") ? 1 : 0;
  const outLen = Math.max(0, Math.floor((clean.length * 3) / 4) - pad);
  const out = new Uint8Array(outLen);
  let pos = 0;
  for (let i = 0; i < clean.length; i += 4) {
    const c0 = B64_LOOKUP[clean.charCodeAt(i)] ?? 0;
    const c1 = B64_LOOKUP[clean.charCodeAt(i + 1)] ?? 0;
    const c2 = clean[i + 2] === "=" ? 0 : (B64_LOOKUP[clean.charCodeAt(i + 2)] ?? 0);
    const c3 = clean[i + 3] === "=" ? 0 : (B64_LOOKUP[clean.charCodeAt(i + 3)] ?? 0);
    const triplet = (c0 << 18) | (c1 << 12) | (c2 << 6) | c3;
    if (pos < outLen) out[pos++] = (triplet >>> 16) & 0xff;
    if (pos < outLen) out[pos++] = (triplet >>> 8) & 0xff;
    if (pos < outLen) out[pos++] = triplet & 0xff;
  }
  return out;
}
