import AppKit

// Real account limits and session metadata; ordinary mode does not poll AI sources.
enum WorkTool: String, Codable, CaseIterable {
    case codex, claude
    var title: String { self == .codex ? "Codex" : "Claude" }
    var color: NSColor { self == .codex ? NSColor(calibratedRed:0.22,green:0.56,blue:0.91,alpha:1) : NSColor(calibratedRed:0.91,green:0.50,blue:0.25,alpha:1) }
}
enum WorkState: String, Codable { case running, awaiting, completed, failed, cancelled }
struct WorkTaskRecord: Codable {
    var id: Int
    var tool: WorkTool
    var title: String
    var state: WorkState
    var started: Double
    var changed: Double
    var read = false
    var key: String?
    var link: String?
    var project: String?
    var source: String?
}
struct WorkPromotion {
    var badgeID: Int
    var color: NSColor
    var captured: Double?
    var source = CGPoint.zero
    var rotation: CGFloat = 0
    var velocity = CGPoint.zero
}
struct WorkInteractionPolicy {
    static func autonomousTyping(running: Bool, waiting: Bool, dragging: Bool, petting: Bool, realTyping: Bool) -> Bool {
        running && !waiting && !dragging && !petting
    }
}
final class WorkModeExperience: NSObject {
    static let shared = WorkModeExperience()
    static let firstHintSeenKey="KuroCat.WorkModeGestureHintSeen.v2"
    weak var parent: OverlayWindow?
    let live=LiveWorkSources()
    var quotas:[WorkTool:LiveQuota]=[:]
    var connectionStatus="连接中…"
    private var nextTaskID=10
    private var knownTurns:[String:Double]=[:]
    private var pendingBirths:[Int]=[]
    private var seenSources=Set<String>()
    private var connectionGeneration=0
    private var loginProcess:Process?
    private var loginWindow:NSWindow?
    private var loginText:NSTextView?
    private var connectionStarted=Date().timeIntervalSince1970
    private var panel: NSPanel?
    private var tooltip: NSPanel?
    private var firstHint:NSPanel?
    private var panelView: WorkPanelView?
    private var tooltipView: WorkTooltipView?
    var tasks: [WorkTaskRecord] = []
    var carryoverTaskKeys=Set<String>()
    var promotions: [Int:WorkPromotion] = [:]
    var fading: [Int:Double] = [:]
    var elapsed: Double = 0
    var center = CGPoint(x:195,y:320)
    var angle: CGFloat = 0.055
    var singleWidth: CGFloat = 190
    var quotaX: CGFloat = 0
    var drawing: WorkPanelDrawing?
    static let canvasPadding:CGFloat=180
    var scale: CGFloat = 1
    var pickupStart: Double?
    var wasDragging = false
    private var lastMode = false
    private var exitFadeElapsed:Double?
    var isTransitioning:Bool { exitFadeElapsed != nil }
    var exitOpacity:CGFloat {
        guard let elapsed=exitFadeElapsed else{return 1}
        let u=max(0,min(1,elapsed/0.55))
        return CGFloat(1-u*u*(3-2*u))
    }
    static func taskOpacity(age:Double)->CGFloat {
        let u=max(0,min(1,age/0.8))
        return CGFloat(1-u*u*(3-2*u))
    }
    private var emitted = Set<Int>()
    private var lastAutoKey: Double = -100
    private var previousSynthetic = Set<PhysicalKey>()
    private var typingCadence=WorkTypingCadence()
    private var autoTypingPhase:Double=0
    private var emotionStart: Double = 0
    private var nextEmotion: Double = Double.random(in:45...75)
    private var quietUntil: Double = 0
    private var emotion = 0
    private var previousDizzy: CGFloat = 0
    private var recoveryStart: Double?
    private var lastBusy: Double = 0
    private var hovered: WorkTool?
    private var hoverLeftAt: Double = 0
    var showsAllTasks = false
    var automaticTools:Bool {UserDefaults.standard.string(forKey:"KuroCat.WorkTools")=="auto"}
    var detectedTools:[WorkTool] {
        get {(UserDefaults.standard.stringArray(forKey:"KuroCat.AutoDetectedTools") ?? []).compactMap{WorkTool(rawValue:$0)}}
        set {UserDefaults.standard.set(newValue.map{$0.rawValue},forKey:"KuroCat.AutoDetectedTools")}
    }
    static func detectedProviders(previous:[WorkTool],tasks:[LiveTask])->[WorkTool] {
        let busy=Set(tasks.filter{$0.state == .running || $0.state == .awaiting}.map{$0.tool})
        return WorkTool.allCases.filter{previous.contains($0) || busy.contains($0)}
    }
    private var monitoredTools:[WorkTool] {automaticTools ? WorkTool.allCases:tools}
    var tools: [WorkTool] {
        switch UserDefaults.standard.string(forKey:"KuroCat.WorkTools") {
        case "auto": return detectedTools
        case "claude": return [.claude]
        case "both": return [.codex,.claude]
        default: return [.codex]
        }
    }
    var visibleTasks: [WorkTaskRecord] {
        tasks.filter { tools.contains($0.tool) && (!$0.read || fading[$0.id] != nil) }.sorted {
            func rank(_ state: WorkState)->Int { state == .awaiting ? 0 : (state == .running ? 1 : 2) }
            let a=rank($0.state),b=rank($1.state)
            return a == b ? $0.id < $1.id : a < b
        }
    }
    var waiting: Bool { visibleTasks.contains { $0.state == .awaiting } }
    var ignoresPhysicalKeyboard: Bool {
        CatSettings.shared.isWorkMode && CatSettings.shared.workAutoTyping && !waiting && visibleTasks.contains{$0.state == .running}
    }
    var allowsPetting: Bool { !CatSettings.shared.isWorkMode || !waiting }
    static func workSpinAdvance(dt:CGFloat,workDizzy:CGFloat,recoveringSpiral:Bool,naturalDizzy:CGFloat)->CGFloat {
        (workDizzy>0.01 || recoveringSpiral) && naturalDizzy<=0.01 ? min(dt,0.05)*7.5 : 0
    }
    func attach(to window: OverlayWindow) {
        parent=window
        drawing=WorkPanelDrawing(window.catView.physics)
        if let data=UserDefaults.standard.data(forKey:"KuroCat.WorkLiveTasks"),
           let saved=try? JSONDecoder().decode([WorkTaskRecord].self,from:data) { tasks=saved }
        carryoverTaskKeys=Set(UserDefaults.standard.stringArray(forKey:"KuroCat.WorkCarryoverTasks") ?? [])
        nextTaskID=max(10,(tasks.map{$0.id}.max() ?? 9)+1)
        if let data=UserDefaults.standard.data(forKey:"KuroCat.WorkLiveQuotas"),let saved=try? JSONDecoder().decode([WorkTool:LiveQuota].self,from:data) {quotas=saved.mapValues{q in var q=q;q.stale=true;q.message="上次数据 · 等待刷新";return q}}
        live.onQuota={ [weak self] tool,quota in
            guard let self else{return}
            if quota.stale,var old=self.quotas[tool] {old.stale=true;old.message=quota.message;self.quotas[tool]=old}
            else {self.quotas[tool]=quota}
            if let data=try? JSONEncoder().encode(self.quotas){UserDefaults.standard.set(data,forKey:"KuroCat.WorkLiveQuotas")}
        }
        live.onDetectedProviders={ [weak self] providers in self?.discoverTools(providers) }
        live.onTasks={ [weak self] items in self?.mergeLive(items) }
        live.onStatus={ [weak self] value in self?.connectionStatus=value }
        let p=NSPanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        p.isOpaque=false;p.backgroundColor = .clear;p.hasShadow=false;p.hidesOnDeactivate=false;p.isReleasedWhenClosed=false
        p.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.stationary,.ignoresCycle]
        let v=WorkPanelView();v.owner=self;p.contentView=v
        panel=p;panelView=v;window.addChildWindow(p,ordered:.above);p.orderOut(nil)
        let tip=NSPanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        tip.isOpaque=false;tip.backgroundColor = .clear;tip.hasShadow=false;tip.hidesOnDeactivate=false;tip.isReleasedWhenClosed=false;tip.ignoresMouseEvents=true
        tip.collectionBehavior=p.collectionBehavior
        let tv=WorkTooltipView();tv.owner=self;tip.contentView=tv;tooltip=tip;tooltipView=tv
        window.addChildWindow(tip,ordered:.above);tip.orderOut(nil)
        let hint=NSPanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        hint.isOpaque=false;hint.backgroundColor = .clear;hint.hasShadow=false;hint.hidesOnDeactivate=false;hint.isReleasedWhenClosed=false;hint.ignoresMouseEvents=true
        hint.collectionBehavior=p.collectionBehavior
        let view=WorkFirstHintView();view.owner=self;hint.contentView=view
        firstHint=hint;window.addChildWindow(hint,ordered:.above);hint.orderOut(nil)
    }
    func persist() {
        UserDefaults.standard.set(Array(carryoverTaskKeys),forKey:"KuroCat.WorkCarryoverTasks")
        if let data=try? JSONEncoder().encode(tasks) { UserDefaults.standard.set(data,forKey:"KuroCat.WorkLiveTasks") }
    }
    func chooseToolsIfNeeded() {
        guard UserDefaults.standard.string(forKey:"KuroCat.WorkTools") == nil else { return }
        let a=NSAlert();a.messageText="工作模式 · 本地体验"
        a.informativeText="请选择展示的工具。额度通过已有登录连接读取；任务只读本机会话和 Claude 网页状态。打开处理只跳转，不执行审批。普通模式不监听任务。"
        a.addButton(withTitle:"仅 Codex");a.addButton(withTitle:"仅 Claude");a.addButton(withTitle:"两者都显示");a.addButton(withTitle:"自动识别")
        let r=a.runModal()
        let value=r == .alertFirstButtonReturn ? "codex" : (r == .alertSecondButtonReturn ? "claude" : (r == .alertThirdButtonReturn ? "both":"auto"))
        UserDefaults.standard.set(value,forKey:"KuroCat.WorkTools")
    }
    func menuItem()->NSMenuItem {
        let item=NSMenuItem(title:"工作模式 · 真实连接",action:nil,keyEquivalent:"")
        let m=NSMenu()
        for (title,value) in [("自动识别正在使用的工具","auto"),("仅 Codex","codex"),("仅 Claude","claude"),("同时显示 Codex 和 Claude","both")] {
            let i=NSMenuItem(title:title,action:#selector(selectTools(_:)),keyEquivalent:"");i.target=self;i.representedObject=value
            i.state=UserDefaults.standard.string(forKey:"KuroCat.WorkTools") == value ? .on : .off;m.addItem(i)
        }
        m.addItem(.separator())
        let refresh=NSMenuItem(title:"立即刷新额度与任务",action:#selector(refreshLive),keyEquivalent:"");refresh.target=self;m.addItem(refresh)
        let codex=NSMenuItem(title:"登录 Codex…",action:#selector(signInCodex),keyEquivalent:"");codex.target=self;m.addItem(codex)
        let claude=NSMenuItem(title:"连接 Claude 网页…",action:#selector(signInClaude),keyEquivalent:"");claude.target=self;m.addItem(claude)
        let hook=NSMenuItem(title:"连接说明与任务监听…",action:#selector(connectionHelp),keyEquivalent:"");hook.target=self;m.addItem(hook)
        let emote=NSMenuItem(title:"自主打字随机表情",action:#selector(toggleEmotions),keyEquivalent:"");emote.target=self;emote.state=emotionsEnabled ? .on : .off;m.addItem(emote)
        let sound=NSMenuItem(title:"开启工作模式声音",action:#selector(toggleSound),keyEquivalent:"");sound.target=self;sound.state=soundEnabled ? .on : .off;m.addItem(sound)
        item.submenu=m;return item
    }
    var soundEnabled: Bool { UserDefaults.standard.bool(forKey:"KuroCat.WorkSounds") }
    func setSoundEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled,forKey:"KuroCat.WorkSounds")
        WorkSounds.shared.configure(enabled:enabled,workMode:CatSettings.shared.isWorkMode)
    }
    @objc private func toggleSound(){setSoundEnabled(!soundEnabled)}
    var emotionsEnabled: Bool {
        UserDefaults.standard.object(forKey:"KuroCat.WorkRandomExpressions") as? Bool
            ?? UserDefaults.standard.object(forKey:"KuroCat.WorkEmotions") as? Bool ?? true
    }
    func setEmotionsEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled,forKey:"KuroCat.WorkRandomExpressions")
        emotion=0;nextEmotion=elapsed+Double.random(in:45...75)
    }
    func hasShort(_ tool:WorkTool)->Bool { quotas[tool]?.short != nil }
    @objc private func refreshLive(){if CatSettings.shared.isWorkMode{live.refresh()}}
    @objc private func signInClaude(){live.claudeWeb.login()}
    @objc private func connectionHelp(){
        let a=NSAlert();a.messageText="真实连接 · 只读监听"
        a.informativeText="现已读取真实额度和本地运行／结束记录。要显示准确的等待批准状态，可添加只记录任务状态的 hook。将保留原有设置并备份；不会批准或阻止任何操作。Codex 添加后还需在其 Settings → Hooks 审核信任。Claude 网页聊天请使用“连接 Claude 网页”。"
        a.addButton(withTitle:"启用 Codex 任务监听");a.addButton(withTitle:"启用 Claude Code 任务监听");a.addButton(withTitle:"关闭")
        let result=a.runModal()
        if result == .alertFirstButtonReturn{installClaudeHooks(tool:.codex)}
        else if result == .alertSecondButtonReturn{installClaudeHooks(tool:.claude)}
    }
    @objc private func signInCodex(){
        guard loginProcess==nil,let binary=CodexReadConnection.binary("codex") else{let a=NSAlert();a.messageText="未找到 Codex CLI，或登录窗口已打开";a.runModal();return}
        let process=Process(),pipe=Pipe();process.executableURL=binary;process.arguments=["login"];process.standardOutput=pipe;process.standardError=pipe
        var env=ProcessInfo.processInfo.environment;env["PATH"]=binary.deletingLastPathComponent().path+":"+(env["PATH"] ?? "/usr/bin:/bin")+":/opt/homebrew/bin:/usr/local/bin";process.environment=env
        let w=NSWindow(contentRect:CGRect(x:0,y:0,width:560,height:210),styleMask:[.titled,.closable],backing:.buffered,defer:false);w.title="Codex 登录 · 请完成浏览器授权";w.isReleasedWhenClosed=false
        let scroll=NSScrollView(frame:w.contentView!.bounds);scroll.autoresizingMask=[.width,.height];scroll.hasVerticalScroller=true
        let view=NSTextView(frame:scroll.bounds);view.isEditable=false;view.isSelectable=true;view.font=NSFont.systemFont(ofSize:13);view.textContainerInset=NSSize(width:14,height:14);scroll.documentView=view;w.contentView?.addSubview(scroll)
        loginWindow=w;loginText=view;loginProcess=process
        pipe.fileHandleForReading.readabilityHandler={ [weak self] h in let data=h.availableData;guard !data.isEmpty else{return};DispatchQueue.main.async{guard let self else{return};let text=String(data:data,encoding:.utf8) ?? "";self.loginText?.string.append(text);self.loginText?.checkTextInDocument(nil)}}
        process.terminationHandler={ [weak self] _ in pipe.fileHandleForReading.readabilityHandler=nil;DispatchQueue.main.async{self?.loginProcess=nil;self?.loginText?.string.append("\n登录命令已结束，可以关闭窗口并点击立即刷新。");self?.live.refresh()}}
        do{try process.run();w.center();w.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}catch{loginProcess=nil;view.string="无法启动登录；可在终端运行 codex login。";w.makeKeyAndOrderFront(nil)}
    }
    @objc private func toggleEmotions(){setEmotionsEnabled(!emotionsEnabled)}
    @objc private func selectTools(_ item:NSMenuItem){
        UserDefaults.standard.set(item.representedObject as? String,forKey:"KuroCat.WorkTools")
        if CatSettings.shared.isWorkMode {
            for t in tools{let i=t == .codex ? 0:1;promotions[i]=WorkPromotion(badgeID:-1,color:t.color,captured:elapsed-2)}
            live.automaticDetectionEnabled=automaticTools;live.start(monitoredTools)
        }
    }
    func discoverTools(_ providers:[WorkTool]) {
        guard CatSettings.shared.isWorkMode,automaticTools else{return}
        let previous=detectedTools
        detectedTools=WorkTool.allCases.filter{previous.contains($0) || providers.contains($0)}
        for tool in detectedTools where !previous.contains(tool) {
            let id=tool == .codex ? 0:1
            promotions.removeValue(forKey:id)
            if !pendingBirths.contains(id){pendingBirths.append(id)}
        }
    }
    func mergeLive(_ items:[LiveTask]) {
        guard CatSettings.shared.isWorkMode else{return}
        let now=Date().timeIntervalSince1970
        discoverTools(Self.detectedProviders(previous:[],tasks:items))
        let initialSources=Set(items.map{$0.source}).subtracting(seenSources)
        for item in items {
            let busy=item.state == .running || item.state == .awaiting
            if let i=tasks.firstIndex(where:{$0.key==item.key}) {
                let newer=item.started>tasks[i].started+1
                if newer {tasks[i].read=false;tasks[i].started=item.started;pendingBirths.append(tasks[i].id);emitted.remove(tasks[i].id);promotions.removeValue(forKey:tasks[i].id)}
                if tasks[i].state != item.state {tasks[i].changed=now}
                if tasks[i].state == .awaiting && item.state != .awaiting {quietUntil=elapsed+2.5;emotion=0;nextEmotion=elapsed+Double.random(in:45...75)}
                if carryoverTaskKeys.contains(item.key) {
                    if newer || item.state == .running {carryoverTaskKeys.remove(item.key)}
                    else if item.state != .awaiting && item.state != .failed {
                        tasks[i].read=true;fading[tasks[i].id]=elapsed;carryoverTaskKeys.remove(item.key)
                    }
                }
                tasks[i].state=item.state;tasks[i].title=item.title;tasks[i].link=item.link;tasks[i].project=item.project;tasks[i].source=item.source
            } else if busy || item.changed>=connectionStarted {
                let id=nextTaskID;nextTaskID+=1
                tasks.append(WorkTaskRecord(id:id,tool:item.tool,title:item.title,state:item.state,started:item.started>0 ? item.started:now,changed:busy ? now:item.changed,key:item.key,link:item.link,project:item.project,source:item.source))
                if initialSources.contains(item.source){promotions[id]=WorkPromotion(badgeID:-1,color:item.tool.color,captured:elapsed-2)}
                else {pendingBirths.append(id)}
            }
        }
        seenSources.formUnion(items.map{$0.source})
        // Terminal historical conversations are not flooded into a new installation.
        tasks=tasks.filter{!$0.read || now-$0.changed<7*86400}
        live.trackedClaude=tasks.filter{$0.key?.hasPrefix("claude-web:")==true && !$0.read}.compactMap{$0.key?.replacingOccurrences(of:"claude-web:",with:"")}
        persist()
    }
    func step(dt:CGFloat,window:OverlayWindow) {
        let p=window.catView.physics,engine=InputEngine.shared,active=CatSettings.shared.isWorkMode
        WorkSounds.shared.configure(enabled:soundEnabled,workMode:active)
        if active != lastMode {
            if active {
                exitFadeElapsed=nil
                chooseToolsIfNeeded();lastBusy=elapsed
                typingCadence.reset();autoTypingPhase=0
                emotion=0;nextEmotion=elapsed+Double.random(in:45...75)
            } else {
                prepareForModeExit()
                for promotion in promotions.values { p.floatingKeycaps.removeAll{$0.id==promotion.badgeID} }
                exitFadeElapsed=0;CatRenderer.workPromotionColors=[:];recoveryStart=nil
                CatRenderer.recoveryBlink=0;CatRenderer.recoverySpiral=nil;CatRenderer.workDizzyAmount=0
                p.previewAwaiting=false;p.workRealTyping=false;p.workReminderAnger=false;p.workExpressionAnger=0;p.workKeepsAwake=false;p.previewAwaitingAnger=0;p.previewTypingKPM=nil;p.previewWorkAngerEnvelope=nil
                panel?.ignoresMouseEvents=true;tooltip?.orderOut(nil);hovered=nil;previousSynthetic=[];pickupStart=nil;p.clearWorkTypingMemory();persist()
            }
            if active {
                connectionStarted=Date().timeIntervalSince1970;seenSources=[];pendingBirths=[]
                for t in visibleTasks {promotions[t.id]=WorkPromotion(badgeID:-1,color:t.tool.color,captured:elapsed-2)}
                for t in tools {let i=t == .codex ? 0:1;promotions.removeValue(forKey:i);pendingBirths.append(i)}
                live.automaticDetectionEnabled=automaticTools;live.start(monitoredTools)
            } else {live.stop()}
            lastMode=active
            if active {lastBusy=elapsed}
        }
        guard active else {
            p.step(dt:dt,windowFrameInScreen:window.frame)
            updateFirstHint(window:window)
            if let fade=exitFadeElapsed {
                exitFadeElapsed=fade+Double(min(dt,0.05))
                if exitOpacity>0 {updatePanels(window:window,dragging:window.catView.isDraggingOrResizing)}
                else {exitFadeElapsed=nil;promotions=[:];emitted=[];fading=[:];panel?.orderOut(nil)}
            }
            return
        }
        elapsed+=Double(min(dt,0.05))
        let dragging=window.catView.isDraggingOrResizing || p.isScruffDragging
        if dragging && !wasDragging { pickupStart=elapsed;tooltip?.orderOut(nil);WorkSounds.shared.pickup() }
        wasDragging=dragging
        let petting=p.petHeadIntensity>0.05 || p.petBodyIntensity>0.05
        engine.pollMouse(dt:dt)
        let now=CACurrentMediaTime()
        let realTyping = !engine.activeKeys.isEmpty || now-engine.lastKeyActivityTime<0.35
        p.workRealTyping=realTyping && !ignoresPhysicalKeyboard
        if !dragging && !petting && elapsed-lastAutoKey>0.35,
           let key=pendingBirths.first {
            pendingBirths.removeFirst();emitted.insert(key)
            if !tasks.contains(where:{$0.id==key && $0.read}) {
                p.triggerKeyDown(.space,at:now,forceBadge:true);WorkSounds.shared.key(at:now);lastAutoKey=elapsed
                if let badge=p.floatingKeycaps.last {
                    let color=key<2 ? (key==0 ? WorkTool.codex.color:WorkTool.claude.color) : (tasks.first{$0.id==key}?.tool.color ?? WorkTool.codex.color)
                    promotions[key]=WorkPromotion(badgeID:badge.id,color:color,captured:nil)
                    CatRenderer.workPromotionColors[badge.id]=color
                }
            }
        }
        let awaiting=waiting
        if awaiting {p.workReminderAnger=true}
        else if p.angerIntensity.value<0.05 {p.workReminderAnger=false}
        p.previewAwaiting=awaiting
        if awaiting {p.petHeadIntensity=0;p.petBodyIntensity=0}
        let run=visibleTasks.contains{$0.state == .running}
        p.workKeepsAwake=true
        let expressive=WorkInteractionPolicy.autonomousTyping(running:run,waiting:awaiting,dragging:dragging,petting:petting,realTyping:realTyping)
        let auto=expressive && CatSettings.shared.workAutoTyping
        if expressive && emotionsEnabled && elapsed>=nextEmotion && elapsed>=quietUntil {
            let long=visibleTasks.contains{$0.state == .running && Date().timeIntervalSince1970-$0.started>3600}
            let random=Double.random(in:0...1);emotion=random<(long ? 0.75 : 0.25) ? 2 : 1
            emotionStart=elapsed;nextEmotion=elapsed+Double.random(in:45...75)
        }
        if !expressive || !emotionsEnabled || elapsed<quietUntil {emotion=0}
        let age=CGFloat(elapsed-emotionStart)
        let strength=WorkPanelDrawing(p).ease(age/0.38)*(1-WorkPanelDrawing(p).ease((age-1.25)/0.7))
        let cadenceFrame=typingCadence.advance(dt:Double(min(dt,0.05)),active:auto)
        if auto && !cadenceFrame.isSlow {autoTypingPhase+=Double(min(dt,0.05))*cadenceFrame.rate/0.075}
        p.previewTypingKPM=auto ? CGFloat(600*cadenceFrame.rate) : nil
        p.previewWorkAngerEnvelope=0
        p.workExpressionAnger=expressive && emotion==1 && emotionsEnabled ? strength : 0
        p.previewAwaitingAnger=awaiting ? WorkPanelDrawing(p).ease(CGFloat(Date().timeIntervalSince1970-(visibleTasks.first{$0.state == .awaiting}?.changed ?? Date().timeIntervalSince1970)-300)/1.2) : 0
        CatRenderer.workDizzyAmount=expressive && emotion==2 && emotionsEnabled ? strength : 0
        var synthetic:[PhysicalKey]=[]
        if auto && elapsed-lastAutoKey>0.18 {
            let left:[PhysicalKey]=[.a,.f,.r,.c,.w,.g,.v,.s,.t,.d,.q,.b],right:[PhysicalKey]=[.j,.o,.m,.u,.l,.y,.k,.p,.h,.n,.i]
            let tick=Int(autoTypingPhase)
            if cadenceFrame.isSlow {
                if let beat=cadenceFrame.slowBeat {
                    synthetic=beat%2==0 ? [left[(beat/2)%left.count]]:[right[(beat/2)%right.count]]
                }
            } else if autoTypingPhase.truncatingRemainder(dividingBy:1)<0.60 {
                synthetic=[left[tick%left.count],right[tick%right.count]]
            }
            for key in synthetic where !previousSynthetic.contains(key){p.triggerKeyDown(key,at:now);WorkSounds.shared.key(at:now)}
        }
        let spaceHold=elapsed>=lastAutoKey && elapsed-lastAutoKey<0.16 && !dragging
        if spaceHold {synthetic=[.space];p.previewAwaiting=false}
        previousSynthetic=Set(synthetic)
        if auto || spaceHold || ignoresPhysicalKeyboard {
            p.step(dt:dt,windowFrameInScreen:window.frame,scripted:ScriptedFrameInput(now:now,activeKeys:Set(synthetic),orderedKeys:synthetic,mouseScreenPos:engine.lastMouseLocation,mouseVelocity:.zero,leftMouseDown:false,rightMouseDown:false,lastMouseMoveTime:now-3,lastMouseClickTime:engine.lastMouseClickTime,lastKeyActivityTime:now))
        } else {p.step(dt:dt,windowFrameInScreen:window.frame)}
        for key in Array(promotions.keys) {
            guard var promotion=promotions[key],promotion.captured == nil,let badge=p.floatingKeycaps.first(where:{$0.id==promotion.badgeID}),badge.age>=0.65 else {continue}
            WorkSounds.shared.bubble(isQuota:key<2,at:now)
            promotion.captured=elapsed;promotion.source=badge.position;promotion.rotation=badge.rotation;promotion.velocity=badge.velocity
            promotions[key]=promotion;p.floatingKeycaps.removeAll{$0.id==badge.id}
        }
        // Recovery swaps spiral contents only during the fully closed first blink.
        let raw=max(CatRenderer.workDizzyAmount,max(p.scruffDizzyIntensity.value,p.dizzyIntensity.value))
        if recoveryStart == nil && previousDizzy>0.4 && raw<=0.4 { recoveryStart=elapsed }
        previousDizzy=raw;CatRenderer.recoveryBlink=0;CatRenderer.recoverySpiral=nil
        if let start=recoveryStart {
            let a=CGFloat(elapsed-start)*1.5
            if a<0.63 {
                let d=WorkPanelDrawing(p),closure:CGFloat
                switch a {
                case ..<0.12:closure=d.ease(a/0.12)
                case ..<0.16:closure=1
                case ..<0.28:closure=1-d.ease((a-0.16)/0.12)
                case ..<0.34:closure=0
                case ..<0.45:closure=d.ease((a-0.34)/0.11)
                case ..<0.49:closure=1
                default:closure=1-d.ease((a-0.49)/0.14)
                }
                CatRenderer.recoveryBlink=closure;CatRenderer.recoverySpiral=a<0.14
            } else {recoveryStart=nil}
        }
        p.dizzyPhase+=Self.workSpinAdvance(dt:dt,workDizzy:CatRenderer.workDizzyAmount,recoveringSpiral:CatRenderer.recoverySpiral == true,naturalDizzy:max(p.scruffDizzyIntensity.value,p.dizzyIntensity.value))
        for (id,start) in fading where elapsed-start>0.8 {fading.removeValue(forKey:id)}
        if run || awaiting {lastBusy=elapsed}
        if Self.shouldReturnToCompanionMode(idleFor:elapsed-lastBusy,hasBusyTask:run || awaiting) {
            CatSettings.shared.isWorkMode=false
        }
        updatePanels(window:window,dragging:dragging)
        updateFirstHint(window:window)
    }
    static func retainAfterModeExit(_ task:WorkTaskRecord)->Bool {
        !task.read && (task.state == .awaiting || task.state == .failed)
    }
    func prepareForModeExit() {
        WorkSounds.shared.stop()
        carryoverTaskKeys=[]
        for i in tasks.indices {
            if Self.retainAfterModeExit(tasks[i]) {
                if let key=tasks[i].key {carryoverTaskKeys.insert(key)}
            } else {
                if !tasks[i].read {fading[tasks[i].id]=elapsed}
                // Retain a read tombstone so the next poll cannot revive this same finished turn.
                tasks[i].read=true
            }
        }
        persist()
    }
    static func shouldReturnToCompanionMode(idleFor:Double,hasBusyTask:Bool)->Bool {
        !hasBusyTask && idleFor>=1800
    }
    static func shouldShowFirstHint(seen:Bool,needsPermission:Bool,workMode:Bool)->Bool {
        !seen
    }
    func updateFirstHint(window:OverlayWindow){
        guard let hint=firstHint,window.isVisible,window.alphaValue>0.01,
              Self.shouldShowFirstHint(seen:UserDefaults.standard.bool(forKey:Self.firstHintSeenKey),needsPermission:InputEngine.shared.status.needsAttention,workMode:CatSettings.shared.isWorkMode) else {firstHint?.orderOut(nil);return}
        let scale=window.frame.width/360,height:CGFloat=20
        let logicalBottom:CGFloat
        if CatSettings.shared.isWorkMode {
            let rows=showsAllTasks ? visibleTasks.count:min(visibleTasks.count,3)
            logicalBottom=center.y+(rows==0 ? 38:83+CGFloat(rows-1)*36)
        } else {
            logicalBottom=InputEngine.shared.status.needsAttention ? CatRenderer.permissionPillRect.maxY+4 : CatRenderer.permissionPillRect.minY+4
        }
        var y=window.frame.maxY-(logicalBottom+height)*scale
        if let safe=(window.screen ?? NSScreen.main)?.visibleFrame,y<safe.minY+4 {
            let shift=safe.minY+4-y
            window.setFrameOrigin(CGPoint(x:window.frame.minX,y:window.frame.minY+shift));y+=shift
        }
        hint.setFrame(CGRect(x:window.frame.midX-106*scale,y:y,width:212*scale,height:height*scale),display:true)
        hint.level=window.level;hint.alphaValue=window.alphaValue;hint.orderFrontRegardless()
    }
    func updatePanels(window:OverlayWindow,dragging:Bool) {
        guard let panel,let v=panelView else{return}
        scale=window.frame.width/CatPhysics.canvasSize.width
        let edge=CatRenderer.previewKeyboardEdge
        let target=CGPoint(x:(edge.0.x+edge.1.x)/2,y:(edge.0.y+edge.1.y)/2+22+(InputEngine.shared.status.needsAttention ? 20 : 0))
        center.x+=(target.x-center.x)*0.2;center.y+=(target.y-center.y)*0.2
        var a=atan2(edge.1.y-edge.0.y,edge.1.x-edge.0.x)
        if a > .pi/2 {a -= .pi};if a < -.pi/2 {a += .pi}
        let desired=dragging ? a*0.5 : a
        angle+=(desired-angle)*0.18
        singleWidth+=(tools.count==1 ? 190-singleWidth : 90-singleWidth)*0.16
        quotaX+=(tools.count==1 ? -quotaX : -49-quotaX)*0.16
        // Keep the complete work group visible when entering work mode or dropping near an edge.
        if !dragging && window.isVisible,let safe=(window.screen ?? NSScreen.main)?.visibleFrame.insetBy(dx:8,dy:8) {
            let height:CGFloat=visibleTasks.isEmpty ? 40 : 80+CGFloat(min(visibleTasks.count,3)-1)*36
            let corners=[CGPoint(x:-102,y:-23),CGPoint(x:102,y:-23),CGPoint(x:-102,y:height),CGPoint(x:102,y:height)].map { local -> CGPoint in
                let x=center.x+local.x*cos(angle)-local.y*sin(angle),y=center.y+local.x*sin(angle)+local.y*cos(angle)
                return CGPoint(x:window.frame.minX+x*scale,y:window.frame.maxY-y*scale)
            }
            let minX=corners.map{$0.x}.min()!,maxX=corners.map{$0.x}.max()!,minY=corners.map{$0.y}.min()!,maxY=corners.map{$0.y}.max()!
            let dx=minX<safe.minX ? safe.minX-minX : (maxX>safe.maxX ? safe.maxX-maxX : 0)
            let dy=minY<safe.minY ? safe.minY-minY : (maxY>safe.maxY ? safe.maxY-maxY : 0)
            if abs(dx)>0.1 || abs(dy)>0.1 {window.setFrameOrigin(CGPoint(x:window.frame.minX+dx,y:window.frame.minY+dy))}
        }
        // The companion window includes the cat's canvas so the SAME keycap can travel into a bar.
        let extra:CGFloat=220*scale
        let padding=Self.canvasPadding*scale
        panel.setFrame(CGRect(x:window.frame.minX-padding,y:window.frame.minY-extra-padding,width:window.frame.width+2*padding,height:window.frame.height+extra+2*padding),display:false)
        panel.level=window.level;tooltip?.level=window.level;panel.alphaValue=window.alphaValue*exitOpacity
        guard window.isVisible && window.alphaValue>0.01 else {panel.orderOut(nil);tooltip?.orderOut(nil);return}
        panel.orderFrontRegardless()
        v.needsDisplay=true
        if isTransitioning {panel.ignoresMouseEvents=true;tooltip?.orderOut(nil);return}
        let pointer=panel.convertPoint(fromScreen:NSEvent.mouseLocation)
        let logical=CGPoint(x:pointer.x/scale-Self.canvasPadding,y:(panel.frame.height-pointer.y)/scale-Self.canvasPadding)
        let local=toPanel(logical)
        updateButtonHover(point:dragging ? nil : local)
        let capturing=hit(local) != nil && !dragging && (!CatSettings.shared.fullClickThrough || NSEvent.modifierFlags.contains(.option))
        panel.ignoresMouseEvents = !capturing
        if !dragging, let current=hit(local) {
            switch current {
            case .quota(let tool):hovered=tool;hoverLeftAt=elapsed;showTooltip(tool)
            case .task(let id):hoverLeftAt=elapsed;showTaskTooltip(id)
            case .more:tooltip?.orderOut(nil)
            }
        } else if dragging || elapsed-hoverLeftAt>0.18 {tooltip?.orderOut(nil);hovered=nil}
    }
    func updateButtonHover(point:CGPoint?) {
        guard let drawing else{return}
        let list=showsAllTasks ? visibleTasks : Array(visibleTasks.prefix(3))
        for (i,task) in list.enumerated() {
            let box=CGRect(x:33,y:26+CGFloat(i)*36,width:58,height:26)
            let target:CGFloat=point.map{box.contains($0) && task.state != .running} == true ? 1 : 0
            let old=drawing.actionHover[task.title] ?? 0
            drawing.actionHover[task.title]=old+(target-old)*0.22
        }
    }
    func toPanel(_ point:CGPoint)->CGPoint {
        let x=point.x-center.x,y=point.y-center.y
        return CGPoint(x:x*cos(-angle)-y*sin(-angle),y:x*sin(-angle)+y*cos(-angle))
    }
    enum Hit { case quota(WorkTool), task(Int), more }
    func hit(_ p:CGPoint)->Hit? {
        if tools.count==1,CGRect(x:-95,y:-16,width:190,height:32).contains(p){return .quota(tools[0])}
        if tools.count==2 {
            if CGRect(x:-94,y:-16,width:90,height:32).contains(p){return .quota(.codex)}
            if CGRect(x:4,y:-16,width:90,height:32).contains(p){return .quota(.claude)}
        }
        let list=showsAllTasks ? visibleTasks : Array(visibleTasks.prefix(3))
        for (i,t) in list.enumerated() where CGRect(x:-95,y:24+CGFloat(i)*36,width:190,height:30).contains(p) {return .task(t.id)}
        if visibleTasks.count>3 && CGRect(x:-95,y:132,width:190,height:20).contains(p){return .more}
        return nil
    }
    func showTooltip(_ tool:WorkTool){
        guard let window=parent,let tooltip,let tv=tooltipView else{return}
        let x=window.frame.minX+center.x*scale,y=window.frame.maxY-center.y*scale
        let row=CGRect(x:x-98*scale,y:y-25*scale,width:196*scale,height:50*scale)
        let protected=CGRect(x:window.frame.minX+126*scale,y:window.frame.maxY-245*scale,width:130*scale,height:200*scale)
        guard let frame=WorkHoverPlacement.frameOnScreen(anchor:row,avoiding:protected,preferredSize:CGSize(width:108*scale,height:(hasShort(tool) ? 140 : 89)*scale)) else{return}
        tv.taskID=nil;tv.tool=tool;tv.needsDisplay=true;tooltip.setFrame(frame,display:true);tooltip.orderFrontRegardless()
    }
    func showTaskTooltip(_ id:Int){
        guard let window=parent,let tooltip,let tv=tooltipView,let task=tasks.first(where:{$0.id==id}) else{return}
        let x=window.frame.minX+center.x*scale,y=window.frame.maxY-center.y*scale
        let row=CGRect(x:x-98*scale,y:y-70*scale,width:196*scale,height:50*scale)
        guard let frame=WorkHoverPlacement.frameOnScreen(anchor:row,avoiding:window.frame.insetBy(dx:window.frame.width*0.32,dy:window.frame.height*0.2),preferredSize:CGSize(width:128*scale,height:130*scale)) else{return}
        tv.taskID=id;tv.tool=task.tool;tv.needsDisplay=true;tooltip.setFrame(frame,display:true);tooltip.orderFrontRegardless()
    }
    func action(_ hit:Hit) {
        guard !wasDragging else{return}
        switch hit {
        case .quota: break
        case .more:showsAllTasks.toggle()
        case .task(let id):
            guard let i=tasks.firstIndex(where:{$0.id==id}) else{return}
            guard let link=tasks[i].link,let url=LiveParsing.allowedLink(link,tool:tasks[i].tool),NSWorkspace.shared.open(url) else {
                let a=NSAlert();a.messageText="终端任务 · "+tasks[i].title
                a.informativeText="请回原终端处理。项目："+(tasks[i].project ?? "未知")+"。本应用不会执行或批准操作。"
                let settled=tasks[i].state != .running && tasks[i].state != .awaiting
                a.addButton(withTitle:settled ? "标为已查看":"知道了");if settled{a.addButton(withTitle:"关闭")}
                if a.runModal() == .alertFirstButtonReturn && settled {tasks[i].read=true;fading[id]=elapsed;persist()}
                return
            }
            if tasks[i].state != .running && tasks[i].state != .awaiting {tasks[i].read=true;fading[id]=elapsed;persist()}
        }
    }
    func drawQuota(_ c:CGContext,tool:WorkTool,width:CGFloat){
        guard let d=drawing else{return}
        let q=quotas[tool],now=Date().timeIntervalSince1970
        c.saveGState();if q?.stale != false{c.setAlpha(0.45)};c.beginTransparencyLayer(auxiliaryInfo:nil)
        d.quota(c,tool.title.uppercased(),tool.color,0,q?.short?.remaining ?? q?.week?.remaining ?? 0,q?.week?.remaining ?? 0,CGFloat(max(0,(q?.week?.reset ?? now)-now)/86400),width,q?.short != nil,q?.week != nil)
        if q?.short == nil && q?.week == nil {d.text(c,"N/A",width/2-29,-4,7,d.ink,true)}
        c.endTransparencyLayer();c.restoreGState()
    }
    func draw(in c:CGContext) {
        guard let d=drawing else{return}
        c.saveGState();c.scaleBy(x:scale,y:scale);c.translateBy(x:Self.canvasPadding,y:Self.canvasPadding);c.translateBy(x:center.x,y:center.y);c.rotate(by:angle)
        func birth(_ id:Int,_ target:CGPoint,_ width:CGFloat,opacity:CGFloat=1,_ body:()->Void){
            guard let p=promotions[id],let captured=p.captured else{return}
            let layer=id<2 ? 0 : (visibleTasks.firstIndex(where:{$0.id==id}) ?? 0)+1
            let pickupAge=CGFloat(elapsed-(pickupStart ?? -100))-CGFloat(layer)*0.12
            let offset:CGFloat=pickupAge>0 && pickupAge<2 ? -12*exp(-5*pickupAge)*sin(7*pickupAge) : 0
            let age=CGFloat(elapsed-captured)*1.3,u=min(1,max(0,age/0.95)),progress=1-pow(1-u,1.35)
            let source=toPanel(p.source),velocity=d.rotate(p.velocity,-angle)
            let c1=CGPoint(x:source.x+velocity.x*0.45,y:source.y+velocity.y*0.45),c2=CGPoint(x:target.x,y:target.y-30)
            let a=d.mixP(source,c1,progress),b=d.mixP(c1,c2,progress),e=d.mixP(c2,target,progress)
            let point=d.mixP(d.mixP(a,b,progress),d.mixP(b,e,progress),progress)
            c.saveGState();c.translateBy(x:point.x,y:point.y+offset)
            c.rotate(by:(p.rotation-angle)*(1-d.ease(age/0.90)))
            let morph=d.ease((age-0.1)/0.7),blend=d.ease((age-0.24)/0.56),h:CGFloat=28
            let w=d.mix(23,width,morph)
            if blend<1 {c.saveGState();c.setAlpha(opacity*(1-blend));CatRenderer.drawWorkPromotionFace(in:c,width:w,height:d.mix(22,h,morph),color:p.color);c.restoreGState()}
            if blend>0 {c.saveGState();c.scaleBy(x:w/width,y:d.mix(22,h,morph)/h);c.setAlpha(opacity*blend);body();c.restoreGState()}
            c.restoreGState()
        }
        if tools.count==1 {
            let t=tools[0],i=t == .codex ? 0 : 1
            birth(i,.zero,singleWidth){drawQuota(c,tool:t,width:singleWidth)}
        } else if tools.count==2 {
            birth(0,CGPoint(x:quotaX,y:0),singleWidth){drawQuota(c,tool:.codex,width:singleWidth)}
            birth(1,CGPoint(x:49,y:0),90){drawQuota(c,tool:.claude,width:90)}
        }
        if tools.isEmpty {d.text(c,"等待识别 Codex／Claude 活动任务",-83,-5,8,d.ink,true)}
        let list=showsAllTasks ? visibleTasks : Array(visibleTasks.prefix(3))
        for (index,t) in list.enumerated() {
            let color:NSColor,action:String?,detail:String
            switch t.state {
            case .running:color=d.yellow;action=nil;detail="运行中 · \(d.elapsed(max(0,Int(Date().timeIntervalSince1970-t.started))))"
            case .awaiting:color=d.purple;action="打开处理";detail="等待处理 · \(d.elapsed(max(0,Int(Date().timeIntervalSince1970-t.changed))))"
            case .completed:color=d.green;action="查看结果";detail="已完成"
            case .failed:color=d.red;action="查看详情";detail="失败 · 任务未成功"
            case .cancelled:color=d.red;action="查看详情";detail="已终止"
            }
            c.saveGState();let opacity=fading[t.id].map{Self.taskOpacity(age:elapsed-$0)} ?? 1
            birth(t.id,CGPoint(x:0,y:39+CGFloat(index)*36),190,opacity:opacity){d.task(c,t.title,detail,t.tool.title,t.tool.color,color,action)}
            c.restoreGState()
        }
        if visibleTasks.count>3 && !showsAllTasks {d.text(c,"还有 \(visibleTasks.count-3) 项…",-36,140,8,d.ink,true)}
        d.text(c,connectionStatus,-91,visibleTasks.isEmpty ? 25 : 61+CGFloat(list.count-1)*36+(visibleTasks.count>3 && !showsAllTasks ? 25 : 0),6.5,NSColor.secondaryLabelColor)
        c.restoreGState()
    }
    func hidePanels(){panel?.orderOut(nil);tooltip?.orderOut(nil);firstHint?.orderOut(nil)}
    func shutdown(){live.stop();if loginProcess?.isRunning==true{loginProcess?.terminate()};persist();hidePanels()}
}
final class WorkPanelView:NSView {
    weak var owner:WorkModeExperience?
    override var isFlipped:Bool{true}
    override var isOpaque:Bool{false}
    override func draw(_ dirtyRect:NSRect){guard let c=NSGraphicsContext.current?.cgContext else{return};c.clear(bounds);owner?.draw(in:c)}
    override func mouseDown(with event:NSEvent){
        guard let o=owner else{return}
        let p=convert(event.locationInWindow,from:nil)
        if let hit=o.hit(o.toPanel(CGPoint(x:p.x/o.scale-WorkModeExperience.canvasPadding,y:p.y/o.scale-WorkModeExperience.canvasPadding))){o.action(hit)}
    }
    override func rightMouseDown(with event:NSEvent){guard let o=owner else{return};let menu=NSMenu();menu.addItem(o.menuItem());NSMenu.popUpContextMenu(menu,with:event,for:self)}
}
final class WorkTooltipView:NSView {
    weak var owner:WorkModeExperience?
    var tool:WorkTool = .codex
    var taskID:Int?
    override var isFlipped:Bool{true}
    override var isOpaque:Bool{false}
    override func draw(_ dirtyRect:NSRect){
        guard let o=owner,let d=o.drawing,let c=NSGraphicsContext.current?.cgContext else{return}
        c.clear(bounds)
        if let id=taskID,let task=o.tasks.first(where:{$0.id==id}) {
            c.saveGState();c.scaleBy(x:bounds.width/128,y:bounds.height/130)
            d.bubble(c,CGRect(x:0,y:0,width:128,height:130),tool.color,8,extruded:false)
            d.text(c,task.title,8,10,10,tool.color,true)
            d.text(c,task.source ?? tool.title,8,28,7,d.ink)
            let names:[WorkState:String]=[.running:"运行中",.awaiting:"等待你处理",.completed:"已完成",.failed:"失败",.cancelled:"已终止"]
            d.text(c,names[task.state] ?? "",8,48,11,tool.color,true)
            d.text(c,"项目："+(task.project ?? "—"),8,69,7.5,d.ink)
            let formatter=DateFormatter();formatter.dateFormat="HH:mm:ss"
            d.text(c,"开始："+formatter.string(from:Date(timeIntervalSince1970:task.started)),8,86,8,d.ink)
            d.text(c,"已用："+d.elapsed(max(0,Int((task.state == .running || task.state == .awaiting ? Date().timeIntervalSince1970:task.changed)-task.started))),8,102,8,d.ink)
            d.text(c,task.link?.isEmpty == false ? "点击任务可打开聊天" : "请回原终端处理",8,117,7,NSColor.secondaryLabelColor)
            c.restoreGState()
        } else {d.drawLiveHover(c,frame:bounds,tool:tool,quota:o.quotas[tool])}
    }
}

final class WorkFirstHintView:NSView {
    weak var owner:WorkModeExperience?
    override var isFlipped:Bool{true}
    override var isOpaque:Bool{false}
    override func draw(_ dirtyRect:NSRect){
        guard let d=owner?.drawing,let c=NSGraphicsContext.current?.cgContext else{return}
        c.clear(bounds);c.saveGState();c.scaleBy(x:bounds.width/212,y:bounds.height/20)
        d.bubble(c,CGRect(x:0,y:0,width:212,height:20),d.blue,9)
        let label=CatSettings.shared.isEnglish ? (CatSettings.shared.isWorkMode ? "Double-click for Companion Mode":"Double-click cat for Work Mode") : (CatSettings.shared.isWorkMode ? "双击小猫可返回普通模式":"双击小猫可切换工作模式")
        let width=NSAttributedString(string:label,attributes:[.font:NSFont.systemFont(ofSize:10,weight:.semibold)]).size().width
        d.text(c,label,(212-width)/2,4,10,d.ink,true)
        c.restoreGState()
    }
}
