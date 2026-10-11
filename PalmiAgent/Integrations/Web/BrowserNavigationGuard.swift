import Foundation

enum BrowserNavigationGuard {
    static func nonces(in policy: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: "'nonce-([A-Za-z0-9+/_=-]{1,256})'") else { return [] }
        let range = NSRange(policy.startIndex..<policy.endIndex, in: policy)
        return Array(Set(expression.matches(in: policy, range: range).compactMap {
            Range($0.range(at: 1), in: policy).map { String(policy[$0]) }
        })).sorted()
    }

    static func scriptPolicy(nonce: String, serverNonces: [String]) -> String {
        let sources = Array(Set([nonce] + serverNonces)).sorted().map { "'nonce-\($0)'" }.joined(separator: " ")
        return "script-src * data: blob: 'unsafe-eval' 'wasm-unsafe-eval'; script-src-elem * data: blob: \(sources); script-src-attr 'unsafe-inline'; form-action http: https:"
    }

    // JavaScript URL 可能不进入 WebKit 导航代理，因此链接与表单还须在默认动作前拦截。
    static let common = #"""
    const allowed = raw => {
        try { const u=new URL(raw,document.baseURI); return /^https?:$/i.test(u.protocol) && !u.username && !u.password; }
        catch (_) { return false; }
    };
    const formAllowed = (form,submitter) => allowed(submitter?.hasAttribute('formaction') ? submitter.formAction : form.action);
    """#

    static func isolatedScript(nonce: String, serverNonces: [String]) -> String {
        let policy = scriptPolicy(nonce: nonce, serverNonces: serverNonces)
        let encoded = String(data: try! JSONEncoder().encode(policy), encoding: .utf8)!
        return """
        const browserNonce='\(nonce)';
        let browserCSPInstalled=false;
        const stampScripts = node => {
            if (node.nodeType!==1) return;
            if (node.tagName==='SCRIPT' && !node.nonce) node.nonce=browserNonce;
            for (const script of node.querySelectorAll('script')) if (!script.nonce) script.nonce=browserNonce;
        };
        const installBrowserCSP = () => {
            if (browserCSPInstalled || !document.head) return;
            browserCSPInstalled=true;
            const meta=document.createElement('meta');
            meta.httpEquiv='Content-Security-Policy';
            meta.content=\(encoded);
            document.head.prepend(meta);
            globalThis.__palmiBrowserCSPInstalled=true;
        };
        new MutationObserver(records => {
            installBrowserCSP();
            for (const record of records) for (const node of record.addedNodes) stampScripts(node);
        }).observe(document,{subtree:true,childList:true});
        installBrowserCSP();
        if (document.documentElement) stampScripts(document.documentElement);
        window.addEventListener('securitypolicyviolation',event => {
            if (event.blockedURI==='inline' && event.effectiveDirective==='script-src-elem')
                window.webkit.messageHandlers.palmiBrowserFrame.postMessage({blocked:'已拦截 JavaScript URL 或未获许可的内联脚本。'});
        },true);
        """ + common + #"""
    const report = message => window.webkit.messageHandlers.palmiBrowserFrame.postMessage({blocked:message});
    const block = (event,message) => { event.preventDefault(); event.stopImmediatePropagation(); report(message); };
    window.addEventListener('click',event => {
        const path=event.composedPath();
        const link=path.find(el=>el?.matches?.('a[href],area[href]'));
        if (link?.hasAttribute('download')) { block(event,'已拦截下载。'); return; }
        if (link && !allowed(link.href)) { block(event,'已拦截非 http/https 导航。'); return; }
        const submitter=path.find(el=>el?.form && ((el.tagName==='BUTTON' && el.type==='submit') ||
            (el.tagName==='INPUT' && ['submit','image'].includes(el.type))));
        if (submitter && !formAllowed(submitter.form,submitter)) block(event,'已拦截表单的非 http/https 导航。');
    },true);
    window.addEventListener('submit',event => {
        if (event.target?.tagName==='FORM' && !formAllowed(event.target,event.submitter)) block(event,'已拦截表单的非 http/https 导航。');
    },true);
    window.addEventListener('__palmiBlockedNavigation',event => {
        if (typeof event.detail==='string') report(event.detail.slice(0,160));
    },true);
    """#
    }

    static func pageScript(nonce: String) -> String {
        #"""
    (() => {
    """# + common + #"""
        const report = () => window.dispatchEvent(new CustomEvent('__palmiBlockedNavigation',{detail:'已拦截脚本请求的非 http/https 导航。'}));
        for (const method of ['submit','requestSubmit']) {
            const original=HTMLFormElement.prototype[method];
            HTMLFormElement.prototype[method]=function(...args) {
                if (!formAllowed(this,args[0])) { report(); return; }
                return original.apply(this,args);
            };
        }
        const originalOpen=window.open;
        window.open=function(url,...args) {
            if (!allowed(url || 'about:blank')) { report(); return null; }
            return originalOpen.call(this,url,...args);
        };
    """# + """
        const createElement=Document.prototype.createElement;
        Document.prototype.createElement=function(...args) {
            const node=createElement.apply(this,args);
            if (node.tagName==='SCRIPT') node.nonce='\(nonce)';
            return node;
        };
        const createElementNS=Document.prototype.createElementNS;
        Document.prototype.createElementNS=function(...args) {
            const node=createElementNS.apply(this,args);
            if (node.localName==='script') node.setAttribute('nonce','\(nonce)');
            return node;
        };
        """ + #"""
    })();
    """#
    }
}
