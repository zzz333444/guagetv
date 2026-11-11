// drpy host parser globals (pdfh / pdfa / pd), cheerio-backed.
// Semantics follow the drpy/CatVod parser convention the engine's
// "jq" backend delegates to:
//   parse = selector [&& selector ...] [&& Text|Html|attribute]
// pdfa returns outer HTML of every match; pd = pdfh + URL resolution.
(function () {
  function load(html) {
    return cheerio.load(String(html == null ? "" : html), { decodeEntities: false }, false);
  }
  function isExtractor(part) {
    return part === "Text" || part === "Html" || /^[a-zA-Z_][\w-]*$/.test(part);
  }
  function splitChain(parse) {
    const parts = String(parse).split("&&").map(s => s.trim()).filter(s => s.length > 0);
    let extractor = null;
    if (parts.length >= 2 && isExtractor(parts[parts.length - 1])) {
      extractor = parts.pop();
    }
    return { selectors: parts, extractor };
  }
  function navigate($, selectors) {
    let set = null;
    for (const sel of selectors) {
      if (set === null) set = $(sel);
      else set = set.find(sel);
      if (!set || set.length === 0) break;
    }
    return set;
  }
  globalThis.pdfh = function (html, parse) {
    if (!html || !parse) return "";
    try {
      const $ = load(html);
      const { selectors, extractor } = splitChain(parse);
      const set = navigate($, selectors);
      if (!set || set.length === 0) return "";
      const el = set.first();
      if (extractor === "Text") return el.text() || "";
      if (extractor && extractor !== "Html") return el.attr(extractor) || "";
      return el.html() || "";
    } catch (e) {
      return "";
    }
  };
  globalThis.pdfa = function (html, parse) {
    if (!html || !parse) return [];
    try {
      const $ = load(html);
      const { selectors } = splitChain(parse);
      const set = navigate($, selectors);
      if (!set || set.length === 0) return [];
      const out = [];
      // NOTE: this cheerio build's static $.html(el) serializer is
      // broken (emits function source); $.xml(el) renders cleanly.
      set.each((_, el) => out.push($.xml(el)));
      return out;
    } catch (e) {
      return [];
    }
  };
  const URL_ATTR = /(url|src|href|-original|-src|-play|-url|style)$/i;
  function urljoin(base, rel) {
    if (!rel) return rel;
    if (/^(https?:)?\/\//i.test(rel) || /^(data:|magnet:|ftp:)/i.test(rel)) {
      return rel.startsWith("//") ? "https:" + rel : rel;
    }
    try {
      const b = new URL(rel, base);
      return b.href;
    } catch (e) { /* no URL global in JavaScriptCore: manual join below */ }
    const m = String(base || "").match(/^(https?:\/\/[^/]+)(\/.*)?$/i);
    if (!m) return rel;
    const origin = m[1];
    if (rel.startsWith("/")) return origin + rel;
    const dir = (m[2] || "/").replace(/[^/]*$/, "");
    let path = dir + rel;
    const parts = [];
    for (const seg of path.split("/")) {
      if (seg === "..") parts.pop();
      else if (seg !== "." && seg !== "") parts.push(seg);
    }
    return origin + "/" + parts.join("/");
  }
  // The engine's own urljoin() delegates to a host-provided joinUrl.
  globalThis.joinUrl = urljoin;
  globalThis.pd = function (html, parse, baseUrl) {
    const ret = globalThis.pdfh(html, parse);
    if (!ret) return ret;
    const tail = String(parse).split("&&").pop().trim();
    if (URL_ATTR.test(tail) || URL_ATTR.test(String(parse).trim())) {
      return urljoin(baseUrl || "", ret);
    }
    return ret;
  };
})();
