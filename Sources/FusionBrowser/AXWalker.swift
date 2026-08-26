import Foundation

// FR-02 / B1 / T2.1: injected JS walker for AXTree extraction with stable mapping.
// FR-03 / C4 / T2.2: visibility audit (static rules + render-based test) in same walk.
// Audit C7: type=password currentValue masked to ********.
//
// Stable mapping (B1): structure fingerprint (tag + attribute subset + document path)
// + WeakRef<Node>. NOT data-fb-node attribute (stripped on SPA re-render).
// Mapping lives in-process per session, keyed by synthetic @eN id.
// Next action resolves @eN -> live node via WeakRef; dead -> node_stale (no silent fail).

public struct FBExtractedNode: Codable, Equatable {
    public var nodeId: String
    public var role: String
    public var name: String
    public var isDisabled: Bool
    public var currentValue: String
    public var fingerprint: String
    public var docPath: String
    // T2.2: visibility audit flags (rule -> true if matched) + render-based hidden flag.
    public var hiddenFlags: [String: Bool]
    public var renderHidden: Bool

    public init(nodeId: String, role: String, name: String, isDisabled: Bool,
                currentValue: String, fingerprint: String, docPath: String,
                hiddenFlags: [String: Bool], renderHidden: Bool) {
        self.nodeId = nodeId
        self.role = role
        self.name = name
        self.isDisabled = isDisabled
        self.currentValue = currentValue
        self.fingerprint = fingerprint
        self.docPath = docPath
        self.hiddenFlags = hiddenFlags
        self.renderHidden = renderHidden
    }
}

public struct FBExtractResult: Codable {
    public var nodes: [FBExtractedNode]
    public var url: String
    public var title: String
    public var nodesAudited: Int
    public var hiddenNodesPurged: Int
    public var matchedRules: [String]

    public init(nodes: [FBExtractedNode], url: String, title: String,
                nodesAudited: Int, hiddenNodesPurged: Int, matchedRules: [String]) {
        self.nodes = nodes
        self.url = url
        self.title = title
        self.nodesAudited = nodesAudited
        self.hiddenNodesPurged = hiddenNodesPurged
        self.matchedRules = matchedRules
    }
}

// In-process stable mapping: @eN -> fingerprint + WeakRef handle.
// WeakRef<Node> cannot cross JS<->Swift; we keep fingerprint here and a JS-side
// WeakRef map keyed by the same @eN. Resolve = re-walk checks node still matches
// fingerprint + alive. Dead -> node_stale.
public final class FBStableMapping {
    private var mappings: [String: FBNodeMapping] = [:]
    private let queue = DispatchQueue(label: "fusion-browser.mapping")
    private let log = FBLogger.shared

    public init() {}

    public func install(_ nodes: [FBExtractedNode]) {
        queue.sync {
            mappings.removeAll()
            for n in nodes {
                mappings[n.nodeId] = FBNodeMapping(nodeId: n.nodeId, role: n.role, name: n.name,
                                                    fingerprint: n.fingerprint)
            }
        }
        log.debug("Mapping", "installed \(nodes.count) nodes")
    }

    public func resolve(_ nodeId: String) -> FBNodeMapping? {
        return queue.sync { mappings[nodeId] }
    }

    public func invalidate() {
        queue.sync { mappings.removeAll() }
    }

    public func count() -> Int { return queue.sync { mappings.count } }
}

// The injected JS. Single walk: collect interactive nodes + visibility audit +
// fingerprint + docPath. JS-side WeakRef map keyed by @eN for click/type resolve.
// Returns JSON {nodes,url,title,audited,purged,rules}.
// NOTE: kept as a string literal; minified-ish but readable for debugging.
public enum FBWalkerScript {
    public static let extract = #"""
(function(){
    if (window.__fbMap) { try { window.__fbMap.clear(); } catch(e){} }
    window.__fbMap = new Map();
    var nextId = 1;
    var INTERACTIVE = new Set(["a","button","input","select","textarea","[role=button]","[role=link]","[role=checkbox]","[role=radio]","[onclick]"]);
    var out = [];
    var audited = 0, purged = 0;
    var rulesHit = {};

    function roleOf(el){
        var r = el.getAttribute("role");
        if (r) return r;
        var t = el.tagName.toLowerCase();
        if (t==="a") return "link";
        if (t==="button") return "button";
        if (t==="input"){ var tp=el.type||"text"; return tp==="checkbox"||tp==="radio"?tp:"textbox"; }
        if (t==="select") return "combobox";
        if (t==="textarea") return "textbox";
        return t;
    }
    function docPath(el){
        var parts=[]; var cur=el; var depth=0;
        while(cur && cur.nodeType===1 && depth<8){
            var t=cur.tagName.toLowerCase();
            var sib=cur.parentNode?Array.prototype.indexOf.call(cur.parentNode.children,cur):-1;
            parts.unshift(t+(sib>=0?("["+(sib+1)+"]"):""));
            cur=cur.parentNode; depth++;
        }
        return parts.join("/");
    }
    function fingerprint(el){
        var tag=el.tagName.toLowerCase();
        var attrs=[];
        var keep=["id","name","type","role","href","aria-label","placeholder","data-test"];
        for(var i=0;i<keep.length;i++){ var v=el.getAttribute(keep[i]); if(v) attrs.push(keep[i]+"="+v.substring(0,40)); }
        var txt=(el.innerText||"").trim().substring(0,24);
        return tag+"|"+attrs.join(",")+"|"+txt+"|"+docPath(el);
    }
    // T2.2: static hidden-vector rules.
    function staticHidden(el){
        var s=getComputedStyle(el);
        var f={};
        if(s.display==="none") f["display:none"]=true;
        if(s.visibility==="hidden") f["visibility:hidden"]=true;
        if(parseFloat(s.opacity)===0) f["opacity:0"]=true;
        if(parseFloat(s.fontSize)===0) f["font-size:0"]=true;
        if(el.getAttribute("aria-hidden")==="true") f["aria-hidden:true"]=true;
        if(el.hasAttribute("hidden")) f["hidden-attr"]=true;
        var rect=el.getBoundingClientRect();
        if(rect.left<-9999||rect.top<-9999) f["offscreen"]=true;
        var ti=parseInt(s.textIndent,10);
        if(!isNaN(ti)&&ti<-9999) f["text-indent:<-9999"]=true;
        if(s.clipPath==="none"&&s.webkitClipPath==="none"){ /* not hidden by clip none */ }
        if(s.transform.indexOf("scale(0)")>=0) f["transform:scale(0)"]=true;
        if(s.filter.indexOf("opacity(0)")>=0) f["filter:opacity(0)"]=true;
        if(s.color===s.backgroundColor && s.color!=="rgba(0, 0, 0, 0)") f["color==bg"]=true;
        return f;
    }
    // T2.2: render-based test (fallback). true if node effectively invisible.
    function renderHidden(el){
        var rect=el.getBoundingClientRect();
        if(rect.width===0||rect.height===0) return true;
        if(rect.right<0||rect.bottom<0||rect.left>window.innerWidth||rect.top>window.innerHeight) return true;
        // elementFromPoint hit-test at center.
        var cx=rect.left+rect.width/2, cy=rect.top+rect.height/2;
        var hit=document.elementFromPoint(cx,cy);
        if(hit && hit!==el && !el.contains(hit)) {
            // covered by higher z-index element -> hidden
            return true;
        }
        return false;
    }
    function isInteractive(el){
        if(INTERACTIVE.has(el.tagName.toLowerCase())) return true;
        if(el.getAttribute("role")) return true;
        if(el.onclick) return true;
        if(el.tabIndex>=0) return true;
        return false;
    }

    var all=document.querySelectorAll("*");
    for(var i=0;i<all.length;i++){
        var el=all[i];
        if(!isInteractive(el)) continue;
        var sh=staticHidden(el);
        var rh=renderHidden(el);
        audited++;
        var name=(el.innerText||el.getAttribute("aria-label")||el.getAttribute("title")||"").trim().substring(0,60);
        var isDisabled = el.disabled===true || el.getAttribute("aria-disabled")==="true";
        // C7: password masking.
        var val="";
        if(el.value!==undefined && el.value!==null){
            if((el.type||"")==="password") val="********";
            else val=String(el.value).substring(0,80);
        }
        var fp=fingerprint(el);
        var id="e"+(nextId++);
        var node={nodeId:id, role:roleOf(el), name:name, isDisabled:isDisabled,
                  currentValue:val, fingerprint:fp, docPath:docPath(el),
                  hiddenFlags:sh, renderHidden:rh};
        // T2.2 purge: hide text content but keep node if interactive+visible.
        if(Object.keys(sh).length>0 || rh){
            purged++;
            for(var k in sh){ rulesHit[k]=true; }
            if(rh) rulesHit["render:hidden"]=true;
            // keep node in tree (for locate) but blank its name = purge text.
            node.name="";
            out.push(node);
            try{ window.__fbMap.set(id, new WeakRef(el)); }catch(e){}
        } else {
            out.push(node);
            try{ window.__fbMap.set(id, new WeakRef(el)); }catch(e){}
        }
    }
    return JSON.stringify({nodes:out, url:location.href, title:document.title,
        nodesAudited:audited, hiddenNodesPurged:purged, matchedRules:Object.keys(rulesHit)});
})();
"""#

    // Resolve + click: re-find node by @eN via WeakRef; click if alive + fingerprint match.
    // Args interpolated via __ARG__ placeholders (id, expectFp).
    public static let resolveClick = #"""
(function(){
    var id="__ARG__", expectFp="__ARG__";
    var ref=window.__fbMap && window.__fbMap.get(id);
    if(!ref) return JSON.stringify({ok:false, stale:true});
    var el=ref.deref();
    if(!el) return JSON.stringify({ok:false, stale:true});
    var tag=el.tagName.toLowerCase();
    var attrs=[]; var keep=["id","name","type","role","href","aria-label","placeholder","data-test"];
    for(var i=0;i<keep.length;i++){ var v=el.getAttribute(keep[i]); if(v) attrs.push(keep[i]+"="+v.substring(0,40)); }
    var txt=(el.innerText||"").trim().substring(0,24);
    var parts=[]; var cur=el; var depth=0;
    while(cur&&cur.nodeType===1&&depth<8){ var t=cur.tagName.toLowerCase(); var sib=cur.parentNode?Array.prototype.indexOf.call(cur.parentNode.children,cur):-1; parts.unshift(t+(sib>=0?("["+(sib+1)+"]"):"")); cur=cur.parentNode; depth++; }
    var fp=tag+"|"+attrs.join(",")+"|"+txt+"|"+parts.join("/");
    if(expectFp && fp!==expectFp) return JSON.stringify({ok:false, stale:true});
    el.scrollIntoView({block:"center"});
    el.click();
    return JSON.stringify({ok:true, stale:false});
})();
"""#

    // Resolve + type: re-find by @eN, set value, dispatch input event.
    // Args interpolated via __ARG__ placeholders (id, expectFp, text).
    public static let resolveType = #"""
(function(){
    var id="__ARG__", expectFp="__ARG__", text="__ARG__";
    var ref=window.__fbMap && window.__fbMap.get(id);
    if(!ref) return JSON.stringify({ok:false, stale:true});
    var el=ref.deref();
    if(!el) return JSON.stringify({ok:false, stale:true});
    el.focus();
    el.value=text;
    el.dispatchEvent(new Event("input",{bubbles:true}));
    el.dispatchEvent(new Event("change",{bubbles:true}));
    return JSON.stringify({ok:true, stale:false});
})();
"""#
}
