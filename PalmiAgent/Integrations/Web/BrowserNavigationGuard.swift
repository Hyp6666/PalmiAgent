import Foundation

enum BrowserNavigationGuard {
    // JavaScript URL 可能不进入 WebKit 导航代理，因此链接与表单还须在默认动作前拦截。
    static let common = #"""
    const allowed = raw => {
        try { const u=new URL(raw,document.baseURI); return /^https?:$/i.test(u.protocol) && !u.username && !u.password; }
        catch (_) { return false; }
    };
    const formAllowed = (form,submitter) => allowed(submitter?.hasAttribute('formaction') ? submitter.formAction : form.action);
    """#

    // Keep enforcement in the isolated world. Never rewrite a site's CSP, script nonces,
    // or native page-world functions: doing so breaks inline scripts and challenge pages.
    static let isolatedScript = common + #"""
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
    """#
}
