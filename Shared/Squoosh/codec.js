// Runs Squoosh's codecs on raw RGBA data.
//   oxipng   – OxiPNG (Squoosh's PNG optimiser, via jSquash's build which exposes
//              `optimize_alpha`). Alpha optimisation is always OFF so the colours
//              of fully transparent pixels — the alpha bleed — survive.
//   quantize – libimagequant (Squoosh's "Reduce palette").
// Used by worker.js, or directly by engine.js when workers aren't available.

import initOxipng, { optimise_raw } from "./codecs/oxipng/squoosh_oxipng.js";
import imagequantFactory from "./codecs/imagequant/imagequant.js";

let imagequant = null;

export async function init(oxipngWasm, imagequantWasm) {
  await initOxipng(oxipngWasm);
  imagequant = await imagequantFactory({ wasmBinary: imagequantWasm });
}

function fromBase64(str) {
  if (Uint8Array.fromBase64) return Uint8Array.fromBase64(str);
  const bin = atob(str);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function toBase64(bytes) {
  if (bytes.toBase64) return bytes.toBase64();
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  }
  return btoa(bin);
}

/** Runs one job and returns the result as base64. */
export function run({ op, input, width, height, options }) {
  const rgba = new Uint8ClampedArray(fromBase64(input).buffer);
  if (rgba.length !== width * height * 4) throw new Error("Pixel buffer size mismatch");

  let result;
  if (op === "oxipng") {
    result = optimise_raw(rgba, width, height, options.level, false, false);
  } else if (op === "quantize") {
    result = imagequant.quantize(rgba, width, height, options.colors, options.dither);
  } else {
    throw new Error(`Unknown op ${op}`);
  }
  return toBase64(new Uint8Array(result.buffer, result.byteOffset, result.byteLength));
}
