# -*- coding: utf-8 -*-
"""Python side of the Swift<->Python bridge.

Loads a user-supplied Spider .py file, instantiates its `Spider` class and
exposes the standard TVBox interfaces as JSON-in / JSON-out calls.

Bridge contract (called from Swift):
    load_spider(path, extend_json)          -> {"ok": true} / {"ok": false, "error": "..."}
    call(method, args_json)                 -> JSON string of the spider's return value

The spider may return dicts directly (preferred) or JSON strings; both are
normalised here. Any exception is caught and returned as {"error": "..."}
so a broken source never crashes the shell.
"""
import importlib.util
import json
import sys
import traceback

_spider = None


def _to_jsonable(v):
    if isinstance(v, (dict, list, str, int, float, bool)) or v is None:
        return v
    return str(v)


def _normalise(ret):
    if ret is None:
        return {}
    if isinstance(ret, str):
        try:
            return json.loads(ret)
        except Exception:
            return {"result": ret}
    return _to_jsonable(ret)


def load_spider(path, extend_json=""):
    global _spider
    try:
        spec = importlib.util.spec_from_file_location("user_spider", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        cls = getattr(mod, "Spider", None)
        if cls is None:
            return json.dumps({"ok": False, "error": "py 文件里没有定义 class Spider"})
        _spider = cls()
        init = getattr(_spider, "init", None)
        if callable(init):
            try:
                init(extend_json or "")
            except TypeError:
                init()
        return json.dumps({"ok": True, "name": getattr(_spider, "getName", lambda: "Spider")()})
    except Exception:
        _spider = None
        return json.dumps({"ok": False, "error": traceback.format_exc(limit=3)})


# method -> positional arg order, mirroring the CatVod/TVBox spider protocol
_METHODS = {
    "homeContent": lambda a: _spider.homeContent(a.get("filter", True)),
    "homeVideoContent": lambda a: _spider.homeVideoContent(),
    "categoryContent": lambda a: _spider.categoryContent(
        a.get("tid", ""), a.get("pg", 1), a.get("filter", False), a.get("extend", {})),
    "detailContent": lambda a: _spider.detailContent(a.get("ids", [])),
    "searchContent": lambda a: _spider.searchContent(
        a.get("key", ""), a.get("quick", False), a.get("pg", 1)),
    "playerContent": lambda a: _spider.playerContent(
        a.get("flag", ""), a.get("id", ""), a.get("vipFlags", [])),
    "isVideoFormat": lambda a: _spider.isVideoFormat(a.get("url", "")),
    "manualVideoCheck": lambda a: _spider.manualVideoCheck(),
    "localProxy": lambda a: _spider.localProxy(a.get("params", {})),
    "destroy": lambda a: _spider.destroy(),
}


def call(method, args_json="{}"):
    if _spider is None:
        return json.dumps({"error": "spider not loaded"})
    fn = _METHODS.get(method)
    if fn is None:
        return json.dumps({"error": "unknown method: %s" % method})
    try:
        args = json.loads(args_json) if args_json else {}
        if not hasattr(_spider, method):
            return json.dumps({"error": "spider has no method: %s" % method})
        return json.dumps(_normalise(fn(args)), ensure_ascii=False)
    except Exception:
        return json.dumps({"error": traceback.format_exc(limit=3)})
