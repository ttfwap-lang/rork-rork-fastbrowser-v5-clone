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

            document.addEventListener('input', function(e) {
                var t = e.target; if (!t) return;
                var p = cssPath(t); if (!p) return;
                post({ kind: 'input', selector: p, value: (t.value != null ? String(t.value) : '') });
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

    // MARK: - Follow the Leader — replay (follower windows)

    /// Builds the JS that replays a single recorded action in a follower
    /// window. Returns nil for unknown/oversized payloads so a malformed
    /// message can never inject junk.
    static func followLeaderReplayScript(kind: String, payload: [String: Any]) -> String? {
        switch kind {
        case "click":
            guard let sel = payload["selector"] as? String, !sel.isEmpty else { return nil }
            let s = sel.jsEscaped
            return """
            (function(){ try { var el=document.querySelector('\(s)'); if(el){ if(el.scrollIntoView){el.scrollIntoView({block:'center'});} el.click(); } } catch(e){} })();
            """
        case "input":
            guard let sel = payload["selector"] as? String, !sel.isEmpty else { return nil }
            let s = sel.jsEscaped
            let v = (payload["value"] as? String ?? "").jsEscaped
            return """
            (function(){ try { var el=document.querySelector('\(s)'); if(el){ var setv=window.__ffb_setNativeValue; if(setv){ setv(el, '\(v)'); } else { el.value='\(v)'; try{el.dispatchEvent(new Event('input',{bubbles:true}));}catch(e){} try{el.dispatchEvent(new Event('change',{bubbles:true}));}catch(e){} } } } catch(e){} })();
            """
        case "check":
            guard let sel = payload["selector"] as? String, !sel.isEmpty else { return nil }
            let s = sel.jsEscaped
            let checked = (payload["checked"] as? Bool ?? false) ? "true" : "false"
            return """
            (function(){ try { var el=document.querySelector('\(s)'); if(el){ el.checked=\(checked); try{el.dispatchEvent(new Event('change',{bubbles:true}));}catch(e){} } } catch(e){} })();
            """
        case "submit":
            guard let sel = payload["selector"] as? String, !sel.isEmpty else { return nil }
            let s = sel.jsEscaped
            return """
            (function(){ try { var el=document.querySelector('\(s)'); if(el){ if(el.requestSubmit){ el.requestSubmit(); } else if(el.submit){ el.submit(); } } } catch(e){} })();
            """
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
