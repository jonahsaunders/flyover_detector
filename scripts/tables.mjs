import { mkdirSync, writeFileSync } from 'node:fs';

const size = 4096;
const encode = value => BigInt(Math.round(value * 65536)) & 0x3ffffn;
const twiddle = [];
const window = [];
for (let index = 0; index < size; index++) {
  const angle = 2 * Math.PI * index / size;
  if (index < size / 2) {
    const bits = (encode(Math.cos(angle)) << 18n) | encode(-Math.sin(angle));
    twiddle.push(bits.toString(16).padStart(9, '0'));
    window.push(encode(0.5 - 0.5 * Math.cos(angle)).toString(16).padStart(5, '0'));
  }
}
mkdirSync('tables', { recursive: true });
writeFileSync('tables/twiddle.mem', twiddle.join('\n') + '\n');
writeFileSync('tables/hann.mem', window.join('\n') + '\n');
