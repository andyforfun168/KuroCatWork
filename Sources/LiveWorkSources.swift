import AppKit
import WebKit
import SQLite3
import Darwin

struct LiveWindow: Codable {
    var used: Double
    var reset: Double?
    var remaining: CGFloat { CGFloat(max(0,min(100,100-used))/100) }
}
struct LiveQuota: Codable {
    var short: LiveWindow?
    var week: LiveWindow?
    var updated: Double = Date().timeIntervalSince1970
    var message = "尚未连接"
    var stale = true
    var source = ""
}
struct LiveTask {
    var key: String
    var tool: WorkTool
    var title: String
    var state: WorkState
    var started: Double
    var changed: Double
    var link: String
    var project: String
    var source: String
    var turnID:String? = nil
}
enum LiveParsing {
    static func timestamp(_ value: Any?) -> Double? {
        if let n=value as? NSNumber { guard n.doubleValue.isFinite else{return nil};return n.doubleValue>1e12 ? n.doubleValue/1000 : n.doubleValue }
        guard let s=value as? String else{return nil}
        let f=ISO8601DateFormatter();f.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        return (f.date(from:s) ?? ISO8601DateFormatter().date(from:s))?.timeIntervalSince1970
    }
    static func codexQuota(_ object:[String:Any])->LiveQuota? {
        let bucket:[String:Any]
        if let buckets=object["rateLimitsByLimitId"] as? [String:Any] {
            guard let value=buckets["codex"] as? [String:Any] else{return LiveQuota(message:"未提供通用额度",stale:false,source:"Codex app-server")}
            bucket=value
        } else if let value=object["rateLimits"] as? [String:Any] {bucket=value} else{return nil}
        var q=LiveQuota(message:"已连接",stale:false,source:"Codex app-server")
        for key in ["primary","secondary"] {
            guard let w=bucket[key] as? [String:Any],let used=(w["usedPercent"] as? NSNumber)?.doubleValue,used.isFinite,let duration=w["windowDurationMins"] as? Int else{continue}
            let window=LiveWindow(used:max(0,min(100,used)),reset:timestamp(w["resetsAt"]))
            if duration==300 {q.short=window};if duration==10080 {q.week=window}
        }
        return q
    }
    static func claudeQuota(_ object:[String:Any],source:String)->LiveQuota? {
        guard object.keys.contains("five_hour") || object.keys.contains("seven_day") else{return nil}
        var q=LiveQuota(message:"已连接",stale:false,source:source)
        func window(_ name:String)->LiveWindow? {
            guard let w=object[name] as? [String:Any],let used=(w["utilization"] as? NSNumber)?.doubleValue,used.isFinite else{return nil}
            return LiveWindow(used:max(0,min(100,used)),reset:timestamp(w["resets_at"]))
        }
        q.short=window("five_hour");q.week=window("seven_day");return q
    }
    static func allowedLink(_ string:String,tool:WorkTool)->URL? {
        guard let u=URL(string:string),u.user==nil,u.password==nil,u.port==nil else{return nil}
        if tool == .codex,u.scheme=="codex",u.host=="threads",UUID(uuidString:u.lastPathComponent) != nil {return u}
        if tool == .claude,u.scheme=="https",u.host=="claude.ai",u.path.hasPrefix("/chat/") || u.path.hasPrefix("/code/") {return u}
        return nil
    }
}

final class WorkCancellation {
    private let lock=NSLock()
    private var cancelled=false
    private var callbacks:[()->Void]=[]
    var valid:Bool {lock.lock();defer{lock.unlock()};return !cancelled}
    func add(_ callback:@escaping()->Void){lock.lock();if cancelled{lock.unlock();callback()}else{callbacks.append(callback);lock.unlock()}}
    func cancel(){lock.lock();cancelled=true;let handlers=callbacks;callbacks=[];lock.unlock();handlers.forEach{$0()}}
}

// Dedicated CLI child; no prompt/turn/write RPCs are ever sent. Output remains in memory.
final class CodexReadConnection {
    let process=Process(),input=Pipe(),output=Pipe()
    private var buffer=Data()
    private var nextID=0
    private var active=false
    private let lock=NSLock()
    static func binary(_ name:String)->URL? {
        let home=FileManager.default.homeDirectoryForCurrentUser.path
        let paths=(ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator:":").map(String.init)+[home+"/.npm-global/bin",home+"/.local/bin","/opt/homebrew/bin","/usr/local/bin","/usr/bin"]
        return paths.map {URL(fileURLWithPath:$0).appendingPathComponent(name)}.first {FileManager.default.isExecutableFile(atPath:$0.path)}
    }
    init?(cancellation:WorkCancellation? = nil) {
        guard let executable=Self.binary("codex") else{return nil}
        process.executableURL=executable;process.arguments=["app-server","--listen","stdio://"]
        process.standardInput=input;process.standardOutput=output;process.standardError=FileHandle.nullDevice
        // GUI PATH often omits node, which the npm launcher needs.
        var env=ProcessInfo.processInfo.environment
        env["PATH"]=executable.deletingLastPathComponent().path+":"+(env["PATH"] ?? "/usr/bin:/bin")+":/opt/homebrew/bin:/usr/local/bin"
        process.environment=env
        do {try process.run();active=true;cancellation?.add{[weak self] in self?.stop()}} catch{return nil}
        guard rpc("initialize",["clientInfo":["name":"kurocat_workingmode","title":"KuroCat WorkingMode","version":"1.4.4"],"capabilities":["experimentalApi":true]]) != nil else{stop();return nil}
        send(["method":"initialized"])
    }
    private func send(_ object:[String:Any]) {
        guard var data=try? JSONSerialization.data(withJSONObject:object) else{return};data.append(10)
        try? input.fileHandleForWriting.write(contentsOf:data)
    }
    func rpc(_ method:String,_ params:[String:Any]=[:])->[String:Any]? {
        lock.lock();let valid=active;lock.unlock();guard valid else{return nil}
        nextID+=1;let id=nextID;send(["id":id,"method":method,"params":params])
        let deadline=Date().addingTimeInterval(12)
        while Date()<deadline {
            while let end=buffer.firstIndex(of:10) {
                let line=buffer.prefix(upTo:end);buffer.removeSubrange(...end)
                if let object=(try? JSONSerialization.jsonObject(with:line)) as? [String:Any],object["id"] as? Int==id {return object["result"] as? [String:Any]}
            }
            lock.lock();let alive=active;lock.unlock();guard alive else{return nil}
            var descriptor=pollfd(fd:output.fileHandleForReading.fileDescriptor,events:Int16(POLLIN),revents:0)
            let ready=Darwin.poll(&descriptor,1,250)
            if ready<0 && errno==EINTR {continue};if ready<0 {return nil};if ready==0 {continue}
            let chunk=output.fileHandleForReading.availableData;guard !chunk.isEmpty else{return nil}
            buffer.append(chunk);if buffer.count>8*1024*1024{return nil}
        }
        return nil
    }
    func stop(){lock.lock();active=false;lock.unlock();if process.isRunning {process.terminate()}}
    deinit{stop()}
}

// Incremental transcript metadata only. Never parse or display message bodies/tool arguments.
final class LocalWorkSessions {
    struct Cursor {var offset:UInt64=0;var pending=Data();var start:Double=0;var changed:Double=0;var state:WorkState?;var turn="";var fileID:UInt64=0}
    var cursors:[String:Cursor]=[:]
    let home:URL
    init(home:URL=FileManager.default.homeDirectoryForCurrentUser){self.home=home}
    private func apply(_ line:Data.SubSequence,to c:inout Cursor,claude:Bool) {
        // Discard large message/attachment records before JSON decoding.
        let needles=claude ? ["\"user\"","\"assistant\""] : ["\"task_started\"","\"task_complete\"","\"turn_aborted\""]
        guard needles.contains(where:{line.range(of:Data($0.utf8)) != nil}),
              let obj=(try? JSONSerialization.jsonObject(with:line)) as? [String:Any] else{return}
        let time=LiveParsing.timestamp(obj["timestamp"]) ?? 0
        if claude {
            if obj["type"] as? String=="user",obj["isMeta"] as? Bool != true {
                let parts=(obj["message"] as? [String:Any])?["content"] as? [[String:Any]]
                if parts?.contains(where:{$0["type"] as? String=="tool_result"}) != true {c.start=time}
                c.state = .running;c.changed=time
            }
            if obj["type"] as? String=="assistant",let message=obj["message"] as? [String:Any],let reason=message["stop_reason"] as? String,["end_turn","stop_sequence"].contains(reason){c.state = .completed;c.changed=time}
        } else if obj["type"] as? String=="event_msg",let event=obj["payload"] as? [String:Any],let type=event["type"] as? String {
            let turn=event["turn_id"] as? String ?? ""
            switch type {
            case "task_started":c.state = .running;c.start=time;c.changed=time;c.turn=turn
            case "task_complete","turn_aborted":
                if c.turn.isEmpty || turn.isEmpty || turn==c.turn {c.state=type=="turn_aborted" ? .cancelled : .completed;c.changed=time;c.turn=turn}
            default:break
            }
        }
    }
    func activity(_ path:String,claude:Bool)->Cursor? {
        guard let attr=try? FileManager.default.attributesOfItem(atPath:path),let size=attr[.size] as? NSNumber,let handle=FileHandle(forReadingAtPath:path) else{return nil}
        defer{try? handle.close()}
        let identity=(attr[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let old=cursors[path],reset=old==nil || old!.offset>size.uint64Value || old!.fileID != identity
        var c=reset ? Cursor():old!;c.fileID=identity
        do {
            if reset && !claude {
                // Bootstrap from the end: long chats can contain gigabytes of images and tool output.
                // Read backwards until a complete lifecycle event is found; preserve split JSON lines.
                var end=size.uint64Value,carry=Data(),tailPending=Data(),first=true
                while end>0 {
                    let start=end>4*1024*1024 ? end-4*1024*1024:0
                    try handle.seek(toOffset:start)
                    guard var block=try handle.read(upToCount:Int(end-start)),block.count==Int(end-start) else{return nil}
                    block.append(carry)
                    var lines=block.split(separator:10,omittingEmptySubsequences:false)
                    if first {
                        if block.last != 10,let last=lines.popLast(){tailPending=Data(last)}
                        first=false
                    }
                    carry=Data()
                    if start>0,!lines.isEmpty {carry=Data(lines.removeFirst())}
                    for line in lines.reversed() {
                        var candidate=Cursor();apply(line,to:&candidate,claude:false)
                        if candidate.state != nil {
                            c.state=candidate.state;c.start=candidate.start;c.changed=candidate.changed;c.turn=candidate.turn
                            c.offset=size.uint64Value;c.pending=tailPending;cursors[path]=c;return c
                        }
                    }
                    if carry.count>8*1024*1024 {carry.removeAll()}
                    end=start
                }
                c.offset=size.uint64Value;c.pending=tailPending;cursors[path]=c;return c
            }
            try handle.seek(toOffset:c.offset)
            let end=min(size.uint64Value,c.offset+32*1024*1024)
            while c.offset<end {
                guard let chunk=try handle.read(upToCount:Int(min(262144,end-c.offset))),!chunk.isEmpty else{break}
                c.offset+=UInt64(chunk.count);c.pending.append(chunk)
                while let nl=c.pending.firstIndex(of:10) {
                    let line=c.pending.prefix(upTo:nl)
                    apply(line,to:&c,claude:claude)
                    c.pending.removeSubrange(...nl)
                }
                if c.pending.count>8*1024*1024 {c.pending.removeAll()}
            }
            cursors[path]=c;return c.offset>=size.uint64Value ? c:nil
        }catch{return nil}
    }
    func codex()->[LiveTask] {
        let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["CODEX_HOME"] ?? home.appendingPathComponent(".codex").path)
        guard let files=try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil),let dbFile=files.filter({$0.lastPathComponent.hasPrefix("state_") && $0.pathExtension=="sqlite"}).sorted(by:{$0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending}).first else{return []}
        var db:OpaquePointer?;guard sqlite3_open_v2(dbFile.path,&db,SQLITE_OPEN_READONLY|SQLITE_OPEN_NOMUTEX,nil)==SQLITE_OK else{if let db{sqlite3_close(db)};return []};defer{sqlite3_close(db)}
        sqlite3_busy_timeout(db,100);var stmt:OpaquePointer?
        let sql="SELECT id,COALESCE(name,title),rollout_path,cwd,updated_at,originator FROM threads WHERE archived=0 AND source IN ('cli','vscode','appServer') AND (thread_source IS NULL OR thread_source IN ('user','agent_created_thread')) ORDER BY updated_at DESC LIMIT 50"
        guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil)==SQLITE_OK else{return []};defer{sqlite3_finalize(stmt)}
        func string(_ n:Int32)->String {sqlite3_column_text(stmt,n).map{String(cString:$0)} ?? ""}
        var results:[LiveTask]=[]
        while sqlite3_step(stmt)==SQLITE_ROW {
            let id=string(0);guard UUID(uuidString:id) != nil,let a=activity(string(2),claude:false),let state=a.state else{continue}
            let updated=sqlite3_column_double(stmt,4)
            if state == .running && Date().timeIntervalSince1970-updated>6*3600 {continue}
            results.append(LiveTask(key:"codex:"+id,tool:.codex,title:String(string(1).prefix(120)),state:state,started:a.start,changed:a.changed,link:"codex://threads/"+id,project:URL(fileURLWithPath:string(3)).lastPathComponent,source:string(5)=="Codex Desktop" ? "CODEX DESKTOP" : "CODEX CLI",turnID:a.turn))
        }
        if cursors.count>160{cursors=cursors.filter{Date().timeIntervalSince1970-$0.value.changed<2*86400}}
        return results
    }
    func claude()->[LiveTask] {
        let root=home.appendingPathComponent(".claude/projects")
        guard let dirs=try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil) else{return []}
        var files:[URL]=[]
        for dir in dirs {files += (try? FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:[.contentModificationDateKey])) ?? []}
        func modified(_ url:URL)->Date {(try? url.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast}
        let recent=files.filter{$0.pathExtension=="jsonl"}.sorted{modified($0)>modified($1)}.prefix(25)
        var results:[LiveTask]=[]
        for file in recent {
            guard let a=activity(file.path,claude:true),let state=a.state,a.changed>0 else{continue}
            if state == .running && Date().timeIntervalSince1970-a.changed>6*3600 {continue}
            let id=file.deletingPathExtension().lastPathComponent
            results.append(LiveTask(key:"claude-cli:"+id,tool:.claude,title:"Claude Code · "+String(id.prefix(8)),state:state,started:a.start,changed:a.changed,link:"",project:file.deletingLastPathComponent().lastPathComponent,source:"CLAUDE CLI"))
        }
        return results
    }
}

final class ClaudeWebConnection:NSObject,WKNavigationDelegate {
    private(set) var web:WKWebView?
    private var loginWindow:NSWindow?
    private var loaded=false
    func prepare(){
        guard web==nil else{return}
        let config=WKWebViewConfiguration();config.websiteDataStore = .default()
        let view=WKWebView(frame:CGRect(x:0,y:0,width:900,height:720),configuration:config);view.navigationDelegate=self;web=view
        view.load(URLRequest(url:URL(string:"https://claude.ai")!))
    }
    func login(){
        prepare();guard let web else{return}
        if loginWindow==nil {let w=NSWindow(contentRect:CGRect(x:0,y:0,width:900,height:720),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false);w.title="连接 Claude · 请在 claude.ai 登录";w.isReleasedWhenClosed=false;w.contentView=web;w.center();loginWindow=w}
        loginWindow?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        web.load(URLRequest(url:URL(string:"https://claude.ai/login")!))
    }
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!){loaded=true}
    func suspend(){web?.evaluateJavaScript("window.__kurocatWorkAbort?.abort()",completionHandler:nil);web?.stopLoading()}
    func fetch(tracked:[String],includeUsage:Bool,done:@escaping([String:Any]?)->Void){
        guard let web,loaded else{done(nil);return}
        let ids=(try? String(data:JSONSerialization.data(withJSONObject:tracked),encoding:.utf8)) ?? "[]"
        let script="""
        window.__kurocatWorkAbort?.abort();const controller=new AbortController();window.__kurocatWorkAbort=controller;const deadline=setTimeout(()=>controller.abort(),18000);
        const get=async p=>{const r=await fetch(p,{credentials:'include',headers:{accept:'application/json','anthropic-version':'2023-06-01'},signal:controller.signal});if(!r.ok)throw Error('HTTP '+r.status);return r.json()};
        try{
          const orgs=await get('/api/organizations');if(!Array.isArray(orgs)||!orgs.length)return JSON.stringify({error:'请登录 Claude'});
          orgs.sort((a,b)=>{const rank=o=>(o.capabilities||[]).includes('claude_max')?0:(o.capabilities||[]).includes('claude_pro')?1:2;return rank(a)-rank(b)});
          const base='/api/organizations/'+encodeURIComponent(orgs[0].uuid),out={sessions:[],tasksOK:false};
          if(\(includeUsage ? "true" : "false")){try{out.usage=await get(base+'/usage')}catch(e){out.usageError=true}}
          const tracked=new Set(\(ids));
          const raw=await get(base+'/chat_conversations?limit=40');const chats=Array.isArray(raw)?raw:(raw.data||[]);
          await Promise.all([...tracked].filter(id=>!chats.some(c=>c.uuid===id)).slice(0,30).map(async id=>{try{chats.push(await get(base+'/chat_conversations/'+encodeURIComponent(id)))}catch(e){}}));
          for(const c of chats){const live=(c.live_status||'').toLowerCase();if(!live&&!tracked.has(c.uuid))continue;
            let req=0;if(c.workspace_session_id&&live){try{const d=await get('/v1/code/sessions/'+encodeURIComponent(c.workspace_session_id));req=((d.response_shape||d).requires_action_details_list||[]).length}catch(e){}}
            out.sessions.push({id:c.uuid,title:c.name||'Claude',live,req,start:c.live_status_started_at,end:c.last_settled_at,updated:c.updated_at,url:'https://claude.ai/chat/'+c.uuid,kind:'CLAUDE WEB'});
          }
          try{const raw=await get('/v1/code/sessions?exclude_tags=-&include_trigger_sessions=true&limit=40');const linked=new Set(chats.map(c=>c.workspace_session_id));for(const s of (raw.data||[]).slice(0,30)){if(!s.id||linked.has(s.id)||s.title==='__warming__'||(s.tags||[]).some(t=>t.startsWith('bard-conversation:')))continue;
            let x=s;const busy=s.status_bucket==='working'||s.status_bucket==='blocked';if(!busy&&!tracked.has(s.id))continue;try{const d=await get('/v1/code/sessions/'+encodeURIComponent(s.id));x=d.response_shape||d}catch(e){}
            const req=(x.requires_action_details_list||[]).length,bucket=(s.status_bucket||'').toLowerCase(),worker=(s.worker_status||'').toLowerCase();
            let live=req||bucket==='blocked'?'permission':bucket==='working'||(worker&&worker!=='idle')?'running':bucket==='failed'?'failed':bucket==='cancelled'?'cancelled':'';
            out.sessions.push({id:s.id,title:x.title||s.title||'Claude Code',live,req,start:s.created_at,end:x.last_event_at,updated:x.updated_at,url:'https://claude.ai/code/'+s.id.replace(/^cse_/,'session_'),kind:'CLAUDE CODE'});
          }}catch(e){}
          out.tasksOK=true;return JSON.stringify(out);
        }catch(e){return JSON.stringify({error:'Claude 网页尚未连接或接口暂不可用'})}finally{clearTimeout(deadline)}
        """
        web.callAsyncJavaScript(script,arguments:[:],in:nil,in:.page){result in
            switch result {case .success(let value):guard let string=value as? String,let data=string.data(using:.utf8),let object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else{done(nil);return};done(object)
            case .failure:done(nil)}
        }
    }
}

final class LiveWorkSources {
    var onQuota:((WorkTool,LiveQuota)->Void)?
    var onTasks:(([LiveTask])->Void)?
    var onDetectedProviders:(([WorkTool])->Void)?
    var automaticDetectionEnabled=false
    var onStatus:((String)->Void)?
    private let queue=DispatchQueue(label:"KuroCat.live.read",qos:.utility)
    private let usageQueue=DispatchQueue(label:"KuroCat.live.usage",qos:.utility)
    private var quotaBusy=false
    private let sessions=LocalWorkSessions()
    let claudeWeb=ClaudeWebConnection()
    private var cancellation=WorkCancellation()
    private var enabled=false
    private var generation=0
    private var tools:[WorkTool]=[]
    private var timer:Timer?
    private var busy=false
    private var webBusy=false
    private var lastUsage=Date.distantPast
    private var lastClaudeUsage=Date.distantPast
    private var cached:[String:LiveTask]=[:]
    private var sessionTasks:[LiveTask]=[]
    private var webTasks:[LiveTask]=[]
    var trackedClaude:[String]=[]
    func start(_ tools:[WorkTool]) {
        stop();sessionTasks=[];webTasks=[];enabled=true;cancellation=WorkCancellation();self.tools=tools;lastUsage = .distantPast;lastClaudeUsage = .distantPast
        if tools.contains(.claude){claudeWeb.prepare()}
        poll();timer=Timer.scheduledTimer(withTimeInterval:6,repeats:true){[weak self] _ in self?.poll()}
    }
    func stop(){enabled=false;cancellation.cancel();generation+=1;timer?.invalidate();timer=nil;quotaBusy=false;claudeWeb.suspend();busy=false;webBusy=false}
    func refresh(){lastUsage = .distantPast;lastClaudeUsage = .distantPast;poll()}
    private func report(_ items:[LiveTask]){onTasks?(items)}
    func poll(){
        guard enabled,!tools.isEmpty else{return}
        let gen=generation,selected=tools,token=cancellation,autoDetect=automaticDetectionEnabled
        let usage=Date().timeIntervalSince(lastUsage)>=60
        let claudeUsage=Date().timeIntervalSince(lastClaudeUsage)>=60
        if usage && selected.contains(.codex) && !quotaBusy {
            quotaBusy=true;lastUsage=Date()
            usageQueue.async{[weak self] in
                guard let self,token.valid else{return}
                let connection=CodexReadConnection(cancellation:token)
                let quota=connection?.rpc("account/rateLimits/read").flatMap{LiveParsing.codexQuota($0)} ?? LiveQuota(message:CodexReadConnection.binary("codex")==nil ? "未安装 Codex CLI":"Codex 未登录或连接失败")
                connection?.stop()
                DispatchQueue.main.async{guard self.generation==gen else{return};self.quotaBusy=false;self.onQuota?(.codex,quota)}
            }
        }
        if !busy {
            busy=true
            queue.async{[weak self] in
                guard let self,token.valid else{return};var tasks:[LiveTask]=[];var quotas:[WorkTool:LiveQuota]=[:]
                if selected.contains(.codex) {
                    guard token.valid else{return}
                    tasks+=self.sessions.codex()
                }
                if selected.contains(.claude),token.valid{
                    tasks+=self.sessions.claude()

                }
                for hook in WorkEventBridge.read() where selected.contains(hook.tool) {
                    if let i=tasks.firstIndex(where:{$0.key==hook.key}) {
                        if hook.tool == .codex {
                            // Transcript completion wins. Hooks from another turn never reopen an old turn.
                            guard tasks[i].state == .running,hook.turnID==tasks[i].turnID,hook.changed>=tasks[i].started else{continue}
                        } else if hook.changed<tasks[i].changed {continue}
                        tasks[i].state=hook.state;tasks[i].changed=hook.changed
                    } else if hook.tool == .claude {tasks.append(hook)}
                }
                let openTools=autoDetect ? OpenWorkTools.read():[]
                DispatchQueue.main.async{
                    guard self.generation==gen else{return};self.busy=false
                    if autoDetect{self.onDetectedProviders?(openTools)}
                    self.sessionTasks=tasks;for (tool,q) in quotas{self.onQuota?(tool,q)}
                    self.report(self.sessionTasks+self.webTasks)
                }
            }
        }
        if selected.contains(.claude),!webBusy {
            webBusy=true;if claudeUsage{lastClaudeUsage=Date()}
            claudeWeb.fetch(tracked:trackedClaude,includeUsage:claudeUsage){[weak self] result in
                guard let self,self.generation==gen else{return};self.webBusy=false
                if let result,let usage=result["usage"] as? [String:Any],let q=LiveParsing.claudeQuota(usage,source:"claude.ai"){self.onQuota?(.claude,q)}
                else if claudeUsage {self.claudeOAuth(gen:gen)}
                if let raw=result?["sessions"] as? [[String:Any]],result?["tasksOK"] as? Bool==true {
                    self.webTasks=raw.compactMap {o in
                        guard let id=o["id"] as? String,!id.isEmpty else{return nil}
                        let live=o["live"] as? String ?? "",state:WorkState
                        if (o["req"] as? Int ?? 0)>0 || ["permission","waiting_for_user","waiting_on_approval","blocked"].contains(live){state = .awaiting}
                        else if ["failed","error"].contains(live){state = .failed}
                        else if ["cancelled","aborted","stopped"].contains(live){state = .cancelled}
                        else if ["running","working","streaming","in_progress","busy","generating"].contains(live){state = .running}
                        else if live.isEmpty || ["done","idle","completed","settled","finished","none"].contains(live){state = .completed}
                        else{return nil} // New/unknown server states never fabricate running or approval.
                        let changed=LiveParsing.timestamp(o["end"]) ?? LiveParsing.timestamp(o["updated"]) ?? Date().timeIntervalSince1970
                        return LiveTask(key:"claude-web:"+id,tool:.claude,title:String((o["title"] as? String ?? "Claude").prefix(120)),state:state,started:LiveParsing.timestamp(o["start"]) ?? changed,changed:changed,link:o["url"] as? String ?? "",project:"",source:o["kind"] as? String ?? "CLAUDE WEB")
                    }
                    self.report(self.sessionTasks+self.webTasks)
                }
                self.onStatus?(result?["tasksOK"] as? Bool==true ? "本地任务＋Claude 网页已连接" : "本地任务监听中；Claude 网页请先登录")
            }
        } else if !selected.contains(.claude){onStatus?("本地任务监听中 · 审批需明确状态信号")}
    }
    private func claudeOAuth(gen:Int){
        let cancellation=self.cancellation
        usageQueue.async{[weak self] in
            guard let self,cancellation.valid else{return}
            var token:String?
            let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/security");p.arguments=["find-generic-password","-s","Claude Code-credentials","-w"]
            let out=Pipe();p.standardOutput=out;p.standardError=FileHandle.nullDevice
            var credential:Data?
            do{try p.run();cancellation.add{if p.isRunning{p.terminate()}}
                var descriptor=pollfd(fd:out.fileHandleForReading.fileDescriptor,events:Int16(POLLIN),revents:0)
                if Darwin.poll(&descriptor,1,15000)>0 {credential=out.fileHandleForReading.availableData}
                if p.isRunning{p.terminate()}
            }catch{}
            if credential==nil{credential=try? Data(contentsOf:FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json"))}
            if let credential,let object=(try? JSONSerialization.jsonObject(with:credential)) as? [String:Any],let oauth=object["claudeAiOauth"] as? [String:Any],let value=oauth["accessToken"] as? String {
                let expires=(oauth["expiresAt"] as? Double ?? 0)/1000
                if expires==0 || expires>Date().timeIntervalSince1970{token=value}
            }
            guard cancellation.valid else{return}
            guard let token else{DispatchQueue.main.async{if self.generation==gen{self.onQuota?(.claude,LiveQuota(message:"请连接 Claude 或登录 Claude Code"))}};return}
            var request=URLRequest(url:URL(string:"https://api.anthropic.com/api/oauth/usage")!);request.timeoutInterval=15
            request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization");request.setValue("oauth-2025-04-20",forHTTPHeaderField:"anthropic-beta");request.setValue("application/json",forHTTPHeaderField:"Accept")
            let task=URLSession.shared.dataTask(with:request){data,response,_ in
                let object=data.flatMap{(try? JSONSerialization.jsonObject(with:$0)) as? [String:Any]}
                let q=(response as? HTTPURLResponse)?.statusCode==200 ? object.flatMap{LiveParsing.claudeQuota($0,source:"Claude Code OAuth")} : nil
                DispatchQueue.main.async{if self.generation==gen{self.onQuota?(.claude,q ?? LiveQuota(message:"Claude 登录失效或额度暂不可用"))}}
            };cancellation.add{task.cancel()};if cancellation.valid{task.resume()}
        }
    }
}

extension WorkPanelDrawing {
    func drawLiveHover(_ c:CGContext,frame:CGRect,tool:WorkTool,quota:LiveQuota?) {
        let short=quota?.short != nil,h:CGFloat=short ? 140:89
        c.saveGState();c.translateBy(x:frame.minX,y:frame.minY);c.scaleBy(x:frame.width/108,y:frame.height/h)
        bubble(c,CGRect(x:0,y:0,width:108,height:h),tool.color,8,extruded:false)
        text(c,tool.title+" 额度",8,8,10,tool.color,true)
        let date=DateFormatter();date.dateFormat="HH:mm:ss"
        text(c,quota?.stale == false ? "已更新 "+date.string(from:Date(timeIntervalSince1970:quota!.updated)) : "等待连接 · "+(quota.map{"上次 "+date.string(from:Date(timeIntervalSince1970:$0.updated))} ?? "暂无数据"),8,24,6,NSColor.secondaryLabelColor)
        func section(_ title:String,_ window:LiveWindow?,_ y:CGFloat){
            text(c,title,8,y,8.5,ink,true)
            text(c,window.map{"剩余 "+String(Int(round(100-$0.used)))+"%"} ?? "N/A",8,y+12,12,tool.color,true)
            var label="重置时间不可用"
            if let reset=window?.reset {let s=max(0,Int(reset-Date().timeIntervalSince1970));label=s>=86400 ? "\(s/86400)天 \((s/3600)%24)小时后重置" : String(format:"%02d:%02d:%02d 后重置",s/3600,(s/60)%60,s%60)}
            text(c,label,8,y+29,7.5,ink)
        }
        if short{section("短周期",quota?.short,40);section("本周",quota?.week,90)}else{section("本周",quota?.week,40)}
        if quota?.short == nil && quota?.week == nil {text(c,String((quota?.message ?? "请先连接账户").prefix(19)),8,h-8,5.4,NSColor.secondaryLabelColor)}
        c.restoreGState()
    }
}

// Optional Claude Code event bridge. Installed only from the connection dialog's explicit button.
// The hook writes sanitized metadata; it always exits successfully and never returns an approval.
enum WorkEventBridge {
    static var directory:URL {FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/KuroCat/work-events")}
    static func handle(_ raw:Data,root:URL=directory,now:Double=Date().timeIntervalSince1970,tool:WorkTool = .claude){
        guard raw.count<4*1024*1024,let object=(try? JSONSerialization.jsonObject(with:raw)) as? [String:Any],let id=object["session_id"] as? String,UUID(uuidString:id) != nil,let event=object["hook_event_name"] as? String else{return}
        if tool == .codex,let path=object["transcript_path"] as? String,!path.isEmpty,!URL(fileURLWithPath:path).lastPathComponent.contains(id){return}
        try? FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let descriptor=open(root.appendingPathComponent(".lock").path,O_CREAT|O_RDWR,0o600)
        guard descriptor>=0 else{return};defer{flock(descriptor,LOCK_UN);close(descriptor)}
        guard flock(descriptor,LOCK_EX)==0 else{return}
        let file=root.appendingPathComponent(tool.rawValue+"-"+id+".json")
        let data=try? Data(contentsOf:file);var value=(data.flatMap{(try? JSONSerialization.jsonObject(with:$0)) as? [String:Any]}) ?? [:]
        guard object["agent_id"] == nil else{return}
        let turn=object["turn_id"] as? String ?? ""
        if !turn.isEmpty,value["turn"] as? String != turn {value=["turn":turn,"started":now]}
        if let turn=object["turn_id"] as? String {value["turn"]=turn}
        var state=value["state"] as? String ?? "running"
        switch event {
        case "UserPromptSubmit":state="running";value["started"]=now
        case "PermissionRequest":state="awaiting"
        case "Notification":
            guard ["permission_prompt","elicitation_dialog"].contains(object["notification_type"] as? String ?? "") else{return};state="awaiting"
        case "PreToolUse":if (object["tool_name"] as? String)=="AskUserQuestion"{state="awaiting"}else if state != "awaiting"{state="running"}
        case "PostToolUse","PostToolUseFailure":state="running"
        case "StopFailure":state="failed"
        case "Interrupt":state="cancelled"
        case "Stop":state="completed"
        case "SessionEnd":if state != "completed" {state="cancelled"}
        default:return
        }
        if value["state"] as? String != state{value["changed"]=now}
        value["tool"]=tool.rawValue;value["state"]=state;value["updated"]=now;value["id"]=id;value["cwd"]=object["cwd"] as? String ?? ""
        if value["started"]==nil{value["started"]=now}
        if let encoded=try? JSONSerialization.data(withJSONObject:value){try? encoded.write(to:file,options:.atomic)}
    }
    static func read(root:URL=directory)->[LiveTask]{
        guard let files=try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil) else{return []}
        return files.prefix(300).compactMap{file in
            guard file.pathExtension=="json",let data=try? Data(contentsOf:file),data.count<8192,let o=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],let id=o["id"] as? String,UUID(uuidString:id) != nil,let raw=o["state"] as? String,let state=WorkState(rawValue:raw) else{return nil}
            let updated=o["updated"] as? Double ?? 0
            if Date().timeIntervalSince1970-updated>6*3600 && (state == .running || state == .awaiting){return nil}
            let tool=WorkTool(rawValue:o["tool"] as? String ?? "claude") ?? .claude
            return LiveTask(key:(tool == .codex ? "codex:" : "claude-cli:")+id,tool:tool,title:tool == .codex ? "Codex" : "Claude Code",state:state,started:o["started"] as? Double ?? updated,changed:o["changed"] as? Double ?? updated,link:tool == .codex ? "codex://threads/"+id : "",project:URL(fileURLWithPath:o["cwd"] as? String ?? "").lastPathComponent,source:tool == .codex ? "CODEX" : "CLAUDE CLI",turnID:o["turn"] as? String)
        }
    }
    static func install(tool:WorkTool = .claude)throws {
        let fm=FileManager.default,base=directory.deletingLastPathComponent(),exe=base.appendingPathComponent("work-event-bridge"),settings=tool == .codex ? URL(fileURLWithPath:ProcessInfo.processInfo.environment["CODEX_HOME"] ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path).appendingPathComponent("hooks.json") : fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        guard let binary=Bundle.main.executableURL else{throw NSError(domain:"KuroCat",code:1)}
        try fm.createDirectory(at:base,withIntermediateDirectories:true)
        var existing:[String:Any]=[:];var original:Data?
        if fm.fileExists(atPath:settings.path){let data=try Data(contentsOf:settings);guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw NSError(domain:"KuroCat",code:2)};existing=object;original=data}
        if existing["hooks"] != nil && !(existing["hooks"] is [String:Any]){throw NSError(domain:"KuroCat.InvalidHookSettings",code:3)}
        var hooks=existing["hooks"] as? [String:Any] ?? [:]
        let command="'"+exe.path.replacingOccurrences(of:"'",with:"'\\''")+"' --work-"+tool.rawValue+"-event"
        let events=tool == .codex ? ["UserPromptSubmit","PermissionRequest","PostToolUse","Stop","Interrupt","SessionEnd"] : ["UserPromptSubmit","PermissionRequest","Notification","PreToolUse","PostToolUse","PostToolUseFailure","Stop","StopFailure","SessionEnd"]
        for event in events {
            if hooks[event] != nil && !(hooks[event] is [[String:Any]]) {throw NSError(domain:"KuroCat.InvalidHookSettings",code:4)}
            var list=(hooks[event] as? [[String:Any]] ?? []).compactMap{ original -> [String:Any]? in
                guard let handlers=original["hooks"] as? [[String:Any]] else{return original}
                var group=original;let kept=handlers.filter{!($0["command"] as? String ?? "").contains("KuroCat/work-event-bridge")}
                if kept.isEmpty && !handlers.isEmpty{return nil};group["hooks"]=kept;return group
            }
            list.append(["matcher":"*","hooks":[["type":"command","command":command,"timeout":3]]]);hooks[event]=list
        }
        existing["hooks"]=hooks
        // Validate everything before replacing our own bridge or writing settings.
        let encoded=try JSONSerialization.data(withJSONObject:existing,options:[.prettyPrinted,.sortedKeys])
        let staged=base.appendingPathComponent("work-event-bridge-"+UUID().uuidString)
        try fm.copyItem(at:binary,to:staged);try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:staged.path)
        if fm.fileExists(atPath:exe.path){_ = try fm.replaceItemAt(exe,withItemAt:staged)}else{try fm.moveItem(at:staged,to:exe)}
        try fm.createDirectory(at:settings.deletingLastPathComponent(),withIntermediateDirectories:true)
        if let original{try original.write(to:base.appendingPathComponent(tool.rawValue+"-settings-before-"+UUID().uuidString+".json"),options:.withoutOverwriting)}
        try encoded.write(to:settings,options:.atomic)
    }
}
extension WorkModeExperience {
    func installClaudeHooks(tool:WorkTool = .claude){
        let alert=NSAlert()
        do{try WorkEventBridge.install(tool:tool);alert.messageText=tool.title+" 事件监听已添加";alert.informativeText=tool == .codex ? "请在 Codex 的 Settings → Hooks（CLI 使用 /hooks）审核并信任这个只记录状态的 hook，然后重新打开会话。不会代替你批准任务。原有 hooks 与设置已保留，并保存备份。" : "请重新打开 Claude Code 会话。原有设置与其他 hooks 已保留，备份位于 ~/Library/Application Support/KuroCat/。"}
        catch{alert.messageText="未能启用事件监听";alert.informativeText="原设置不会被无效 JSON 覆盖。请检查 Claude Code 设置文件与目录权限。"}
        alert.runModal()
    }
}

// Process names only; no command arguments, prompts, or terminal contents are read.
enum OpenWorkTools {
    struct Entry {var pid:Int;var parent:Int;var executable:String}
    static func providers(_ entries:[Entry],ownPID:Int)->[WorkTool] {
        var excluded=Set([ownPID]),changed=true
        while changed {let old=excluded.count;for p in entries where excluded.contains(p.parent){excluded.insert(p.pid)};changed=old != excluded.count}
        var found=Set<WorkTool>()
        for entry in entries where !excluded.contains(entry.pid) {
            let path=entry.executable.lowercased(),name=URL(fileURLWithPath:path).lastPathComponent
            if name=="claude" || path.contains("/claude.app/contents/macos/") || path.contains("/.local/share/claude/versions/"){found.insert(.claude)}
            if name=="codex" || path.contains("/codex.app/contents/macos/"){found.insert(.codex)}
        }
        return WorkTool.allCases.filter{found.contains($0)}
    }
    static func read()->[WorkTool] {
        let p=Process(),pipe=Pipe();p.executableURL=URL(fileURLWithPath:"/bin/ps");p.arguments=["-axo","pid=,ppid=,comm="];p.standardOutput=pipe;p.standardError=FileHandle.nullDevice
        do{try p.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit();guard p.terminationStatus==0,let text=String(data:data,encoding:.utf8) else{return []}
            let entries=text.split(separator:"\n").compactMap{line -> Entry? in
                let fields=line.split(maxSplits:2,whereSeparator:{$0==" " || $0=="\t"})
                guard fields.count==3,let pid=Int(fields[0]),let parent=Int(fields[1]) else{return nil}
                return Entry(pid:pid,parent:parent,executable:String(fields[2]))
            }
            return providers(entries,ownPID:Int(ProcessInfo.processInfo.processIdentifier))
        }catch{return []}
    }
}
