import Foundation

enum BrowserDOMScript {
    // 脚本运行在独立的 WKContentWorld；网页不能访问保存的元素映射。
    static let body = #"""
    if (!globalThis.__palmiBrowserCSPInstalled) throw new Error('browser_policy_not_ready|页面安全策略尚未就绪或文档类型不受支持，请先 reload。');
    if (!globalThis.__palmiBrowser) {
        const attribute = 'data-palmi-browser-ref';
        const state = { id: null, refs: new Map(), marked: [], revision: 0 };
        const observedRoots = new WeakSet();
        const fail = (code, message) => { throw new Error(code + '|' + message); };
        const sensitive = el => el && (String(el.type).toLowerCase() === 'password' ||
            String(el.autocomplete || el.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/).some(x => x.startsWith('cc-')));
        const visible = el => {
            if (!el.getClientRects().length) return false;
            for (let parent=el; parent; parent=parent.parentElement || parent.getRootNode()?.host) {
                const s=parent.ownerDocument.defaultView.getComputedStyle(parent);
                if (s.display==='none' || s.visibility==='hidden' || s.visibility==='collapse' || Number(s.opacity)===0 || parent.hidden || parent.inert) return false;
            }
            return true;
        };
        const semantic = el => el.matches('a[href],button,input:not([type=hidden]),textarea,select,summary,[role=button],[role=link],[role=checkbox],[role=radio],[role=tab],[role=menuitem],[role=textbox],[role=combobox],[onclick],[contenteditable=true],[tabindex]:not([tabindex="-1"])');
        const frameScale = el => {
            for (let node=el; node; node=node.parentElement || node.getRootNode()?.host) {
                const transform=node.ownerDocument.defaultView.getComputedStyle(node).transform;
                if (transform==='none') continue;
                const m=new DOMMatrixReadOnly(transform);
                if (!m.is2D || Math.abs(m.b)>0.0001 || Math.abs(m.c)>0.0001 || m.a<=0 || m.d<=0)
                    fail('unsupported_transform','iframe 含旋转、倾斜或透视变换，请使用 handoff。');
            }
            const r=el.getBoundingClientRect();
            return {x:r.width/Math.max(1,el.offsetWidth),y:r.height/Math.max(1,el.offsetHeight)};
        };
        const watch = root => {
            if (observedRoots.has(root)) return;
            observedRoots.add(root);
            new MutationObserver(records => {
                if (records.some(r => r.type !== 'attributes' || r.attributeName !== attribute)) state.revision++;
            }).observe(root, { subtree: true, childList: true, characterData: true, attributes: true });
        };
        const collect = () => {
            const items = [], texts = [], viewportTexts = [], frameWarnings = [];
            let inaccessible = 0, visited = 0, clipped = false;
            const walk = (root, ox = 0, oy = 0, clip = {x:0,y:0,right:innerWidth,bottom:innerHeight}, sx = 1, sy = 1) => {
                watch(root);
                const walker = root.ownerDocument ? root.ownerDocument.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT) :
                    root.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
                let node;
                while ((node = walker.nextNode())) {
                    if (++visited > 40000) { clipped = true; break; }
                    if (node.nodeType === Node.TEXT_NODE) {
                        const parent = node.parentElement;
                        if (!parent || parent.closest('script,style,noscript,template') || !visible(parent)) continue;
                        const text = node.textContent.replace(/\s+/g, ' ').trim();
                        if (!text) continue;
                        texts.push(text);
                        const range = parent.ownerDocument.createRange(); range.selectNodeContents(node);
                        const r = range.getBoundingClientRect();
                        if (r.bottom*sy + oy > clip.y && r.top*sy + oy < clip.bottom && r.right*sx + ox > clip.x && r.left*sx + ox < clip.right) viewportTexts.push(text);
                        continue;
                    }
                    const el = node;
                    if (!visible(el)) continue;
                    const r = el.getBoundingClientRect();
                    const rect = {x:r.left*sx+ox,y:r.top*sy+oy,width:r.width*sx,height:r.height*sy};
                    const inView = rect.x < clip.right && rect.x + rect.width > clip.x && rect.y < clip.bottom && rect.y + rect.height > clip.y;
                    if (semantic(el)) items.push({el,rect,inView});
                    if (el.shadowRoot) walk(el.shadowRoot, ox, oy, clip, sx, sy);
                    if (el.tagName === 'IFRAME') {
                        try {
                            const doc = el.contentDocument;
                            if (!doc || !doc.documentElement) { if (inView) inaccessible++; continue; }
                            const scale=frameScale(el);
                            walk(doc, rect.x + el.clientLeft*scale.x*sx, rect.y + el.clientTop*scale.y*sy, {
                                x:Math.max(clip.x,rect.x),y:Math.max(clip.y,rect.y),
                                right:Math.min(clip.right,rect.x+rect.width),bottom:Math.min(clip.bottom,rect.y+rect.height)
                            }, sx*scale.x, sy*scale.y);
                        } catch (_) { if (inView) frameWarnings.push('iframe 含复杂变换，操作请使用 handoff。'); }
                    }
                }
            };
            walk(document);
            return {items,text:texts.join('\n').slice(0,1000000),viewportText:viewportTexts.join('\n')+'\n'+frameWarnings.slice(0,3).join('\n'),inaccessible,clipped};
        };
        const label = el => {
            const ids = (el.getAttribute('aria-labelledby') || '').split(/\s+/).filter(Boolean);
            const named = ids.map(id => el.getRootNode().getElementById?.(id)?.textContent || '').join(' ').trim();
            return String(el.getAttribute('aria-label') || named || Array.from(el.labels || []).map(x => x.innerText).join(' ') ||
                el.getAttribute('placeholder') || el.innerText || el.getAttribute('alt') || el.getAttribute('title') || el.name || el.tagName.toLowerCase())
                .replace(/\s+/g,' ').trim().slice(0,80);
        };
        const role = el => el.getAttribute('role') || (el.tagName === 'A' ? 'link' : el.tagName === 'SELECT' ? 'combobox' :
            el.tagName === 'TEXTAREA' || el.isContentEditable ? 'textbox' : el.tagName === 'INPUT' ?
                ['checkbox','radio'].includes(el.type) ? el.type : ['submit','button','reset'].includes(el.type) ? 'button' : 'textbox' : 'button');
        const observe = id => {
            for (const el of state.marked) el.removeAttribute(attribute);
            state.marked = []; state.refs.clear(); state.id = id;
            const data = collect();
            const visibleItems = data.items.filter(x => x.inView);
            const elements = visibleItems.slice(0,60).map((item,index) => {
                const {el,rect} = item, ref = 'e' + (index+1);
                el.setAttribute(attribute,ref); state.refs.set(ref,el); state.marked.push(el);
                const value = sensitive(el) ? '[受保护]' : ['checkbox','radio'].includes(el.type) ? String(el.checked) :
                    'value' in el ? String(el.value).slice(0,80) : null;
                return {ref,role:role(el),label:label(el),value,href:el.tagName === 'A' ? el.getAttribute('href') : null,...rect};
            });
            return {id,url:location.href,title:document.title,width:innerWidth,height:innerHeight,
                scrollY,scrollHeight:document.scrollingElement?.scrollHeight || 0,elements,
                offscreenCount:data.items.filter(x => !x.inView).length,crossOriginFrameCount:data.inaccessible,
                text:data.viewportText.slice(0,1500) + (visibleItems.length > 60 ? '\n（视口清单已截断至 60 个）' : '') +
                    (data.clipped ? '\n（页面结构超过扫描上限）' : '')};
        };
        const target = request => {
            if (state.id !== request.observation_id) fail('stale_observation','元素编号已过期，请先 observe。');
            const el = state.refs.get(request.ref);
            if (!el || !el.isConnected || el.getAttribute(attribute) !== request.ref) fail('stale_observation','元素已变化，请先 observe。');
            if (!visible(el)) fail('stale_observation','目标已不可见，请先 observe。');
            return el;
        };
        const formNavigation = (form,submitter) => {
            const raw=submitter?.hasAttribute('formaction') ? submitter.formAction : form.action;
            const url=new URL(raw,form.ownerDocument.baseURI);
            if (!/^https?:$/i.test(url.protocol) || url.username || url.password) fail('blocked_navigation','已拦截表单的非 http/https 导航。');
        };
        const safeClick = (el,point) => {
            if (!el) fail('element_not_found','该坐标没有可点击元素。');
            if (el.disabled || el.getAttribute('aria-disabled') === 'true') fail('element_disabled','目标不可用。');
            const link = el.closest('a[href]');
            if (link) {
                if (link.hasAttribute('download')) fail('blocked_download','已拦截下载。');
                if (!/^https?:$/i.test(new URL(link.href,location.href).protocol)) fail('blocked_navigation','已拦截非 http/https 导航。');
            }
            const submitter=el.closest('button,input[type=submit],input[type=image]');
            if (submitter?.form && ['submit','image'].includes(submitter.type)) formNavigation(submitter.form,submitter);
            el.focus?.({preventScroll:true});
            if (!point && typeof el.click==='function') el.click();
            else {
                const win=el.ownerDocument.defaultView, rect=el.getBoundingClientRect();
                el.dispatchEvent(new win.MouseEvent('click',{bubbles:true,composed:true,cancelable:true,view:win,
                    clientX:point?.x ?? rect.left+rect.width/2,clientY:point?.y ?? rect.top+rect.height/2,button:0}));
            }
        };
        const write = (el,text,append) => {
            if (sensitive(el)) fail('sensitive_field','禁止自动输入密码或支付字段，请使用 handoff。');
            if (el.disabled || el.readOnly) fail('element_disabled','目标输入框不可编辑。');
            const win = el.ownerDocument.defaultView;
            if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
                const proto = el.tagName === 'INPUT' ? win.HTMLInputElement.prototype : win.HTMLTextAreaElement.prototype;
                if (el.tagName === 'INPUT' && ['file','checkbox','radio','button','submit','reset','hidden'].includes(el.type)) fail('invalid_target','目标不是可写文本框。');
                Object.getOwnPropertyDescriptor(proto,'value').set.call(el,(append ? el.value : '') + text);
            } else if (el.isContentEditable) { el.textContent = (append ? el.textContent : '') + text; }
            else fail('invalid_target','目标不是可写文本框。');
            el.dispatchEvent(new win.InputEvent('input',{bubbles:true,composed:true,inputType:'insertText',data:text}));
            el.dispatchEvent(new win.Event('change',{bubbles:true,composed:true}));
        };
        const focused = () => {
            let el = document.activeElement;
            for (let i=0;i<20;i++) {
                if (el?.shadowRoot?.activeElement) el = el.shadowRoot.activeElement;
                else if (el?.tagName === 'IFRAME') {
                    let child; try { child = el.contentDocument?.activeElement; } catch (_) {}
                    if (!child) fail('cross_origin_frame','跨域 iframe 的焦点无法读取，请使用 handoff。');
                    el = child;
                } else break;
            }
            return el || document.body;
        };
        const press = key => {
            const el = focused(), win = el.ownerDocument.defaultView;
            if (sensitive(el)) fail('sensitive_field','密码或支付字段的按键操作请使用 handoff。');
            if (key==='Enter' && el.form) {
                const button=el.form.querySelector('button:not([type]),button[type=submit],input[type=submit]');
                formNavigation(el.form,button);
            }
            const accepted = el.dispatchEvent(new win.KeyboardEvent('keydown',{key,code:key,bubbles:true,composed:true,cancelable:true}));
            if (accepted) {
                if (key === 'Tab') {
                    const list = collect().items.map(x=>x.el).filter(x=>!x.disabled && x.tabIndex >= 0);
                    const index = list.indexOf(el); list[(index+1) % list.length]?.focus();
                } else if (key === 'Enter') {
                    if (el.tagName === 'TEXTAREA' || el.isContentEditable) write(el,'\n',true);
                    else if (el.matches('button,a[href],summary,input[type=button],input[type=submit],input[type=checkbox],input[type=radio]')) safeClick(el);
                    else if (el.form) {
                        const button = el.form.querySelector('button:not([type]),button[type=submit],input[type=submit]');
                        if (button) safeClick(button); else el.form.requestSubmit();
                    }
                } else if (key === 'Escape') {
                    const dialog=el.closest?.('dialog[open]');
                    if (dialog && dialog.dispatchEvent(new win.Event('cancel',{cancelable:true}))) dialog.close();
                    else el.blur?.();
                }
            }
            el.dispatchEvent(new win.KeyboardEvent('keyup',{key,code:key,bubbles:true,composed:true}));
        };
        const frameToken = iframe => new Promise((resolve,reject) => {
            const secret = globalThis.__palmiFrameSecret;
            const requestID = Math.random().toString(36).slice(2);
            const listener = event => {
                if (event.source !== iframe.contentWindow || event.data?.palmiFrameReply !== secret || event.data?.requestID !== requestID) return;
                clearTimeout(timer); window.removeEventListener('message',listener); resolve(event.data.token);
            };
            const timer = setTimeout(() => { window.removeEventListener('message',listener); reject(new Error('stale_frame|iframe 正在切换，请先 observe 或 look。')); },800);
            window.addEventListener('message',listener);
            iframe.contentWindow.postMessage({palmiFrameQuery:secret,requestID},'*');
        });
        const atPoint = async (doc,x,y) => {
            let el = doc.elementFromPoint(x,y);
            for (let i=0;i<20 && el;i++) {
                const inner = el.shadowRoot?.elementFromPoint(x,y);
                if (inner && inner !== el) { el=inner; continue; }
                if (el.tagName === 'IFRAME') {
                    const r=el.getBoundingClientRect();
                    const scale=frameScale(el);
                    const childX=(x-r.left)/scale.x-el.clientLeft, childY=(y-r.top)/scale.y-el.clientTop;
                    return {routeFrame:await frameToken(el),x:childX,y:childY};
                }
                break;
            }
            return el;
        };
        globalThis.__palmiBrowser = {state,observe,collect,target,safeClick,write,press,atPoint};
    }
    const api = globalThis.__palmiBrowser;
    if (request.operation === 'observe') return JSON.stringify(api.observe(request.id));
    if (request.operation === 'text') return JSON.stringify({text:api.collect().text});
    if (request.operation === 'settle') return JSON.stringify({ready:document.readyState,revision:api.state.revision,url:location.href});
    if (request.operation === 'click') {
        if (!request.ref && (request.x >= innerWidth || request.y >= innerHeight)) throw new Error('invalid_coordinates|坐标超出当前视口。');
        const el = request.ref ? api.target(request) : await api.atPoint(document,request.x,request.y);
        if (el?.routeFrame) { api.state.id=null; return JSON.stringify(el); }
        api.safeClick(el,request.ref ? null : {x:request.x,y:request.y});
    } else if (request.operation === 'type') {
        const el = api.target(request); el.focus({preventScroll:true}); api.write(el,request.text,!request.clear);
        if (request.submit) api.press('Enter');
    } else if (request.operation === 'select') {
        const el = api.target(request);
        if (el.tagName !== 'SELECT' || el.disabled) throw new Error('invalid_target|目标不是可用下拉框。');
        if (String(el.autocomplete || el.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/).some(x=>x.startsWith('cc-'))) throw new Error('sensitive_field|支付字段请使用 handoff。');
        if (!Array.from(el.options).some(x=>x.value===request.value && !x.disabled)) throw new Error('invalid_option|下拉框没有该可用选项。');
        const win=el.ownerDocument.defaultView;
        Object.getOwnPropertyDescriptor(win.HTMLSelectElement.prototype,'value').set.call(el,request.value);
        el.dispatchEvent(new win.Event('input',{bubbles:true,composed:true})); el.dispatchEvent(new win.Event('change',{bubbles:true,composed:true}));
    } else if (request.operation === 'press') api.press(request.key);
    else if (request.operation === 'scroll') {
        if (request.ref) api.target(request).scrollIntoView({block:'center',inline:'nearest',behavior:'instant'});
        else window.scrollBy({top:innerHeight*request.amount*(request.direction==='down'?1:-1),behavior:'instant'});
    }
    api.state.id = null;
    return 'ok';
    """#
}
