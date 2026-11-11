// Host prelude shared by the Node harness and the app's JSContext:
// TextEncoder/TextDecoder (UTF-8, pure JS — JavaScriptCore lacks them)
// and a minimal setTimeout queue drained by the bridge after each call.
if (typeof TextEncoder === "undefined") {
  globalThis.TextEncoder = class {
    encode(str) {
      const bytes = [];
      for (let i = 0; i < str.length; i++) {
        let cp = str.codePointAt(i);
        if (cp > 0xFFFF) i++;
        if (cp < 0x80) bytes.push(cp);
        else if (cp < 0x800) bytes.push(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F));
        else if (cp < 0x10000) bytes.push(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F));
        else bytes.push(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F));
      }
      return new Uint8Array(bytes);
    }
  };
}
if (typeof TextDecoder === "undefined") {
  globalThis.TextDecoder = class {
    decode(input) {
      const bytes = input instanceof Uint8Array ? input : new Uint8Array(input || []);
      let out = "", i = 0;
      while (i < bytes.length) {
        const b = bytes[i];
        let cp, len;
        if (b < 0x80) { cp = b; len = 1; }
        else if ((b & 0xE0) === 0xC0) { cp = b & 0x1F; len = 2; }
        else if ((b & 0xF0) === 0xE0) { cp = b & 0x0F; len = 3; }
        else if ((b & 0xF8) === 0xF0) { cp = b & 0x07; len = 4; }
        else { cp = 0xFFFD; len = 1; }
        if (len > 1) {
          if (i + len > bytes.length) { cp = 0xFFFD; len = 1; }
          else for (let k = 1; k < len; k++) cp = (cp << 6) | (bytes[i + k] & 0x3F);
        }
        out += String.fromCodePoint(cp);
        i += len;
      }
      return out;
    }
  };
}
const __timers = [];
if (typeof setTimeout === "undefined") {
  globalThis.setTimeout = (fn, ms) => { __timers.push(fn); return __timers.length; };
  globalThis.clearTimeout = (id) => { if (id >= 1 && id <= __timers.length) __timers[id - 1] = null; };
}
globalThis.__drainTimers = () => {
  let guard = 0;
  while (__timers.length && guard++ < 50) {
    const fn = __timers.shift();
    if (fn) { try { fn(); } catch (e) { console.log("timer error: " + e); } }
  }
};
