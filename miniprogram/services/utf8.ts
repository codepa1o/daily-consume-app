// 小程序运行环境不保证提供浏览器 TextDecoder，流式解码时保留跨包字符。
export class Utf8Decoder {
  private pending = new Uint8Array(0);

  decode(input?: ArrayBuffer, options: { stream?: boolean } = {}): string {
    const next = new Uint8Array(input ?? new ArrayBuffer(0));
    const bytes = new Uint8Array(this.pending.length + next.length);
    bytes.set(this.pending);
    bytes.set(next, this.pending.length);
    this.pending = new Uint8Array(0);
    let output = '';
    let index = 0;
    while (index < bytes.length) {
      const first = bytes[index];
      const length = first < 0x80 ? 1 : first >= 0xc2 && first <= 0xdf ? 2
        : first >= 0xe0 && first <= 0xef ? 3 : first >= 0xf0 && first <= 0xf4 ? 4 : 0;
      if (!length) throw new Error('无效的 UTF-8 字节');
      if (index + length > bytes.length) {
        if (!options.stream) throw new Error('不完整的 UTF-8 字符');
        this.pending = bytes.slice(index);
        break;
      }
      let code = first & (length === 1 ? 0x7f : length === 2 ? 0x1f : length === 3 ? 0x0f : 0x07);
      for (let offset = 1; offset < length; offset++) {
        const continuation = bytes[index + offset];
        if ((continuation & 0xc0) !== 0x80) throw new Error('无效的 UTF-8 连续字节');
        code = (code << 6) | (continuation & 0x3f);
      }
      if ((length === 2 && code < 0x80) || (length === 3 && code < 0x800)
          || (length === 4 && code < 0x10000) || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) {
        throw new Error('无效的 UTF-8 码点');
      }
      output += String.fromCodePoint(code);
      index += length;
    }
    return output;
  }
}
