// libp2p's Stream is message-oriented (`send()`/`push()`), but nothing
// guarantees a receiver's delivered chunks line up 1:1 with the sender's
// `send()` calls — the underlying muxer is free to split or coalesce them.
// Automerge sync messages are variable-length and sometimes large (a full
// initial sync), so we frame them explicitly with a 4-byte length prefix
// rather than trust chunk boundaries.
export function encodeFrame(payload) {
  const header = Buffer.alloc(4);
  header.writeUInt32BE(payload.length, 0);
  return Buffer.concat([header, Buffer.from(payload)]);
}

export class FrameDecoder {
  #buffer = Buffer.alloc(0);

  // Feed in a raw chunk, get back zero or more complete frames.
  *push(chunk) {
    this.#buffer = Buffer.concat([this.#buffer, Buffer.from(chunk)]);
    while (this.#buffer.length >= 4) {
      const len = this.#buffer.readUInt32BE(0);
      if (this.#buffer.length < 4 + len) break;
      yield this.#buffer.subarray(4, 4 + len);
      this.#buffer = this.#buffer.subarray(4 + len);
    }
  }
}
