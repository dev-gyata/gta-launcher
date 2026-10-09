// wasm/platform/graphics/bc_decode.js
//
// BC1-BC7 block decoder for the GPU worker (wgpu_worker.js): graphics chips without WebGPU's texture-compression-bc (iPhones and
// A-chip iPads under WebKit, Adreno and Mali phones) get the game's BC textures uncompressed, decoded here as they are uploaded.
// BC1/2/3/7 -> rgba8 (4 bytes per texel), BC4 -> r8, BC5 -> rg8, BC6H (unsigned) -> rgba16float halves with alpha 1.0.
//
// A JavaScript port of bcdec.h v0.985 (https://github.com/iOrange/bcdec), MIT license:
//   Copyright (c) 2022 Sergii Kudlai
//   Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files
//   (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge,
//   publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so,
//   subject to the following conditions:
//   The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
//   MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR
//   ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH
//   THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//
// The BC6H mode layouts and the partition tables below are generated from bcdec.h: BC6H_MODES maps the mode bits (2 or 5) to
// [mode index, ops], each op = 5 numbers (channel 0-2 = r/g/b endpoint or 3 = partition, endpoint index, bit count, shift, reversed),
// read in order after the mode bits. BC7_P2/BC7_P3: 64 shapes x 16 texels, value = subset, +128 on the subset's anchor (fix-up) texel.
// BC6H uses the first 32 shapes of BC7_P2.

'use strict';

// one IIFE: importScripts puts top-level names into the worker's global scope, where wgpu_worker.js has its own
(function () {
const BC6H_MODES = {"0":[0,[1,2,1,4,0,2,2,1,4,0,2,3,1,4,0,0,0,10,0,0,1,0,10,0,0,2,0,10,0,0,0,1,5,0,0,1,3,1,4,0,1,2,4,0,0,1,1,5,0,0,2,3,1,0,0,1,3,4,0,0,2,1,5,0,0,2,3,1,1,0,2,2,4,0,0,0,2,5,0,0,2,3,1,2,0,0,3,5,0,0,2,3,1,3,0,3,0,5,0,0]],"1":[1,[1,2,1,5,0,1,3,1,4,0,1,3,1,5,0,0,0,7,0,0,2,3,1,0,0,2,3,1,1,0,2,2,1,4,0,1,0,7,0,0,2,2,1,5,0,2,3,1,2,0,1,2,1,4,0,2,0,7,0,0,2,3,1,3,0,2,3,1,5,0,2,3,1,4,0,0,1,6,0,0,1,2,4,0,0,1,1,6,0,0,1,3,4,0,0,2,1,6,0,0,2,2,4,0,0,0,2,6,0,0,0,3,6,0,0,3,0,5,0,0]],"2":[2,[0,0,10,0,0,1,0,10,0,0,2,0,10,0,0,0,1,5,0,0,0,0,1,10,0,1,2,4,0,0,1,1,4,0,0,1,0,1,10,0,2,3,1,0,0,1,3,4,0,0,2,1,4,0,0,2,0,1,10,0,2,3,1,1,0,2,2,4,0,0,0,2,5,0,0,2,3,1,2,0,0,3,5,0,0,2,3,1,3,0,3,0,5,0,0]],"3":[10,[0,0,10,0,0,1,0,10,0,0,2,0,10,0,0,0,1,10,0,0,1,1,10,0,0,2,1,10,0,0]],"6":[3,[0,0,10,0,0,1,0,10,0,0,2,0,10,0,0,0,1,4,0,0,0,0,1,10,0,1,3,1,4,0,1,2,4,0,0,1,1,5,0,0,1,0,1,10,0,1,3,4,0,0,2,1,4,0,0,2,0,1,10,0,2,3,1,1,0,2,2,4,0,0,0,2,4,0,0,2,3,1,0,0,2,3,1,2,0,0,3,4,0,0,1,2,1,4,0,2,3,1,3,0,3,0,5,0,0]],"7":[11,[0,0,10,0,0,1,0,10,0,0,2,0,10,0,0,0,1,9,0,0,0,0,1,10,0,1,1,9,0,0,1,0,1,10,0,2,1,9,0,0,2,0,1,10,0]],"10":[4,[0,0,10,0,0,1,0,10,0,0,2,0,10,0,0,0,1,4,0,0,0,0,1,10,0,2,2,1,4,0,1,2,4,0,0,1,1,4,0,0,1,0,1,10,0,2,3,1,0,0,1,3,4,0,0,2,1,5,0,0,2,0,1,10,0,2,2,4,0,0,0,2,4,0,0,2,3,1,1,0,2,3,1,2,0,0,3,4,0,0,2,3,1,4,0,2,3,1,3,0,3,0,5,0,0]],"11":[12,[0,0,10,0,0,1,0,10,0,0,2,0,10,0,0,0,1,8,0,0,0,0,2,10,1,1,1,8,0,0,1,0,2,10,1,2,1,8,0,0,2,0,2,10,1]],"14":[5,[0,0,9,0,0,2,2,1,4,0,1,0,9,0,0,1,2,1,4,0,2,0,9,0,0,2,3,1,4,0,0,1,5,0,0,1,3,1,4,0,1,2,4,0,0,1,1,5,0,0,2,3,1,0,0,1,3,4,0,0,2,1,5,0,0,2,3,1,1,0,2,2,4,0,0,0,2,5,0,0,2,3,1,2,0,0,3,5,0,0,2,3,1,3,0,3,0,5,0,0]],"15":[13,[0,0,10,0,0,1,0,10,0,0,2,0,10,0,0,0,1,4,0,0,0,0,6,10,1,1,1,4,0,0,1,0,6,10,1,2,1,4,0,0,2,0,6,10,1]],"18":[6,[0,0,8,0,0,1,3,1,4,0,2,2,1,4,0,1,0,8,0,0,2,3,1,2,0,1,2,1,4,0,2,0,8,0,0,2,3,1,3,0,2,3,1,4,0,0,1,6,0,0,1,2,4,0,0,1,1,5,0,0,2,3,1,0,0,1,3,4,0,0,2,1,5,0,0,2,3,1,1,0,2,2,4,0,0,0,2,6,0,0,0,3,6,0,0,3,0,5,0,0]],"22":[7,[0,0,8,0,0,2,3,1,0,0,2,2,1,4,0,1,0,8,0,0,1,2,1,5,0,1,2,1,4,0,2,0,8,0,0,1,3,1,5,0,2,3,1,4,0,0,1,5,0,0,1,3,1,4,0,1,2,4,0,0,1,1,6,0,0,1,3,4,0,0,2,1,5,0,0,2,3,1,1,0,2,2,4,0,0,0,2,5,0,0,2,3,1,2,0,0,3,5,0,0,2,3,1,3,0,3,0,5,0,0]],"26":[8,[0,0,8,0,0,2,3,1,1,0,2,2,1,4,0,1,0,8,0,0,2,2,1,5,0,1,2,1,4,0,2,0,8,0,0,2,3,1,5,0,2,3,1,4,0,0,1,5,0,0,1,3,1,4,0,1,2,4,0,0,1,1,5,0,0,2,3,1,0,0,1,3,4,0,0,2,1,6,0,0,2,2,4,0,0,0,2,5,0,0,2,3,1,2,0,0,3,5,0,0,2,3,1,3,0,3,0,5,0,0]],"30":[9,[0,0,6,0,0,1,3,1,4,0,2,3,1,0,0,2,3,1,1,0,2,2,1,4,0,1,0,6,0,0,1,2,1,5,0,2,2,1,5,0,2,3,1,2,0,1,2,1,4,0,2,0,6,0,0,1,3,1,5,0,2,3,1,3,0,2,3,1,5,0,2,3,1,4,0,0,1,6,0,0,1,2,4,0,0,1,1,6,0,0,1,3,4,0,0,2,1,6,0,0,2,2,4,0,0,0,2,6,0,0,0,3,6,0,0,3,0,5,0,0]]};
const BC7_P2 = new Uint8Array([128,0,1,1,0,0,1,1,0,0,1,1,0,0,1,129,128,0,0,1,0,0,0,1,0,0,0,1,0,0,0,129,128,1,1,1,0,1,1,1,0,1,1,1,0,1,1,129,128,0,0,1,0,0,1,1,0,0,1,1,0,1,1,129,128,0,0,0,0,0,0,1,0,0,0,1,0,0,1,129,128,0,1,1,0,1,1,1,0,1,1,1,1,1,1,129,128,0,0,1,0,0,1,1,0,1,1,1,1,1,1,129,128,0,0,0,0,0,0,1,0,0,1,1,0,1,1,129,128,0,0,0,0,0,0,0,0,0,0,1,0,0,1,129,128,0,1,1,0,1,1,1,1,1,1,1,1,1,1,129,128,0,0,0,0,0,0,1,0,1,1,1,1,1,1,129,128,0,0,0,0,0,0,0,0,0,0,1,0,1,1,129,128,0,0,1,0,1,1,1,1,1,1,1,1,1,1,129,128,0,0,0,0,0,0,0,1,1,1,1,1,1,1,129,128,0,0,0,1,1,1,1,1,1,1,1,1,1,1,129,128,0,0,0,0,0,0,0,0,0,0,0,1,1,1,129,128,0,0,0,1,0,0,0,1,1,1,0,1,1,1,129,128,1,129,1,0,0,0,1,0,0,0,0,0,0,0,0,128,0,0,0,0,0,0,0,129,0,0,0,1,1,1,0,128,1,129,1,0,0,1,1,0,0,0,1,0,0,0,0,128,0,129,1,0,0,0,1,0,0,0,0,0,0,0,0,128,0,0,0,1,0,0,0,129,1,0,0,1,1,1,0,128,0,0,0,0,0,0,0,129,0,0,0,1,1,0,0,128,1,1,1,0,0,1,1,0,0,1,1,0,0,0,129,128,0,129,1,0,0,0,1,0,0,0,1,0,0,0,0,128,0,0,0,1,0,0,0,129,0,0,0,1,1,0,0,128,1,129,0,0,1,1,0,0,1,1,0,0,1,1,0,128,0,129,1,0,1,1,0,0,1,1,0,1,1,0,0,128,0,0,1,0,1,1,1,129,1,1,0,1,0,0,0,128,0,0,0,1,1,1,1,129,1,1,1,0,0,0,0,128,1,129,1,0,0,0,1,1,0,0,0,1,1,1,0,128,0,129,1,1,0,0,1,1,0,0,1,1,1,0,0,128,1,0,1,0,1,0,1,0,1,0,1,0,1,0,129,128,0,0,0,1,1,1,1,0,0,0,0,1,1,1,129,128,1,0,1,1,0,129,0,0,1,0,1,1,0,1,0,128,0,1,1,0,0,1,1,129,1,0,0,1,1,0,0,128,0,129,1,1,1,0,0,0,0,1,1,1,1,0,0,128,1,0,1,0,1,0,1,129,0,1,0,1,0,1,0,128,1,1,0,1,0,0,1,0,1,1,0,1,0,0,129,128,1,0,1,1,0,1,0,1,0,1,0,0,1,0,129,128,1,129,1,0,0,1,1,1,1,0,0,1,1,1,0,128,0,0,1,0,0,1,1,129,1,0,0,1,0,0,0,128,0,129,1,0,0,1,0,0,1,0,0,1,1,0,0,128,0,129,1,1,0,1,1,1,1,0,1,1,1,0,0,128,1,129,0,1,0,0,1,1,0,0,1,0,1,1,0,128,0,1,1,1,1,0,0,1,1,0,0,0,0,1,129,128,1,1,0,0,1,1,0,1,0,0,1,1,0,0,129,128,0,0,0,0,1,129,0,0,1,1,0,0,0,0,0,128,1,0,0,1,1,129,0,0,1,0,0,0,0,0,0,128,0,129,0,0,1,1,1,0,0,1,0,0,0,0,0,128,0,0,0,0,0,129,0,0,1,1,1,0,0,1,0,128,0,0,0,0,1,0,0,129,1,1,0,0,1,0,0,128,1,1,0,1,1,0,0,1,0,0,1,0,0,1,129,128,0,1,1,0,1,1,0,1,1,0,0,1,0,0,129,128,1,129,0,0,0,1,1,1,0,0,1,1,1,0,0,128,0,129,1,1,0,0,1,1,1,0,0,0,1,1,0,128,1,1,0,1,1,0,0,1,1,0,0,1,0,0,129,128,1,1,0,0,0,1,1,0,0,1,1,1,0,0,129,128,1,1,1,1,1,1,0,1,0,0,0,0,0,0,129,128,0,0,1,1,0,0,0,1,1,1,0,0,1,1,129,128,0,0,0,1,1,1,1,0,0,1,1,0,0,1,129,128,0,129,1,0,0,1,1,1,1,1,1,0,0,0,0,128,0,129,0,0,0,1,0,1,1,1,0,1,1,1,0,128,1,0,0,0,1,0,0,0,1,1,1,0,1,1,129]);
const BC7_P3 = new Uint8Array([128,0,1,129,0,0,1,1,0,2,2,1,2,2,2,130,128,0,0,129,0,0,1,1,130,2,1,1,2,2,2,1,128,0,0,0,2,0,0,1,130,2,1,1,2,2,1,129,128,2,2,130,0,0,2,2,0,0,1,1,0,1,1,129,128,0,0,0,0,0,0,0,129,1,2,2,1,1,2,130,128,0,1,129,0,0,1,1,0,0,2,2,0,0,2,130,128,0,2,130,0,0,2,2,1,1,1,1,1,1,1,129,128,0,1,1,0,0,1,1,130,2,1,1,2,2,1,129,128,0,0,0,0,0,0,0,129,1,1,1,2,2,2,130,128,0,0,0,1,1,1,1,129,1,1,1,2,2,2,130,128,0,0,0,1,1,129,1,2,2,2,2,2,2,2,130,128,0,1,2,0,0,129,2,0,0,1,2,0,0,1,130,128,1,1,2,0,1,129,2,0,1,1,2,0,1,1,130,128,1,2,2,0,129,2,2,0,1,2,2,0,1,2,130,128,0,1,129,0,1,1,2,1,1,2,2,1,2,2,130,128,0,1,129,2,0,0,1,130,2,0,0,2,2,2,0,128,0,0,129,0,0,1,1,0,1,1,2,1,1,2,130,128,1,1,129,0,0,1,1,130,0,0,1,2,2,0,0,128,0,0,0,1,1,2,2,129,1,2,2,1,1,2,130,128,0,2,130,0,0,2,2,0,0,2,2,1,1,1,129,128,1,1,129,0,1,1,1,0,2,2,2,0,2,2,130,128,0,0,129,0,0,0,1,130,2,2,1,2,2,2,1,128,0,0,0,0,0,129,1,0,1,2,2,0,1,2,130,128,0,0,0,1,1,0,0,130,2,129,0,2,2,1,0,128,1,2,130,0,129,2,2,0,0,1,1,0,0,0,0,128,0,1,2,0,0,1,2,129,1,2,2,2,2,2,130,128,1,1,0,1,2,130,1,129,2,2,1,0,1,1,0,128,0,0,0,0,1,129,0,1,2,130,1,1,2,2,1,128,0,2,2,1,1,0,2,129,1,0,2,0,0,2,130,128,1,1,0,0,129,1,0,2,0,0,2,2,2,2,130,128,0,1,1,0,1,2,2,0,1,130,2,0,0,1,129,128,0,0,0,2,0,0,0,130,2,1,1,2,2,2,129,128,0,0,0,0,0,0,2,129,1,2,2,1,2,2,130,128,2,2,130,0,0,2,2,0,0,1,2,0,0,1,129,128,0,1,129,0,0,1,2,0,0,2,2,0,2,2,130,128,1,2,0,0,129,2,0,0,1,130,0,0,1,2,0,128,0,0,0,1,1,129,1,2,2,130,2,0,0,0,0,128,1,2,0,1,2,0,1,130,0,129,2,0,1,2,0,128,1,2,0,2,0,1,2,129,130,0,1,0,1,2,0,128,0,1,1,2,2,0,0,1,1,130,2,0,0,1,129,128,0,1,1,1,1,130,2,2,2,0,0,0,0,1,129,128,1,0,129,0,1,0,1,2,2,2,2,2,2,2,130,128,0,0,0,0,0,0,0,130,1,2,1,2,1,2,129,128,0,2,2,1,129,2,2,0,0,2,2,1,1,2,130,128,0,2,130,0,0,1,1,0,0,2,2,0,0,1,129,128,2,2,0,1,2,130,1,0,2,2,0,1,2,2,129,128,1,0,1,2,2,130,2,2,2,2,2,0,1,0,129,128,0,0,0,2,1,2,1,130,1,2,1,2,1,2,129,128,1,0,129,0,1,0,1,0,1,0,1,2,2,2,130,128,2,2,130,0,1,1,1,0,2,2,2,0,1,1,129,128,0,0,2,1,129,1,2,0,0,0,2,1,1,1,130,128,0,0,0,2,129,1,2,2,1,1,2,2,1,1,130,128,2,2,2,0,129,1,1,0,1,1,1,0,2,2,130,128,0,0,2,1,1,1,2,129,1,1,2,0,0,0,130,128,1,1,0,0,129,1,0,0,1,1,0,2,2,2,130,128,0,0,0,0,0,0,0,2,1,129,2,2,1,1,130,128,1,1,0,0,129,1,0,2,2,2,2,2,2,2,130,128,0,2,2,0,0,1,1,0,0,129,1,0,0,2,130,128,0,2,2,1,1,2,2,129,1,2,2,0,0,2,130,128,0,0,0,0,0,0,0,0,0,0,0,2,129,1,130,128,0,0,130,0,0,0,1,0,0,0,2,0,0,0,129,128,2,2,2,1,2,2,2,0,2,2,2,129,2,2,130,128,1,0,129,2,2,2,2,2,2,2,2,2,2,2,130,128,1,1,129,2,0,1,1,130,2,0,1,2,2,2,0]);

const W2 = [0, 21, 43, 64], W3 = [0, 9, 18, 27, 37, 46, 55, 64], W4 = [0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64];
const BC6H_BITS = [[10, 7, 11, 11, 11, 9, 8, 8, 8, 6, 10, 11, 12, 16], [5, 6, 5, 4, 4, 5, 6, 5, 5, 6, 10, 9, 8, 4], [5, 6, 4, 5, 4, 5, 5, 6, 5, 6, 10, 9, 8, 4], [5, 6, 4, 4, 5, 5, 5, 5, 6, 6, 10, 9, 8, 4]];
const BC7_COLOR_BITS = [4, 6, 5, 7, 5, 7, 7, 5], BC7_ALPHA_BITS = [0, 0, 0, 0, 6, 8, 7, 5], BC7_PBITS = 0b11001011;

// 128-bit little-endian bit reader over one block (bits are pulled from the low end, as bcdec's bitstream)
const bw = new Uint32Array(5);
let bpos = 0;
function bsInit(s, o) {
	for (let i = 0; i < 4; i++, o += 4) bw[i] = (s[o] | (s[o + 1] << 8) | (s[o + 2] << 16) | (s[o + 3] << 24)) >>> 0;
	bpos = 0;
}
function bits(n) {
	const i = bpos >>> 5, sh = bpos & 31;
	let v = bw[i] >>> sh;
	if (sh + n > 32) v |= bw[i + 1] << (32 - sh);
	bpos += n;
	return v & ((1 << n) - 1);
}
function bitsReversed(n) {
	let v = bits(n), r = 0;
	while (n--) { r = (r << 1) | (v & 1); v >>= 1; }
	return r;
}

// One decoded 4x4 block, row-major: rgba8 (also r8/rg8, packed at the texel size) or rgba16f halves
const blk8 = new Uint8Array(64), blk16 = new Uint16Array(64);
const ref = new Uint8Array(16), alpha = new Uint8Array(8);

// BC1 color part at s[o..o+8] into blk8 (stride 4); opaque: BC2/BC3 always use the 4-color mode
function colorBlock(s, o, opaque) {
	const c0 = s[o] | (s[o + 1] << 8), c1 = s[o + 2] | (s[o + 3] << 8);
	const r0 = (c0 >> 11) & 31, g0 = (c0 >> 5) & 63, b0 = c0 & 31, r1 = (c1 >> 11) & 31, g1 = (c1 >> 5) & 63, b1 = c1 & 31;
	ref[0] = (r0 * 527 + 23) >> 6; ref[1] = (g0 * 259 + 33) >> 6; ref[2] = (b0 * 527 + 23) >> 6; ref[3] = 255;
	ref[4] = (r1 * 527 + 23) >> 6; ref[5] = (g1 * 259 + 33) >> 6; ref[6] = (b1 * 527 + 23) >> 6; ref[7] = 255;
	if (c0 > c1 || opaque) {
		ref[8] = ((2 * r0 + r1) * 351 + 61) >> 7; ref[9] = ((2 * g0 + g1) * 2763 + 1039) >> 11; ref[10] = ((2 * b0 + b1) * 351 + 61) >> 7; ref[11] = 255;
		ref[12] = ((r0 + r1 * 2) * 351 + 61) >> 7; ref[13] = ((g0 + g1 * 2) * 2763 + 1039) >> 11; ref[14] = ((b0 + b1 * 2) * 351 + 61) >> 7; ref[15] = 255;
	} else {
		ref[8] = ((r0 + r1) * 1053 + 125) >> 8; ref[9] = ((g0 + g1) * 4145 + 1019) >> 11; ref[10] = ((b0 + b1) * 1053 + 125) >> 8; ref[11] = 255;
		ref[12] = 0; ref[13] = 0; ref[14] = 0; ref[15] = 0;
	}
	let idx = (s[o + 4] | (s[o + 5] << 8) | (s[o + 6] << 16) | (s[o + 7] << 24)) >>> 0;
	for (let t = 0; t < 64; t += 4, idx >>>= 2) {
		const k = (idx & 3) << 2;
		blk8[t] = ref[k]; blk8[t + 1] = ref[k + 1]; blk8[t + 2] = ref[k + 2]; blk8[t + 3] = ref[k + 3];
	}
}
// BC2 explicit 4-bit alpha into blk8 byte 3 of each texel
function sharpAlpha(s, o) {
	for (let t = 0; t < 16; t++) blk8[t * 4 + 3] = ((s[o + (t >> 1)] >> ((t & 1) * 4)) & 15) * 17;
}
// BC3 alpha / BC4 / BC5 channel: 8 bytes at s[o..] into blk8 at byte `off` of each texel, `step` bytes per texel
function smoothAlpha(s, o, off, step) {
	const a0 = s[o], a1 = s[o + 1];
	alpha[0] = a0; alpha[1] = a1;
	if (a0 > a1) {
		alpha[2] = (6 * a0 + a1) / 7 | 0; alpha[3] = (5 * a0 + 2 * a1) / 7 | 0; alpha[4] = (4 * a0 + 3 * a1) / 7 | 0;
		alpha[5] = (3 * a0 + 4 * a1) / 7 | 0; alpha[6] = (2 * a0 + 5 * a1) / 7 | 0; alpha[7] = (a0 + 6 * a1) / 7 | 0;
	} else {
		alpha[2] = (4 * a0 + a1) / 5 | 0; alpha[3] = (3 * a0 + 2 * a1) / 5 | 0; alpha[4] = (2 * a0 + 3 * a1) / 5 | 0;
		alpha[5] = (a0 + 4 * a1) / 5 | 0; alpha[6] = 0; alpha[7] = 255;
	}
	// 48 index bits: two 24-bit halves (8 texels each)
	let lo = s[o + 2] | (s[o + 3] << 8) | (s[o + 4] << 16), hi = s[o + 5] | (s[o + 6] << 8) | (s[o + 7] << 16);
	for (let t = 0; t < 8; t++, lo >>= 3) blk8[t * step + off] = alpha[lo & 7];
	for (let t = 8; t < 16; t++, hi >>= 3) blk8[t * step + off] = alpha[hi & 7];
}

const ep = new Int32Array(24);		// BC7: 6 endpoints x rgba; BC6H: r[4], g[4], b[4] at 0/4/8
const ind = new Uint8Array(16);

function bc7Block(s, o) {
	bsInit(s, o);
	let mode = 0;
	while (mode < 8 && bits(1) === 0) mode++;
	if (mode >= 8) { blk8.fill(0); return; }		// reserved mode: transparent black
	let partition = 0, nParts = 1, rotation = 0, isb = 0;
	if (mode === 0 || mode === 1 || mode === 2 || mode === 3 || mode === 7) { nParts = mode === 0 || mode === 2 ? 3 : 2; partition = bits(mode === 0 ? 4 : 6); }
	const nEp = nParts * 2, cb = BC7_COLOR_BITS[mode], ab = BC7_ALPHA_BITS[mode];
	if (mode === 4 || mode === 5) { rotation = bits(2); if (mode === 4) isb = bits(1); }
	for (let c = 0; c < 3; c++) for (let e = 0; e < nEp; e++) ep[e * 4 + c] = bits(cb);
	if (ab) for (let e = 0; e < nEp; e++) ep[e * 4 + 3] = bits(ab);
	const hasP = (BC7_PBITS >> mode) & 1;
	if (hasP) {
		for (let i = 0; i < nEp * 4; i++) ep[i] <<= 1;
		if (mode === 1) {
			const p0 = bits(1), p1 = bits(1);
			for (let c = 0; c < 3; c++) { ep[c] |= p0; ep[4 + c] |= p0; ep[8 + c] |= p1; ep[12 + c] |= p1; }
		} else {
			for (let e = 0; e < nEp; e++) { const p = bits(1); for (let c = 0; c < 4; c++) ep[e * 4 + c] |= p; }
		}
	}
	const cbits = cb + hasP, abits = ab + hasP;
	for (let e = 0; e < nEp; e++) {
		for (let c = 0; c < 3; c++) { const v = ep[e * 4 + c] << (8 - cbits); ep[e * 4 + c] = v | (v >> cbits); }
		if (ab) { const v = ep[e * 4 + 3] << (8 - abits); ep[e * 4 + 3] = v | (v >> abits); } else ep[e * 4 + 3] = 255;
	}
	const ib = mode === 0 || mode === 1 ? 3 : mode === 6 ? 4 : 2, ib2 = mode === 4 ? 3 : mode === 5 ? 2 : 0;
	const wt = ib === 2 ? W2 : ib === 3 ? W3 : W4, wt2 = ib2 === 2 ? W2 : W3;
	const table = nParts === 3 ? BC7_P3 : BC7_P2, tbase = partition * 16;
	for (let t = 0; t < 16; t++) {
		const ps = nParts === 1 ? (t ? 0 : 128) : table[tbase + t];
		ind[t] = bits(ps & 128 ? ib - 1 : ib);
	}
	for (let t = 0; t < 16; t++) {
		const set = nParts === 1 ? 0 : table[tbase + t] & 3, e0 = set * 8, e1 = e0 + 4;
		let i1 = ind[t], w1 = wt, i2 = i1, w2 = wt;		// color index/weights, alpha index/weights
		if (ib2) {
			const i2b = bits(t ? ib2 : ib2 - 1);
			if (isb) { i1 = i2b; w1 = wt2; i2 = ind[t]; w2 = wt; } else { i2 = i2b; w2 = wt2; }
		}
		const f1 = w1[i1], f2 = w2[i2];
		let r = (ep[e0] * (64 - f1) + ep[e1] * f1 + 32) >> 6, g = (ep[e0 + 1] * (64 - f1) + ep[e1 + 1] * f1 + 32) >> 6,
			b = (ep[e0 + 2] * (64 - f1) + ep[e1 + 2] * f1 + 32) >> 6, a = (ep[e0 + 3] * (64 - f2) + ep[e1 + 3] * f2 + 32) >> 6;
		if (rotation === 1) { const x = a; a = r; r = x; } else if (rotation === 2) { const x = a; a = g; g = x; } else if (rotation === 3) { const x = a; a = b; b = x; }
		blk8[t * 4] = r; blk8[t * 4 + 1] = g; blk8[t * 4 + 2] = b; blk8[t * 4 + 3] = a;
	}
}

// BC6H unsigned (BC6H_UF16) into blk16 as rgba16f halves, alpha 1.0
const extendSign = (v, n) => (v << (32 - n)) >> (32 - n);
function unq6(v, n) { return n >= 15 ? v : !v ? 0 : v === (1 << n) - 1 ? 0xffff : ((v << 16) + 0x8000) >> n; }
function bc6hBlock(s, o) {
	bsInit(s, o);
	let code = bits(2);
	if (code > 1) code |= bits(3) << 2;
	const m = BC6H_MODES[code];
	if (!m) { for (let t = 0; t < 16; t++) { blk16[t * 4] = 0; blk16[t * 4 + 1] = 0; blk16[t * 4 + 2] = 0; blk16[t * 4 + 3] = 0x3c00; } return; }
	const mode = m[0], ops = m[1];
	ep.fill(0, 0, 12);
	let partition = 0;
	for (let i = 0; i < ops.length; i += 5) {
		const ch = ops[i], n = ops[i + 2];
		const v = ops[i + 4] ? bitsReversed(n) : bits(n);
		if (ch === 3) partition = v; else ep[ch * 4 + ops[i + 1]] |= v << ops[i + 3];
	}
	const two = mode < 10, nEp = two ? 4 : 2, wb = BC6H_BITS[0][mode];
	if (mode !== 9 && mode !== 10) {
		for (let e = 1; e < nEp; e++) for (let c = 0; c < 3; c++) {
			const d = extendSign(ep[c * 4 + e], BC6H_BITS[c + 1][mode]);
			ep[c * 4 + e] = (d + ep[c * 4]) & ((1 << wb) - 1);		// delta from endpoint 0, at endpoint 0's precision
		}
	}
	for (let e = 0; e < nEp; e++) for (let c = 0; c < 3; c++) ep[c * 4 + e] = unq6(ep[c * 4 + e], wb);
	const wt = two ? W3 : W4, ib = two ? 3 : 4, tbase = partition * 16;
	for (let t = 0; t < 16; t++) {
		const ps = two ? BC7_P2[tbase + t] : (t ? 0 : 128);
		const f = wt[bits(ps & 128 ? ib - 1 : ib)], e0 = (ps & 1) * 2;
		for (let c = 0; c < 3; c++) blk16[t * 4 + c] = (((ep[c * 4 + e0] * (64 - f) + ep[c * 4 + e0 + 1] * f + 32) >> 6) * 31) >> 6;
		blk16[t * 4 + 3] = 0x3c00;
	}
}

const BC_BLOCK_BYTES = { bc1: 8, bc2: 16, bc3: 16, bc4: 8, bc5: 16, bc6h: 16, bc7: 16 };
const BC_TEXEL_BYTES = { bc1: 4, bc2: 4, bc3: 4, bc4: 1, bc5: 2, bc6h: 8, bc7: 4 };

// Decodes a w x h texel region of one image: `src` rows of blocks `srcBpr` bytes apart from `srcOff`, into `out` (Uint8Array, even
// byteOffset) rows `outBpr` bytes apart. w/h may stop inside the last block column/row (mips under 4x4, regions at the edge).
function decodeBC(kind, src, srcOff, srcBpr, w, h, out, outBpr) {
	const bb = BC_BLOCK_BYTES[kind], tb = BC_TEXEL_BYTES[kind], wide = kind === 'bc6h';
	const out16 = wide ? new Uint16Array(out.buffer, out.byteOffset, out.byteLength >> 1) : null;
	const src8 = blk8;
	for (let by = 0; by * 4 < h; by++) {
		for (let bx = 0; bx * 4 < w; bx++) {
			const o = srcOff + by * srcBpr + bx * bb;
			switch (kind) {
			case 'bc1': colorBlock(src, o, false); break;
			case 'bc2': colorBlock(src, o + 8, true); sharpAlpha(src, o); break;
			case 'bc3': colorBlock(src, o + 8, true); smoothAlpha(src, o, 3, 4); break;
			case 'bc4': smoothAlpha(src, o, 0, 1); break;
			case 'bc5': smoothAlpha(src, o, 0, 2); smoothAlpha(src, o + 8, 1, 2); break;
			case 'bc6h': bc6hBlock(src, o); break;
			case 'bc7': bc7Block(src, o); break;
			}
			const cw = Math.min(4, w - bx * 4), ch = Math.min(4, h - by * 4);
			for (let y = 0; y < ch; y++) {
				const d = (by * 4 + y) * outBpr + bx * 4 * tb;
				if (wide) out16.set(blk16.subarray(y * 16, y * 16 + cw * 4), d >> 1);
				else out.set(src8.subarray(y * 4 * tb, (y * 4 + cw) * tb), d);
			}
		}
	}
}

const api = { decodeBC, BC_BLOCK_BYTES, BC_TEXEL_BYTES };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
else globalThis.BCDecode = api;
})();
