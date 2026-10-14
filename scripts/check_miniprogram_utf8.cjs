// 验证中文及表情在任意网络分包位置都能正确还原。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const root = path.resolve(__dirname, '..');
const ts = require(path.join(root, 'miniprogram/node_modules/typescript'));
const source = path.join(root, 'miniprogram/services/utf8.ts');
const compiled = ts.transpileModule(fs.readFileSync(source, 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2019, module: ts.ModuleKind.CommonJS },
}).outputText;
const unit = new Module(source, module);
unit._compile(compiled, source);
const { Utf8Decoder } = unit.exports;
const message = 'event: message\ndata: {"内容":"中文🙂𠮷"}\n\n';
const bytes = new TextEncoder().encode(message);
for (let split = 0; split <= bytes.length; split++) {
  const decoder = new Utf8Decoder();
  assert.equal(decoder.decode(bytes.slice(0, split).buffer, { stream: true })
    + decoder.decode(bytes.slice(split).buffer, { stream: true }) + decoder.decode(), message);
}
const decoder = new Utf8Decoder();
assert.equal(Array.from(bytes, byte => decoder.decode(Uint8Array.of(byte).buffer, { stream: true })).join('')
  + decoder.decode(), message);
for (const invalid of [[0xc0, 0xaf], [0xe0, 0x80, 0x80], [0xed, 0xa0, 0x80], [0xf4, 0x90, 0x80, 0x80], [0xe4]]) {
  assert.throws(() => new Utf8Decoder().decode(Uint8Array.from(invalid).buffer));
}
console.log('UTF-8 streaming checks passed: every split, byte-by-byte and invalid input.');
