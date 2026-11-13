# -*- coding: utf-8 -*-
"""In-app bridge module for 呱壳's embedded Python runtime.

Loaded once by Swift (PythonRuntime) from pybundle.zip. Contract:

    ping()                                -> version string (diagnostics)
    load_spider(path, extend_json)        -> JSON {"ok": true, "name": ...}
    call(method, args_json)               -> JSON {"ok": true, "result": ...}

Every failure is returned as {"ok": false, "error": <traceback>} so a
broken spider shows its own error in the UI instead of crashing the
shell. Spider instances are cached per file path; `call` always acts
on the most recently loaded spider.
"""
import base64
import hashlib
import importlib.util
import json
import os
import platform
import sys
import traceback

_spiders = {}
_active_path = None

# Local proxy (v1.38): the app runs a loopback HTTP server and
# hands its base URL here; each loaded spider gets
# "<base>/<token>" bound as spider._proxy_base, which
# base.spider.getProxyUrl() returns. Requests to that URL are
# dispatched back into proxy_dispatch → spider.localProxy(params).
_proxy_base = ""
_proxy_tokens = {}


def set_proxy_base(base):
    global _proxy_base
    _proxy_base = base or ""
    for path, spider in list(_spiders.items()):
        _bind_proxy(spider, path)
    return json.dumps({"ok": True, "result": _proxy_base},
                      ensure_ascii=False)


def _bind_proxy(spider, path):
    if not _proxy_base:
        return
    token = hashlib.md5(path.encode("utf-8")).hexdigest()[:12]
    _proxy_tokens[token] = path
    try:
        spider._proxy_base = _proxy_base + "/" + token
    except Exception:
        pass


def proxy_dispatch(token, params_json):
    try:
        path = _proxy_tokens.get(token)
        if path is None:
            return json.dumps({"ok": False, "error": "未知的代理令牌"},
                              ensure_ascii=False)
        spider = _spiders.get(path)
        if spider is None:
            return json.dumps({"ok": False, "error": "蜘蛛未加载"},
                              ensure_ascii=False)
        fn = getattr(spider, "localProxy", None)
        if not callable(fn):
            return json.dumps({"ok": False, "error": "该蜘蛛没有 localProxy"},
                              ensure_ascii=False)
        params = json.loads(params_json or "{}")
        ret = fn(params)
        status, ctype, body, headers = 200, "application/octet-stream", b"", {}
        if isinstance(ret, (list, tuple)):
            if len(ret) > 0 and isinstance(ret[0], int):
                status = ret[0]
            if len(ret) > 1 and isinstance(ret[1], str):
                ctype = ret[1]
            if len(ret) > 2:
                body = ret[2]
            if len(ret) > 3 and isinstance(ret[3], dict):
                headers = {str(k): str(v) for k, v in ret[3].items()}
        elif isinstance(ret, (bytes, str)):
            body = ret
        if isinstance(body, str):
            payload = body.encode("utf-8")
        elif isinstance(body, (bytes, bytearray)):
            payload = bytes(body)
        else:
            payload = str(body).encode("utf-8")
        return json.dumps({"ok": True, "status": status, "type": ctype,
                           "headers": headers,
                           "body_b64": base64.b64encode(payload).decode("ascii")},
                          ensure_ascii=False)
    except Exception:
        return json.dumps({"ok": False,
                           "error": traceback.format_exc(limit=4)},
                          ensure_ascii=False)


def ping():
    return "Python " + platform.python_version()


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
    if isinstance(ret, dict):
        return {k: _to_jsonable(v) for k, v in ret.items()}
    return _to_jsonable(ret)


def load_spider(path, extend_json=""):
    global _active_path
    try:
        if path in _spiders:
            _active_path = path
            spider = _spiders[path]
            _bind_proxy(spider, path)
            return json.dumps({"ok": True, "name": _spider_name(spider)},
                              ensure_ascii=False)
        spec = importlib.util.spec_from_file_location(
            "user_spider_" + str(len(_spiders)), path)
        mod = importlib.util.module_from_spec(spec)
        spider_dir = os.path.dirname(path)
        if spider_dir and spider_dir not in sys.path:
            sys.path.insert(0, spider_dir)
        spec.loader.exec_module(mod)
        cls = getattr(mod, "Spider", None)
        if cls is None:
            return json.dumps({"ok": False,
                               "error": "py 文件里没有定义 class Spider"},
                              ensure_ascii=False)
        spider = cls()
        init = getattr(spider, "init", None)
        if callable(init):
            try:
                init(extend_json or "")
            except TypeError:
                init()
        _spiders[path] = spider
        _active_path = path
        _bind_proxy(spider, path)
        return json.dumps({"ok": True, "name": _spider_name(spider)},
                          ensure_ascii=False)
    except Exception:
        return json.dumps({"ok": False, "error": traceback.format_exc(limit=4)},
                          ensure_ascii=False)


def _spider_name(spider):
    try:
        return spider.getName()
    except Exception:
        return "Spider"


def call(method, args_json="{}"):
    try:
        spider = _spiders.get(_active_path)
        if spider is None:
            return json.dumps({"ok": False, "error": "尚未加载任何 Spider"},
                              ensure_ascii=False)
        args = json.loads(args_json or "{}")
        fn = getattr(spider, method, None)
        if fn is None:
            return json.dumps({"ok": False,
                               "error": "Spider 没有实现 " + method},
                              ensure_ascii=False)
        if method == "homeContent":
            ret = fn(bool(args.get("filter", False)))
        elif method == "homeVideoContent":
            ret = fn()
        elif method == "categoryContent":
            ret = fn(str(args.get("tid", "")), str(args.get("pg", "1")),
                     args.get("filter", {}), args.get("extend", {}))
        elif method == "detailContent":
            ret = fn(list(args.get("ids", [])))
        elif method == "searchContent":
            ret = fn(str(args.get("key", "")), bool(args.get("quick", False)),
                     str(args.get("pg", "1")))
        elif method == "playerContent":
            ret = fn(str(args.get("flag", "")), str(args.get("id", "")),
                     list(args.get("vipFlags", [])))
        elif method == "liveContent":
            ret = fn(str(args.get("url", "")))
        else:
            ret = fn()
        return json.dumps({"ok": True, "result": _normalise(ret)},
                          ensure_ascii=False, default=str)
    except Exception:
        return json.dumps({"ok": False, "error": traceback.format_exc(limit=4)},
                          ensure_ascii=False)
