import Foundation

/// JavaScript for Follow the Leader mode (record actions in the leader
/// window, replay them in followers) and for session save/load (capture and
/// restore localStorage / sessionStorage). Cookies are handled natively via
/// `WKHTTPCookieStore`; these scripts cover only the in-page pieces.
extension JavaScriptInjectionService {

    // MARK: - Follow the Leader — recorder (leader window only)

    /// Installs capture-phase listeners that post each user action
    /// (click, input, checkbox/radio change, form submit, scroll) to the
    /// native `followLeader` message handler. Idempotent: re-running only
    /// re-arms the active flag, so it is safe to call on every page load.
    /// Posting is gated behind `__ffb_flActive` so disabling the mode stops
    /// events without needing to remove listeners.
    static func followLeaderRecorderScript() -> String {
        return """
        (function() {
            window.__ffb_flActive = true;
            if (window.__ffb_flRecorder) { return JSON.stringify({ installed: true, already: true }); }
            window.__ffb_flRecorder = true;

            var esc = function(s) {
                try { return (window.CSS && CSS.escape) ? CSS.escape(s) : String(s).replace(/[^a-zA-Z0-9_-]/g, '\\\\$&'); }
                catch (e) { return String(s); }
            };
            var cssPath = function(el) {
                if (!el || el.nodeType !== 1) return null;
                if (el === document.body) return 'body';
                var parts = [];
                var node = el;
                while (node && node.nodeType === 1 && parts.length < 25) {
                    var sel = node.nodeName.toLowerCase();
                    if (node.id) { parts.unshift(sel + '#' + esc(node.id)); break; }
                    var parent = node.parentNode;
                    if (!parent || parent.nodeType !== 1) { parts.unshift(sel); break; }
                    var kids = parent.children;
                    var sameTag = 0, idx = 0;
                    for (var i = 0; i < kids.length; i++) {
                        if (kids[i].nodeName === node.nodeName) { sameTag++; if (kids[i] === node) idx = sameTag; }
                    }
                    if (sameTag > 1) { sel += ':nth-of-type(' + idx + ')'; }
                    parts.unshift(sel);
                    node = parent;
                }
                return parts.join(' > ');
            };
            var post = function(obj) {
                if (!window.__ffb_flActive) return;
                try {
                    if (window.webkit && webkit.messageHandlers && webkit.messageHandlers.followLeader) {
                        webkit.messageHandlers.followLeader.postMessage(obj);
                    }
                } catch (e) {}
            };

            document.addEventListener('click', function(e) {
                var p = cssPath(e.target);
                if (p) post({ kind: 'click', selector: p });
            }, true);

            // Input is debounced per-field so rapid typing coalesces to the
            // settled value instead of flooding followers with a fill per
            // keystroke (each follower fill verifies + retries).
            var inputTimers = {};
            document.addEventListener('input', function(e) {
                var t = e.target; if (!t) return;
                var p = cssPath(t); if (!p) return;
                if (inputTimers[p]) { clearTimeout(inputTimers[p]); }
                inputTimers[p] = setTimeout(function() {
                    delete inputTimers[p];
                    post({ kind: 'input', selector: p, value: (t.value != null ? String(t.value) : '') });
                }, 300);
            }, true);

            document.addEventListener('change', function(e) {
                var t = e.target; if (!t) return;
                if (t.type === 'checkbox' || t.type === 'radio') {
                    var p = cssPath(t); if (p) post({ kind: 'check', selector: p, checked: !!t.checked });
                } else if (t.tagName === 'SELECT') {
                    var p2 = cssPath(t); if (p2) post({ kind: 'input', selector: p2, value: (t.value != null ? String(t.value) : '') });
                }
            }, true);

            document.addEventListener('submit', function(e) {
                var p = cssPath(e.target);
                if (p) post({ kind: 'submit', selector: p });
            }, true);

            var lastScroll = 0;
            window.addEventListener('scroll', function() {
                var now = Date.now();
                if (now - lastScroll < 250) return;
                lastScroll = now;
                post({ kind: 'scroll', x: Math.round(window.scrollX || 0), y: Math.round(window.scrollY || 0) });
            }, true);

            return JSON.stringify({ installed: true });
        })();
        """
    }

    /// Stops the leader recorder from posting further actions.
    static func followLeaderDisableScript() -> String {
        "window.__ffb_flActive = false;"
    }

    // MARK: - Follow the Leader — best-effort replay (scroll only)

    /// Builds the JS that replays a scroll in a follower window. Fills,
    /// clicks, checks, and submits use the verified async engine below
    /// instead; only scroll stays fire-and-forget.
    static func followLeaderReplayScript(kind: String, payload: [String: Any]) -> String? {
        switch kind {
        case "scroll":
            let x = (payload["x"] as? NSNumber)?.intValue ?? Int(payload["x"] as? Double ?? 0)
            let y = (payload["y"] as? NSNumber)?.intValue ?? Int(payload["y"] as? Double ?? 0)
            return """
            (function(){ try { window.scrollTo(\(x), \(y)); } catch(e){} })();
            """
        default:
            return nil
        }
    }

    // MARK: - Follow the Leader — verified multi-fallback engine
    //
    // These bodies are executed with `callAsyncJavaScript` (they use `await`
    // and `return` a result object). Each tries several techniques in turn
    // and reads the page back to confirm the action actually landed, so a
    // hidden follower never silently misses a fill or a button press.

    /// Fills `sel` with `value`, trying native setter -> char-by-char ->
    /// execCommand -> plain assignment, verifying `el.value === value` after
    /// each. Waits for the field to appear first. Args: `sel`, `value`.
    static func followLeaderFillBody() -> String {
        return """
        const timeoutMs = 4000;
        const start = Date.now();
        let el = null;
        while (Date.now() - start < timeoutMs) {
            try { el = document.querySelector(sel); } catch (e) { el = null; }
            if (el) break;
            await new Promise(function(r){ setTimeout(r, 120); });
        }
        if (!el) { return { ok: false, found: false, method: -1 }; }
        function nativeSet(element, val) {
            try {
                var proto = (window.HTMLTextAreaElement && element instanceof HTMLTextAreaElement)
                    ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
                var desc = Object.getOwnPropertyDescriptor(proto, 'value');
                if (desc && desc.set) { desc.set.call(element, val); } else { element.value = val; }
            } catch (e) { try { element.value = val; } catch (e2) {} }
        }
        function fire(element) {
            try { element.dispatchEvent(new Event('input', { bubbles: true })); } catch (e) {}
            try { element.dispatchEvent(new InputEvent('input', { bubbles: true, data: '', inputType: 'insertText' })); } catch (e) {}
            try { element.dispatchEvent(new Event('change', { bubbles: true })); } catch (e) {}
            try { element.dispatchEvent(new Event('keyup', { bubbles: true })); } catch (e) {}
        }
        function ok() { try { return el.value === value; } catch (e) { return false; } }

        try { el.focus({ preventScroll: true }); } catch (e) {}
        nativeSet(el, value); fire(el);
        await new Promise(function(r){ setTimeout(r, 50); });
        if (ok()) return { ok: true, found: true, method: 0 };

        try { el.focus(); } catch (e) {}
        nativeSet(el, ''); fire(el);
        for (var i = 0; i < value.length && i < 240; i++) {
            nativeSet(el, value.slice(0, i + 1));
            try { el.dispatchEvent(new Event('input', { bubbles: true })); } catch (e) {}
            await new Promise(function(r){ setTimeout(r, 6); });
        }
        fire(el);
        if (ok()) return { ok: true, found: true, method: 1 };

        try {
            el.focus();
            try { el.select && el.select(); } catch (e) {}
            try { document.execCommand('selectAll', false, null); } catch (e) {}
            try { document.execCommand('insertText', false, value); } catch (e) {}
            fire(el);
        } catch (e) {}
        if (ok()) return { ok: true, found: true, method: 2 };

        try { el.value = value; } catch (e) {}
        try { el.setAttribute('value', value); } catch (e) {}
        fire(el);
        return { ok: ok(), found: true, method: 3 };
        """
    }

    /// Presses `sel`, trying click -> pointer/mouse sequence -> Enter key ->
    /// form submit, watching for a navigation / DOM change after each so it
    /// stops as soon as the press registers. Waits for the element first.
    /// Arg: `sel`.
    static func followLeaderClickBody() -> String {
        return """
        const timeoutMs = 3000;
        const start = Date.now();
        let el = null;
        function visible(x) {
            if (!x) return false;
            if (x.offsetParent !== null) return true;
            try { var r = x.getBoundingClientRect(); return !!(r && r.width > 0 && r.height > 0); } catch (e) { return false; }
        }
        while (Date.now() - start < timeoutMs) {
            try { el = document.querySelector(sel); } catch (e) { el = null; }
            if (el && visible(el)) break;
            await new Promise(function(r){ setTimeout(r, 120); });
        }
        if (!el) return { ok: false, found: false, changed: false, method: -1 };
        const startHref = location.href;
        let mutations = 0;
        var obs = null;
        try { obs = new MutationObserver(function(){ mutations++; }); obs.observe(document.documentElement, { childList: true, subtree: true, attributes: true }); } catch (e) {}
        const passBefore = document.querySelectorAll('input[type="password"]').length;
        function center() { try { var r = el.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; } catch (e) { return { x: 5, y: 5 }; } }
        function fireMouse() {
            var c = center();
            ['pointerover', 'pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'].forEach(function(t) {
                try {
                    var ev;
                    if (t.indexOf('pointer') === 0 && window.PointerEvent) {
                        ev = new PointerEvent(t, { bubbles: true, cancelable: true, clientX: c.x, clientY: c.y });
                    } else {
                        ev = new MouseEvent(t, { bubbles: true, cancelable: true, clientX: c.x, clientY: c.y });
                    }
                    el.dispatchEvent(ev);
                } catch (e) {}
            });
        }
        function fireEnter() {
            ['keydown', 'keypress', 'keyup'].forEach(function(t) {
                try { el.dispatchEvent(new KeyboardEvent(t, { bubbles: true, cancelable: true, key: 'Enter', code: 'Enter', keyCode: 13, which: 13 })); } catch (e) {}
            });
        }
        async function changed() {
            await new Promise(function(r){ setTimeout(r, 500); });
            if (location.href !== startHref) return true;
            if (mutations > 3) return true;
            try { if (document.querySelectorAll('input[type="password"]').length !== passBefore) return true; } catch (e) {}
            return false;
        }
        var methods = [
            function(){ try { el.scrollIntoView({ block: 'center' }); } catch (e) {} try { el.click(); } catch (e) {} },
            function(){ fireMouse(); },
            function(){ try { el.focus(); } catch (e) {} fireEnter(); },
            function(){ var f = el.closest ? el.closest('form') : null; if (f) { try { if (f.requestSubmit) f.requestSubmit(); else f.submit(); } catch (e) {} } }
        ];
        var used = -1;
        for (var m = 0; m < methods.length; m++) {
            try { methods[m](); } catch (e) {}
            used = m;
            if (await changed()) { try { obs && obs.disconnect(); } catch (e) {} return { ok: true, found: true, changed: true, method: m }; }
        }
        try { obs && obs.disconnect(); } catch (e) {}
        return { ok: true, found: true, changed: false, method: used };
        """
    }

    /// Submits the form matching `sel` (or the first form), watching for a
    /// navigation / DOM change. Arg: `sel`.
    static func followLeaderSubmitBody() -> String {
        return """
        let el = null;
        try { el = document.querySelector(sel); } catch (e) { el = null; }
        if (!el) { el = document.querySelector('form'); }
        if (!el) return { ok: false, found: false, changed: false };
        const startHref = location.href;
        let mutations = 0; var obs = null;
        try { obs = new MutationObserver(function(){ mutations++; }); obs.observe(document.documentElement, { childList: true, subtree: true }); } catch (e) {}
        try { if (el.requestSubmit) el.requestSubmit(); else if (el.submit) el.submit(); } catch (e) {}
        await new Promise(function(r){ setTimeout(r, 500); });
        try { obs && obs.disconnect(); } catch (e) {}
        var didChange = (location.href !== startHref) || (mutations > 3);
        return { ok: true, found: true, changed: didChange };
        """
    }

    /// Sets checkbox/radio `sel` to `checked`, via click then direct set,
    /// verifying the final state. Args: `sel`, `checked`.
    static func followLeaderCheckBody() -> String {
        return """
        const start = Date.now();
        let el = null;
        while (Date.now() - start < 2000) {
            try { el = document.querySelector(sel); } catch (e) { el = null; }
            if (el) break;
            await new Promise(function(r){ setTimeout(r, 100); });
        }
        if (!el) return { ok: false, found: false };
        try {
            if (el.checked !== checked) { el.click(); }
            if (el.checked !== checked) { el.checked = checked; try { el.dispatchEvent(new Event('change', { bubbles: true })); } catch (e) {} }
        } catch (e) {}
        var result = false; try { result = (el.checked === checked); } catch (e) {}
        return { ok: result, found: true };
        """
    }

    // MARK: - Session save / load — local + session storage

    /// Reads the current page's localStorage and sessionStorage (origin
    /// scoped, per the same-origin policy) plus its origin/href.
    static func sessionStorageCaptureScript() -> String {
        return """
        (function() {
            var ls = {}, ss = {};
            try { for (var i = 0; i < localStorage.length; i++) { var k = localStorage.key(i); ls[k] = localStorage.getItem(k); } } catch (e) {}
            try { for (var j = 0; j < sessionStorage.length; j++) { var k2 = sessionStorage.key(j); ss[k2] = sessionStorage.getItem(k2); } } catch (e) {}
            return JSON.stringify({ origin: location.origin, href: location.href, localStorage: ls, sessionStorage: ss });
        })();
        """
    }

    /// Restores previously captured storage into the current page. The two
    /// arguments must be valid JSON object literals (`{"k":"v",...}`).
    static func sessionStorageRestoreScript(localStorageJSON: String, sessionStorageJSON: String) -> String {
        return """
        (function() {
            try {
                var ls = \(localStorageJSON);
                for (var k in ls) { try { localStorage.setItem(k, ls[k]); } catch (e) {} }
            } catch (e) {}
            try {
                var ss = \(sessionStorageJSON);
                for (var k2 in ss) { try { sessionStorage.setItem(k2, ss[k2]); } catch (e) {} }
            } catch (e) {}
            return JSON.stringify({ restored: true });
        })();
        """
    }
}
