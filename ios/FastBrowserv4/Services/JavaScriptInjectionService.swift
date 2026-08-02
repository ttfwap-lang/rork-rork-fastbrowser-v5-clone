import Foundation

struct JavaScriptInjectionService {
    static func fillHelperScript() -> String {
        return """
        window.__ffb_isVisible = function(el) {
            if (!el) return false;
            if (el.disabled || el.readOnly) return false;
            if (el.getAttribute && el.getAttribute('aria-hidden') === 'true') return false;
            var style = window.getComputedStyle ? window.getComputedStyle(el) : null;
            if (style) {
                if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return false;
                if (style.pointerEvents === 'none') return false;
            }
            // offsetParent is null for fixed/sticky elements in some browsers,
            // so also accept anything with a non-zero client box.
            if (el.offsetParent !== null) return true;
            var rect = el.getBoundingClientRect ? el.getBoundingClientRect() : null;
            return !!(rect && rect.width > 0 && rect.height > 0);
        };

        window.__ffb_setNativeValue = function(element, value) {
            try {
                var proto = window.HTMLInputElement && window.HTMLInputElement.prototype;
                var desc = proto ? Object.getOwnPropertyDescriptor(proto, 'value') : null;
                if (desc && desc.set) {
                    desc.set.call(element, value);
                } else {
                    element.value = value;
                }
            } catch (e) {
                element.value = value;
            }
            try { element.dispatchEvent(new Event('input', { bubbles: true })); } catch (e) {}
            try { element.dispatchEvent(new Event('change', { bubbles: true })); } catch (e) {}
            try { element.dispatchEvent(new InputEvent('input', { bubbles: true, data: value, inputType: 'insertText' })); } catch (e) {}
        };

        window.__ffb_findUsername = function(customSel) {
            if (customSel) {
                try {
                    var el = document.querySelector(customSel);
                    if (el && window.__ffb_isVisible(el)) return el;
                } catch (e) {}
            }
            var selectors = [
                'input[autocomplete="username"]',
                'input[autocomplete="email"]',
                'input[type="email"]',
                'input[name*="user" i]',
                'input[name*="email" i]',
                'input[name*="login" i]',
                'input[name*="account" i]',
                'input[id*="user" i]',
                'input[id*="email" i]',
                'input[id*="login" i]',
                'input[id*="account" i]',
                'input[placeholder*="email" i]',
                'input[placeholder*="user" i]',
                'input[placeholder*="login" i]',
                'input[type="text"]:not([name*="search" i]):not([id*="search" i]):not([placeholder*="search" i])',
                'input:not([type]):not([name*="search" i]):not([id*="search" i])'
            ];
            for (var i = 0; i < selectors.length; i++) {
                try {
                    var nodes = document.querySelectorAll(selectors[i]);
                    for (var j = 0; j < nodes.length; j++) {
                        if (window.__ffb_isVisible(nodes[j])) return nodes[j];
                    }
                } catch (e) {}
            }
            return null;
        };

        window.__ffb_findPassword = function(customSel) {
            if (customSel) {
                try {
                    var el = document.querySelector(customSel);
                    if (el && window.__ffb_isVisible(el)) return el;
                } catch (e) {}
            }
            var selectors = [
                'input[autocomplete="current-password"]',
                'input[type="password"]',
                'input[name*="pass" i]',
                'input[id*="pass" i]',
                'input[placeholder*="pass" i]'
            ];
            for (var i = 0; i < selectors.length; i++) {
                try {
                    var nodes = document.querySelectorAll(selectors[i]);
                    for (var j = 0; j < nodes.length; j++) {
                        if (window.__ffb_isVisible(nodes[j])) return nodes[j];
                    }
                } catch (e) {}
            }
            return null;
        };

        window.__ffb_findSubmit = function(customSel) {
            if (customSel) {
                try {
                    var el = document.querySelector(customSel);
                    if (el && window.__ffb_isVisible(el)) return el;
                } catch (e) {}
            }
            var selectors = [
                'button[type="submit"]',
                'input[type="submit"]',
                'button[name*="login" i]',
                'button[name*="sign" i]',
                'button[id*="login" i]',
                'button[id*="sign" i]',
                'button[class*="login" i]',
                'button[class*="sign" i]',
                'a[role="button"]',
                '[role="button"]'
            ];
            for (var s = 0; s < selectors.length; s++) {
                try {
                    var els = document.querySelectorAll(selectors[s]);
                    for (var k = 0; k < els.length; k++) {
                        var candidate = els[k];
                        if (!window.__ffb_isVisible(candidate)) continue;
                        var text = ((candidate.textContent || candidate.value || '') + '').toLowerCase();
                        if (text.includes('log in') || text.includes('login') ||
                            text.includes('sign in') || text.includes('signin') ||
                            text.includes('submit') || text.includes('continue') ||
                            text.includes('next') || text.includes('enter')) {
                            return candidate;
                        }
                        // Prefer real submit controls even without matching text.
                        if (candidate.type === 'submit' || candidate.getAttribute('type') === 'submit') {
                            return candidate;
                        }
                    }
                } catch (e) {}
            }
            var form = document.querySelector('form');
            if (form) {
                var btn = form.querySelector('button[type="submit"], input[type="submit"], button');
                if (btn && window.__ffb_isVisible(btn)) return btn;
            }
            return null;
        };
        """
    }

    static func fillCredentialScript(
        username: String,
        password: String,
        usernameSelector: String?,
        passwordSelector: String?,
        suppressKeyboard: Bool = false
    ) -> String {
        let escapedUser = username.jsEscaped
        let escapedPass = password.jsEscaped
        let userSel = (usernameSelector?.isEmpty == false) ? usernameSelector!.jsEscaped : ""
        let passSel = (passwordSelector?.isEmpty == false) ? passwordSelector!.jsEscaped : ""
        let focusCall = suppressKeyboard ? "" : "try { el.focus({ preventScroll: true }); } catch (e) { try { el.focus(); } catch (e2) {} }"
        let blurAfter = suppressKeyboard ? "try { if (document.activeElement && document.activeElement.blur) { document.activeElement.blur(); } } catch (e) {}" : ""

        return """
        (function() {
            var userField = window.__ffb_findUsername ? window.__ffb_findUsername('\(userSel)') : null;
            var passField = window.__ffb_findPassword ? window.__ffb_findPassword('\(passSel)') : null;
            var setVal = window.__ffb_setNativeValue || function(el, v) {
                el.value = v;
                try { el.dispatchEvent(new Event('input', { bubbles: true })); } catch (e) {}
                try { el.dispatchEvent(new Event('change', { bubbles: true })); } catch (e) {}
            };
            var fillField = function(el, v) {
                if (!el) return;
                \(focusCall)
                setVal(el, v);
                try { el.setAttribute('value', v); } catch (e) {}
            };
            var filled = 0;
            if (userField) { fillField(userField, '\(escapedUser)'); filled++; }
            if (passField) { fillField(passField, '\(escapedPass)'); filled++; }
            \(blurAfter)
            return JSON.stringify({ filled: filled, userFound: !!userField, passFound: !!passField });
        })();
        """
    }

    /// Installs a one-shot login-response observer that watches the page for
    /// ~6 seconds after a submit and posts a single classification
    /// (`success`, `failed`, `blocked`, or `timeout`) to the
    /// `loginResponse` script-message handler. Purely informational —
    /// never used by RCR (which has its own `rcrObserver`).
    static func loginResponseObserverScript() -> String {
        return """
        (function() {
            try {
                if (window.__ffb_lrObserver) { try { window.__ffb_lrObserver.disconnect(); } catch(e){} }
                if (window.__ffb_lrTimer) { try { clearTimeout(window.__ffb_lrTimer); } catch(e){} }
                if (window.__ffb_lrTimeout) { try { clearTimeout(window.__ffb_lrTimeout); } catch(e){} }
                window.__ffb_lrFired = false;
                var post = function(kind, hint) {
                    if (window.__ffb_lrFired) return;
                    window.__ffb_lrFired = true;
                    try { if (window.__ffb_lrObserver) window.__ffb_lrObserver.disconnect(); } catch(e){}
                    try { if (window.__ffb_lrTimer) clearTimeout(window.__ffb_lrTimer); } catch(e){}
                    try { if (window.__ffb_lrTimeout) clearTimeout(window.__ffb_lrTimeout); } catch(e){}
                    try {
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.loginResponse) {
                            window.webkit.messageHandlers.loginResponse.postMessage({ kind: kind, hint: hint || '' });
                        }
                    } catch (e) {}
                };
                var classify = function() {
                    try {
                        var bodyText = (document.body && document.body.innerText) ? document.body.innerText : '';
                        var lower = bodyText.toLowerCase();
                        var passField = document.querySelector('input[type="password"]');
                        var hasPassword = !!(passField && passField.offsetParent !== null);
                        if (lower.indexOf('been disabled') !== -1 || lower.indexOf('account is locked') !== -1 || lower.indexOf('account locked') !== -1) {
                            post('blocked', 'disabled');
                            return;
                        }
                        if (lower.indexOf('invalid') !== -1 || lower.indexOf('incorrect') !== -1 || lower.indexOf('wrong password') !== -1 || lower.indexOf('try again') !== -1) {
                            post('failed', 'invalid');
                            return;
                        }
                        if (bodyText.indexOf('Welcome!') !== -1 || lower.indexOf('dashboard') !== -1 || lower.indexOf('sign out') !== -1 || lower.indexOf('log out') !== -1) {
                            post('success', 'welcome');
                            return;
                        }
                        var path = window.location.pathname || '/';
                        if ((path === '' || path === '/') && !hasPassword) { post('success', 'homepage'); return; }
                    } catch (e) {}
                };
                var debounced = function() {
                    if (window.__ffb_lrTimer) clearTimeout(window.__ffb_lrTimer);
                    window.__ffb_lrTimer = setTimeout(classify, 350);
                };
                var obs = new MutationObserver(debounced);
                obs.observe(document.documentElement, { childList: true, subtree: true, characterData: true });
                window.__ffb_lrObserver = obs;
                window.__ffb_lrTimeout = setTimeout(function() { post('timeout', ''); }, 6000);
                setTimeout(classify, 500);
                return JSON.stringify({ installed: true });
            } catch (e) {
                return JSON.stringify({ installed: false, error: String(e) });
            }
        })();
        """
    }

    static func submitFormScript(submitSelector: String?) -> String {
        let sel = (submitSelector?.isEmpty == false) ? submitSelector!.jsEscaped : ""

        return """
        (function() {
            const btn = window.__ffb_findSubmit ? window.__ffb_findSubmit('\(sel)') : null;
            if (btn) { btn.click(); return JSON.stringify({ submitted: true }); }
            const form = document.querySelector('form');
            if (form) { form.submit(); return JSON.stringify({ submitted: true, method: 'form' }); }
            return JSON.stringify({ submitted: false });
        })();
        """
    }

    static func detectLoginFormScript() -> String {
        return """
        (function() {
            var isVisible = window.__ffb_isVisible || function(el) {
                if (!el) return false;
                if (el.offsetParent !== null) return true;
                var rect = el.getBoundingClientRect ? el.getBoundingClientRect() : null;
                return !!(rect && rect.width > 0 && rect.height > 0);
            };
            var passFields = document.querySelectorAll('input[type="password"], input[autocomplete="current-password"]');
            var visiblePass = 0;
            for (var i = 0; i < passFields.length; i++) {
                if (isVisible(passFields[i])) visiblePass++;
            }
            var forms = document.querySelectorAll('form');
            var formCount = 0;
            for (var j = 0; j < forms.length; j++) {
                if (forms[j].querySelector('input[type="password"], input[autocomplete="current-password"]')) formCount++;
            }
            return JSON.stringify({
                hasLoginForm: visiblePass > 0,
                passwordFieldCount: passFields.length,
                loginFormCount: formCount
            });
        })();
        """
    }

    /// Installs a MutationObserver that posts page state to native via the
    /// `rcrObserver` script-message handler. Idempotent — a previous observer
    /// is disconnected before a new one is attached. The script also fires an
    /// initial state ping so the runner sees the post-submit page even when
    /// no further DOM mutations occur.
    static func rcrInstallObserverScript() -> String {
        return """
        (function() {
            try {
                if (window.__ffb_rcrObserver) { try { window.__ffb_rcrObserver.disconnect(); } catch(e){} }
                if (window.__ffb_rcrTimer) { try { clearTimeout(window.__ffb_rcrTimer); } catch(e){} }
                var send = function() {
                    try {
                        var passField = document.querySelector('input[type="password"]');
                        var hasPassword = !!(passField && passField.offsetParent !== null);
                        var bodyText = (document.body && document.body.innerText) ? document.body.innerText : '';
                        var lower = bodyText.toLowerCase();
                        // Case-sensitive: only the exact 'Welcome!' marker counts.
                        // All-caps 'WELCOME' / 'WELCOME BACK!' must NOT trigger success.
                        var hasWelcome = bodyText.indexOf('Welcome!') !== -1;
                        var hasDisabled = lower.indexOf('been disabled') !== -1;
                        var hasTempDisabled = (!hasDisabled) && (lower.indexOf('temporarily') !== -1);
                        // Generic success detection: checks for common success-class patterns
                        // without hardcoding any single site's markup.
                        var hasSuccess = document.querySelector('[class*="success"]') != null
                            || document.querySelector('[class*="alert-success"]') != null
                            || document.querySelector('[class*="message-success"]') != null
                            || document.querySelector('[class*="notification-success"]') != null
                            || document.querySelector('[data-status="success"]') != null;
                        var path = window.location.pathname || '/';
                        var isHomepage = (path === '' || path === '/');
                        var url = window.location.href;
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.rcrObserver) {
                            window.webkit.messageHandlers.rcrObserver.postMessage({
                                hasPassword: hasPassword,
                                hasWelcome: hasWelcome,
                                hasDisabled: hasDisabled,
                                hasTempDisabled: hasTempDisabled,
                                hasSuccess: hasSuccess,
                                isHomepage: isHomepage,
                                url: url
                            });
                        }
                    } catch (e) {}
                };
                var debounced = function() {
                    if (window.__ffb_rcrTimer) { clearTimeout(window.__ffb_rcrTimer); }
                    window.__ffb_rcrTimer = setTimeout(send, 450);
                };
                var obs = new MutationObserver(debounced);
                obs.observe(document.documentElement, { childList: true, subtree: true, characterData: true, attributes: true });
                window.__ffb_rcrObserver = obs;
                setTimeout(send, 350);
                return JSON.stringify({ installed: true });
            } catch (e) {
                return JSON.stringify({ installed: false, error: String(e) });
            }
        })();
        """
    }

    static func rcrUninstallObserverScript() -> String {
        return """
        (function() {
            try { if (window.__ffb_rcrObserver) { window.__ffb_rcrObserver.disconnect(); } } catch(e){}
            window.__ffb_rcrObserver = null;
            if (window.__ffb_rcrTimer) { try { clearTimeout(window.__ffb_rcrTimer); } catch(e){} window.__ffb_rcrTimer = null; }
            return JSON.stringify({ uninstalled: true });
        })();
        """
    }

    /// One-shot, synchronous-style page-state read (no observer, no debounce).
    /// Returns the same shape as the `rcrObserver` message so the extra-submit
    /// loop can check for a terminal result (disabled / temp-disabled /
    /// success) after every confirmation submit, without waiting on the
    /// MutationObserver debounce.
    static func pageStateSnapshotScript() -> String {
        return """
        (function() {
            try {
                var passField = document.querySelector('input[type=\"password\"]');
                var hasPassword = !!(passField && passField.offsetParent !== null);
                var bodyText = (document.body && document.body.innerText) ? document.body.innerText : '';
                var lower = bodyText.toLowerCase();
                var hasWelcome = bodyText.indexOf('Welcome!') !== -1;
                var hasDisabled = lower.indexOf('been disabled') !== -1;
                var hasTempDisabled = (!hasDisabled) && (lower.indexOf('temporarily') !== -1);
                var hasSuccess = document.querySelector('[class*=\"success\"]') != null
                    || document.querySelector('[class*=\"alert-success\"]') != null
                    || document.querySelector('[class*=\"message-success\"]') != null
                    || document.querySelector('[class*=\"notification-success\"]') != null
                    || document.querySelector('[data-status=\"success\"]') != null;
                var path = window.location.pathname || '/';
                var isHomepage = (path === '' || path === '/');
                return JSON.stringify({
                    hasPassword: hasPassword,
                    hasWelcome: hasWelcome,
                    hasDisabled: hasDisabled,
                    hasTempDisabled: hasTempDisabled,
                    hasSuccess: hasSuccess,
                    isHomepage: isHomepage,
                    url: window.location.href
                });
            } catch (e) {
                return JSON.stringify({ hasPassword: false, hasWelcome: false, hasDisabled: false, hasTempDisabled: false, hasSuccess: false, isHomepage: false, url: '' });
            }
        })();
        """
    }

    // MARK: - Multi-window viewport normalization

    /// Forces every page loaded inside a multi-window (Quad) tile to lay out
    /// against a full, "normal" single-window phone width instead of
    /// reflowing into the tile's own tiny physical width. WebKit's standard
    /// mobile viewport auto-fit then shrinks that normal layout down to
    /// whatever the tile's actual size is — giving every grid size (2×2,
    /// 2×3, 4×2, 3×3, 3×4) an automatic, always-correct "zoomed out" view of the
    /// complete page instead of a squished/overlapping mobile layout.
    /// Re-asserts itself if the page's own scripts replace the viewport tag
    /// later (SPA-style sites), and again on DOMContentLoaded as a safety net
    /// since `document.head` may not exist yet at document-start.
    static func multiWindowViewportScript(referenceWidth: Int) -> String {
        return """
        (function() {
            if (window.__ffb_viewportLocked) return;
            window.__ffb_viewportLocked = true;
            var content = 'width=\(referenceWidth)';
            var apply = function() {
                try {
                    var metas = document.querySelectorAll('meta[name="viewport"]');
                    if (metas.length === 1 && metas[0].getAttribute('content') === content) return;
                    for (var i = 0; i < metas.length; i++) {
                        try { metas[i].remove(); } catch (e) {}
                    }
                    var meta = document.createElement('meta');
                    meta.setAttribute('name', 'viewport');
                    meta.setAttribute('content', content);
                    (document.head || document.documentElement).appendChild(meta);
                } catch (e) {}
            };
            apply();
            document.addEventListener('DOMContentLoaded', apply);
            var timer = null;
            try {
                var obs = new MutationObserver(function() {
                    if (timer) clearTimeout(timer);
                    timer = setTimeout(apply, 300);
                });
                obs.observe(document.documentElement, { childList: true, subtree: true });
                window.__ffb_viewportObserver = obs;
            } catch (e) {}
        })();
        """
    }

    // MARK: - Cookie banner removal

    /// Injected on every page load. Scans and removes cookie consent banners
    /// immediately, then installs a MutationObserver to catch dynamically-
    /// injected banners that appear after the initial load. Runs silently.
    static func cookieBannerRemovalScript() -> String {
        return """
        (function() {
            if (window.__ffb_cookieRemovalInstalled) return;
            window.__ffb_cookieRemovalInstalled = true;
            var selectors = [
                '.cookie-banner', '.cookieBanner', '.cookie-consent', '.cookieConsent',
                '.cookie-notice', '.cookieNotice', '.cookie-bar', '.cookieBar',
                '.cookie-popup', '.cookiePopup', '.cookie-modal', '.cookieModal',
                '#cookie-banner', '#cookieBanner', '#cookie-consent', '#cookieConsent',
                '#cookie-notice', '#cookieNotice', '#cookie-bar', '#cookieBar',
                '.gdpr-banner', '.gdprBanner', '.gdpr-modal', '.gdprModal',
                '.gdpr-consent', '.gdprConsent', '.gdpr-notice', '.gdprNotice',
                '#gdpr-banner', '#gdprBanner', '#gdpr-modal', '#gdprModal',
                '#gdpr-consent', '#gdprConsent', '#gdpr-notice', '#gdprNotice',
                '.cc-banner', '.ccBanner', '.cc-consent', '.ccConsent',
                '.consent-banner', '.consentBanner', '.consent-modal', '.consentModal',
                '#consent-banner', '#consentBanner', '#consent-modal', '#consentModal',
                '.eu-cookie', '.euCookie', '.privacy-banner', '.privacyBanner',
                '#privacy-banner', '#privacyBanner'
            ];
            // Attribute selectors for cookie/consent labelled elements.
            var attrSelectors = [
                '[aria-label*="cookie" i]',
                '[aria-label*="consent" i]',
                '[aria-label*="gdpr" i]',
                '[aria-label*="privacy" i]',
                '[data-cookie*="banner" i]',
                '[data-nosnippet*="cookie"]'
            ];
            var allSelectors = selectors.concat(attrSelectors);
            window.__ffb_cookieSelectors = allSelectors;
            var removeMatches = function() {
                for (var i = 0; i < allSelectors.length; i++) {
                    try {
                        var els = document.querySelectorAll(allSelectors[i]);
                        for (var j = 0; j < els.length; j++) {
                            try { els[j].remove(); } catch(e) {}
                        }
                    } catch(e) {}
                }
                // Tight text-based fallback: only removes elements that are
                // BOTH short AND positioned as a banner (fixed or sticky),
                // since real cookie banners are always overlaid at the
                // viewport edge — never inline in the main content flow.
                try {
                    var candidates = document.querySelectorAll('div[style*="fixed"], div[style*="sticky"], section[style*="fixed"], section[style*="sticky"], aside[style*="fixed"], aside[style*="sticky"]');
                    for (var k = 0; k < candidates.length; k++) {
                        try {
                            var d = candidates[k];
                            var text = (d.textContent || '').toLowerCase();
                            var hasCookie = text.indexOf('cookie') !== -1 || text.indexOf('gdpr') !== -1;
                            var hasAction = text.indexOf('accept') !== -1 || text.indexOf('consent') !== -1 || text.indexOf('agree') !== -1 || text.indexOf('reject') !== -1;
                            if (text.length < 600 && hasCookie && hasAction) {
                                d.remove();
                            }
                        } catch(e) {}
                    }
                } catch(e) {}
            };
            removeMatches();
            // Catch dynamically injected banners.
            try {
                var obs = new MutationObserver(function() {
                    if (window.__ffb_cookieTimer) clearTimeout(window.__ffb_cookieTimer);
                    window.__ffb_cookieTimer = setTimeout(removeMatches, 250);
                });
                obs.observe(document.documentElement, { childList: true, subtree: true });
                window.__ffb_cookieObs = obs;
            } catch(e) {}
        })();
        """
    }

    /// Waits for a cookie/consent banner to appear-and-be-dismissed after a
    /// fresh page load. The banner only ever shows up on a window's first
    /// load or right after a burn+reload, so this is only called at those two
    /// moments. Unlike the old version this does NOT bail immediately if no
    /// banner exists at call time — it gives the page a short grace window
    /// (~1.5s) for a dynamically-injected banner to appear, then polls via
    /// MutationObserver until dismissed or the full timeout elapses.
    static func waitForCookieNoticeScript(timeoutMs: Int = 10000) -> String {
        return """
        (function() {
            return new Promise(function(resolve) {
                try {
                    var selectors = window.__ffb_cookieSelectors || [];
                    var matches = function() {
                        for (var i = 0; i < selectors.length; i++) {
                            try { if (document.querySelector(selectors[i])) return true; } catch(e) {}
                        }
                        return false;
                    };
                    var done = false;
                    var obs = null;
                    var timer = null;
                    var finish = function(reason) {
                        if (done) return;
                        done = true;
                        try { if (obs) obs.disconnect(); } catch(e) {}
                        try { if (timer) clearTimeout(timer); } catch(e) {}
                        resolve(JSON.stringify({ waited: true, reason: reason }));
                    };
                    // Give the page a short grace window (~1.5s) for a
                    // dynamically-injected banner to appear before we
                    // conclude there isn't one.
                    var startObserving = function() {
                        if (matches()) {
                            obs = new MutationObserver(function() {
                                if (!matches()) finish('dismissed');
                            });
                            obs.observe(document.documentElement, { childList: true, subtree: true });
                        } else {
                            // Still nothing — bail without blocking.
                            finish('none');
                        }
                    };
                    if (matches()) {
                        // Banner already present — start watching immediately.
                        startObserving();
                    } else {
                        // No banner yet — wait up to 1.5s for one to appear
                        // before giving up. This prevents the race where
                        // didFinish fires before the consent script injects
                        // the banner DOM.
                        var graceTimer = setTimeout(function() {
                            startObserving();
                        }, 1500);
                        // But also watch for early appearance.
                        obs = new MutationObserver(function() {
                            if (matches()) {
                                try { clearTimeout(graceTimer); } catch(e) {}
                                try { obs.disconnect(); } catch(e) {}
                                startObserving();
                            }
                        });
                        obs.observe(document.documentElement, { childList: true, subtree: true });
                    }
                    timer = setTimeout(function() { finish('timeout'); }, \(timeoutMs));
                } catch (e) {
                    resolve(JSON.stringify({ waited: false, reason: 'error' }));
                }
            });
        })();
        """
    }

    // MARK: - Fingerprint hardening

    /// Deletes known Google tracking cookies. Called by the native timer
    /// every hour from each active web view.
    static func deleteTrackingCookiesScript() -> String {
        return """
        (function() {
            var cookies = ['__Secure-3PSID', '__Secure-3PAPISID', '__Secure-3PSIDCC',
                           '_ga', '_gid', '_gat', 'NID', 'SID', 'HSID', 'APISID',
                           'SAPISID', 'SSID', 'SIDCC', '__Secure-1PSID', '__Secure-1PAPISID'];
            for (var i = 0; i < cookies.length; i++) {
                document.cookie = cookies[i] + '=;expires=Thu, 01 Jan 1970 00:00:00 GMT;path=/;domain=' + location.hostname;
                document.cookie = cookies[i] + '=;expires=Thu, 01 Jan 1970 00:00:00 GMT;path=/;domain=.' + location.hostname;
                document.cookie = cookies[i] + '=;expires=Thu, 01 Jan 1970 00:00:00 GMT;path=/';
            }
            return JSON.stringify({ deleted: true });
        })();
        """
    }

    /// Spoils font enumeration so sites can't fingerprint by installed fonts.
    /// Injected at document start so it takes effect before any page JS.
    static func fontSpoofingScript() -> String {
        return """
        (function() {
            if (window.__ffb_fontSpoofed) return;
            window.__ffb_fontSpoofed = true;
            var sparseFonts = ['Arial', 'Times New Roman', 'Courier New', 'Georgia', 'Verdana', 'Helvetica'];
            try {
                var origEnumerate = Object.getOwnPropertyDescriptor(CSSFontFaceRule.prototype, 'family');
                Object.defineProperty(document, 'fonts', {
                    get: function() {
                        return {
                            values: function() { return sparseFonts.values(); },
                            has: function() { return true; },
                            forEach: function(fn) { sparseFonts.forEach(fn); },
                            get: function() { return sparseFonts[0]; },
                            size: sparseFonts.length
                        };
                    },
                    configurable: true
                });
            } catch(e) {}
            // Override FontFaceSet check if present.
            try {
                if (typeof FontFaceSet !== 'undefined') {
                    FontFaceSet.prototype.check = function() { return true; };
                }
            } catch(e) {}
        })();
        """
    }

    /// Blocks device orientation and device motion event listeners so sites
    /// can't fingerprint sensor APIs. Injected at document start.
    static func sensorBlockingScript() -> String {
        return """
        (function() {
            if (window.__ffb_sensorsBlocked) return;
            window.__ffb_sensorsBlocked = true;
            var noop = function() {};
            try {
                Object.defineProperty(window, 'DeviceOrientationEvent', { value: null, writable: false, configurable: false });
            } catch(e) {}
            try {
                Object.defineProperty(window, 'DeviceMotionEvent', { value: null, writable: false, configurable: false });
            } catch(e) {}
            // Block addEventListener for these event types.
            var origAdd = EventTarget.prototype.addEventListener;
            EventTarget.prototype.addEventListener = function(type, listener, options) {
                if (type === 'deviceorientation' || type === 'devicemotion' ||
                    type === 'orientationchange' || type === 'compassneedscalibration') {
                    return;
                }
                return origAdd.call(this, type, listener, options);
            };
            // Nullify the legacy on* properties.
            try { Object.defineProperty(window, 'ondeviceorientation', { get: function(){ return null; }, set: noop, configurable: false }); } catch(e) {}
            try { Object.defineProperty(window, 'ondevicemotion', { get: function(){ return null; }, set: noop, configurable: false }); } catch(e) {}
        })();
        """
    }

    /// Simulates human-like scrolling using randomised sine/cosine patterns.
    /// WKWebView doesn't expose mouse events, but scroll events are a common
    /// fingerprinting vector — this normalises them.
    static func humanScrollSimulationScript() -> String {
        return """
        (function() {
            if (window.__ffb_scrollSimInstalled) return;
            window.__ffb_scrollSimInstalled = true;
            var phase = Math.random() * Math.PI * 2;
            var interval = 2000 + Math.random() * 4000;
            setInterval(function() {
                phase += 0.3 + Math.random() * 0.7;
                var dy = Math.round(Math.sin(phase) * 30 + Math.cos(phase * 1.7) * 20 + Math.sin(phase * 3.1) * 15);
                var dx = Math.round(Math.cos(phase * 2.3) * 12 + Math.sin(phase * 0.7) * 8);
                try {
                    window.scrollBy(dx, dy);
                } catch(e) {}
            }, interval);
        })();
        """
    }

    static func extractFilledCredentialsScript() -> String {
        return """
        (function() {
            var passField = window.__ffb_findPassword ? window.__ffb_findPassword('') : document.querySelector('input[type="password"]');
            if (!passField || !passField.value) return JSON.stringify({ found: false });
            var userField = null;
            var form = passField.closest ? passField.closest('form') : null;
            if (form) {
                userField = form.querySelector('input[type="email"], input[autocomplete="username"], input[type="text"], input:not([type])');
            }
            if (!userField && window.__ffb_findUsername) {
                userField = window.__ffb_findUsername('');
            }
            if (!userField) {
                userField = document.querySelector('input[type="email"], input[autocomplete="username"]');
            }
            return JSON.stringify({
                found: true,
                username: userField ? (userField.value || '') : '',
                password: passField.value || ''
            });
        })();
        """
    }
}

extension JavaScriptInjectionService {
    /// Parses the JSON string returned by `pageStateSnapshotScript()` (or
    /// posted by the `rcrObserver` message handler) into a plain dictionary.
    static func parsePageState(_ raw: Any?) -> [String: Any]? {
        guard let json = raw as? String,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return dict
    }

    /// True if the payload represents a result RCR should act on immediately
    /// (permanent disable, temporary disable, or success) rather than firing
    /// another confirmation submit.
    static func isTerminalRCRState(_ payload: [String: Any]) -> Bool {
        let hasDisabled = payload["hasDisabled"] as? Bool ?? false
        let hasTempDisabled = payload["hasTempDisabled"] as? Bool ?? false
        let hasWelcome = payload["hasWelcome"] as? Bool ?? false
        let hasSuccess = payload["hasSuccess"] as? Bool ?? false
        let hasPassword = payload["hasPassword"] as? Bool ?? false
        let isHomepage = payload["isHomepage"] as? Bool ?? false
        return hasDisabled || hasTempDisabled || hasWelcome || hasSuccess || (isHomepage && !hasPassword)
    }
}

extension String {
    var jsEscaped: String {
        self.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
