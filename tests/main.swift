import AppKit
setbuf(stdout,nil)
let workTestDefaults=UserDefaults(suiteName:"KuroCat.LiveValidation."+UUID().uuidString)!
var count=0
func check(_ value:Bool,_ name:String){if !value{print("FAILED:",name);fatalError(name)};count+=1}
check(WorkInteractionPolicy.autonomousTyping(running:true,waiting:false,dragging:false,petting:false,realTyping:true),"Physical typing does not interrupt autonomous work")
check(!WorkInteractionPolicy.autonomousTyping(running:true,waiting:true,dragging:false,petting:false,realTyping:true),"Awaiting still pauses autonomous work")
check(!WorkInteractionPolicy.autonomousTyping(running:true,waiting:false,dragging:true,petting:false,realTyping:true),"Dragging still pauses autonomous work")
check(!WorkInteractionPolicy.autonomousTyping(running:true,waiting:false,dragging:false,petting:true,realTyping:true),"Petting still pauses autonomous work")
let a: [String:Any] = ["rateLimitsByLimitId":["codex":["primary":["usedPercent":31,"windowDurationMins":10080,"resetsAt":2000000000]]]]
let quota=LiveParsing.codexQuota(a)!
check(quota.short == nil,"No invented short window")
check(quota.week?.used==31,"Real used percentage")
check(abs(Double(quota.week!.remaining)-0.69)<0.001,"Remaining conversion")
check(quota.week?.reset==2000000000,"Unix reset")
check(LiveParsing.codexQuota(["rateLimitsByLimitId":["model":["primary":["usedPercent":10,"windowDurationMins":300]]]])?.short == nil,"Model allowance is not account allowance")
check(LiveParsing.codexQuota(["rateLimits":["primary":["usedPercent":120,"windowDurationMins":300]]])?.short?.used==100,"Clamp values")
check(LiveParsing.claudeQuota(["five_hour":NSNull(),"seven_day":["utilization":12.5,"resets_at":"2026-12-01T12:00:00.000Z"]],source:"test")?.short == nil,"Missing Claude window hidden")
check(LiveParsing.claudeQuota(["error":"unauthorized"],source:"test")==nil,"Failed login is not zero usage")
check(LiveParsing.timestamp("2026-12-01T12:00:00Z") != nil,"ISO reset")
check(LiveParsing.timestamp(2000000000000)==2000000000,"Millisecond timestamp")
let id=UUID().uuidString.lowercased()
check(LiveParsing.allowedLink("codex://threads/"+id,tool:.codex) != nil,"Codex chat link")
check(LiveParsing.allowedLink("javascript:alert(1)",tool:.claude)==nil,"Reject script URL")
check(LiveParsing.allowedLink("https://claude.ai.evil.test/chat/a",tool:.claude)==nil,"Reject wrong host")
check(LiveParsing.allowedLink("https://claude.ai/chat/abc",tool:.claude) != nil,"Claude link")
let temp=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("kurocat-live-test-"+UUID().uuidString)
try! FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
func hook(_ event:String,_ tool:WorkTool = .claude,_ extra:[String:Any]=[:],_ time:Double=Date().timeIntervalSince1970){var object:[String:Any]=["session_id":id,"hook_event_name":event,"cwd":"/private/project","turn_id":"turn-a"];object.merge(extra){_,new in new};WorkEventBridge.handle(try! JSONSerialization.data(withJSONObject:object),root:temp,now:time,tool:tool)}
hook("UserPromptSubmit")
check(WorkEventBridge.read(root:temp).first?.state == .running,"Prompt starts task")
hook("PermissionRequest")
check(WorkEventBridge.read(root:temp).first?.state == .awaiting,"Permission is explicit awaiting")
hook("PostToolUse")
check(WorkEventBridge.read(root:temp).first?.state == .running,"After tool clears wait")
hook("Stop")
check(WorkEventBridge.read(root:temp).first?.state == .completed,"Stop completion")
hook("SessionEnd")
check(WorkEventBridge.read(root:temp).first?.state == .completed,"Session end preserves completion")
hook("UserPromptSubmit");hook("StopFailure")
check(WorkEventBridge.read(root:temp).first?.state == .failed,"Failure is red state")
hook("UserPromptSubmit",.codex);hook("PermissionRequest",.codex)
check(WorkEventBridge.read(root:temp).first{$0.tool == .codex}?.state == .awaiting,"Codex explicit approval hook")
hook("Interrupt",.codex)
check(WorkEventBridge.read(root:temp).first{$0.tool == .codex}?.state == .cancelled,"Codex interruption")
let content=try! String(contentsOf:temp.appendingPathComponent("claude-"+id+".json"))
check(!content.contains("tool_input") && !content.contains("accessToken"),"Metadata only persisted")
let log=temp.appendingPathComponent("rollout.jsonl")
func record(_ type:String,_ turn:String="a")->Data {try! JSONSerialization.data(withJSONObject:["type":"event_msg","timestamp":"2026-11-26T12:00:00Z","payload":["type":type,"turn_id":turn]])}
var data=record("task_started");data.append(10);try! data.write(to:log)
let sessions=LocalWorkSessions(home:temp)
check(sessions.activity(log.path,claude:false)?.state == .running,"Transcript start")
let file=try! FileHandle(forWritingTo:log);try! file.seekToEnd();let end=record("task_complete");try! file.write(contentsOf:end.prefix(8))
check(sessions.activity(log.path,claude:false)?.state == .running,"Partial JSON not mistaken for end")
try! file.write(contentsOf:end.dropFirst(8));try! file.write(contentsOf:Data([10]));try! file.close()
check(sessions.activity(log.path,claude:false)?.state == .completed,"Incremental completion")
var aborted=record("task_started","b");aborted.append(10);aborted.append(record("turn_aborted","b"));aborted.append(10);try! aborted.write(to:log)
check(sessions.activity(log.path,claude:false)?.state == .cancelled,"Rotated/truncated file resets cursor")
CatSettings.shared.isWorkMode=true
workTestDefaults.set("both",forKey:"KuroCat.WorkTools")
let model=WorkModeExperience()
CatSettings.shared.workAutoTyping=true
model.tasks=[WorkTaskRecord(id:90,tool:.codex,title:"Routing check",state:.running,started:0,changed:0)]
check(model.ignoresPhysicalKeyboard,"Running autonomous work owns the keyboard")
CatSettings.shared.workAutoTyping=false
check(!model.ignoresPhysicalKeyboard,"Disabling autonomy restores physical keyboard animation")
CatSettings.shared.workAutoTyping=true
model.tasks[0].state = .awaiting
check(!model.ignoresPhysicalKeyboard,"Awaiting state preserves physical keyboard animation without sound")
model.tasks=[]
let now=Date().timeIntervalSince1970
func task(_ key:String,_ state:WorkState,_ start:Double,_ changed:Double)->LiveTask{LiveTask(key:key,tool:.codex,title:"Test",state:state,started:start,changed:changed,link:"codex://threads/"+id,project:"test",source:"CODEX DESKTOP")}
model.mergeLive([task("old",.completed,now-100,now-80)])
check(model.tasks.isEmpty,"No flood of historical results")
model.mergeLive([task("current",.running,now,now)])
check(model.tasks.count==1,"Real active task appears")
model.mergeLive([task("current",.awaiting,now,now)])
check(model.waiting,"Awaiting priority")
model.mergeLive([task("current",.completed,now,now)])
check(!model.waiting,"Actual completion clears anger source")
model.tasks[0].read=true
model.mergeLive([task("current",.running,now+10,now+10)])
check(!model.tasks[0].read,"New turn revives same chat")
check(WorkModeExperience.shouldReturnToCompanionMode(idleFor:1800,hasBusyTask:false),"30 min idle return")
check(!WorkModeExperience.shouldReturnToCompanionMode(idleFor:1800,hasBusyTask:true),"Busy never sleeps/auto exits")


let large=temp.appendingPathComponent("large-rollout.jsonl")
FileManager.default.createFile(atPath:large.path,contents:nil)
let largeHandle=try! FileHandle(forWritingTo:large)
let padding=Data(("{\"type\":\"response_item\",\"payload\":\""+String(repeating:"x",count:1024*256)+"\"}\n").utf8)
for _ in 0..<180 {try! largeHandle.write(contentsOf:padding)}
var startRecord=record("task_started","large");startRecord.append(10);try! largeHandle.write(contentsOf:startRecord);try! largeHandle.close()
let timer=Date(),largeScanner=LocalWorkSessions(home:temp)
check(largeScanner.activity(large.path,claude:false)?.state == .running,"Large chat shows running on first scan")
print("48MB cold scan seconds:",Date().timeIntervalSince(timer))
let largeAppend=try! FileHandle(forWritingTo:large);try! largeAppend.seekToEnd()
for _ in 0..<40 {try! largeAppend.write(contentsOf:padding)}
var doneRecord=record("task_complete","large");doneRecord.append(10);try! largeAppend.write(contentsOf:doneRecord);try! largeAppend.close()
check(largeScanner.activity(large.path,claude:false)?.state == .completed,"Large chat incremental completion")
let fullScanner=LocalWorkSessions(home:temp)
check(fullScanner.activity(large.path,claude:false)?.state == .completed,"Large chat bootstrap completion")
let longRun=temp.appendingPathComponent("long-running.jsonl");FileManager.default.createFile(atPath:longRun.path,contents:nil)
let longHandle=try! FileHandle(forWritingTo:longRun);try! longHandle.write(contentsOf:startRecord)
for _ in 0..<48 {try! longHandle.write(contentsOf:padding)};try! longHandle.close()
check(LocalWorkSessions(home:temp).activity(longRun.path,claude:false)?.state == .running,"Running start beyond tail block is found backwards")
check(WorkModeExperience.shouldShowFirstHint(seen:false,needsPermission:false,workMode:false),"Hint appears after input permission already granted")
check(WorkModeExperience.shouldShowFirstHint(seen:false,needsPermission:false,workMode:true),"Restored mode does not consume hint")
check(!WorkModeExperience.shouldShowFirstHint(seen:true,needsPermission:true,workMode:false),"Actual acknowledgement hides hint")


let entries:[OpenWorkTools.Entry]=[
 .init(pid:100,parent:1,executable:"/Applications/KuroCatWork.app/Contents/MacOS/KuroCatWork"),
 .init(pid:101,parent:100,executable:"/usr/bin/node"),
 .init(pid:102,parent:101,executable:"/vendor/codex"),
 .init(pid:200,parent:1,executable:"/Users/test/.local/share/claude/versions/2.1.128")]
check(OpenWorkTools.providers(entries,ownPID:100)==[.claude],"Our own Codex app-server does not count as user activity")
check(OpenWorkTools.providers(entries+[.init(pid:300,parent:1,executable:"/Applications/Codex.app/Contents/MacOS/Codex")],ownPID:100)==[.codex,.claude],"Detect both actual tools")
check(WorkModeExperience.detectedProviders(previous:[],tasks:[task("done",.completed,now,now)]).isEmpty,"Old completed tasks do not auto-enable provider")
workTestDefaults.set("auto",forKey:"KuroCat.WorkTools")
let automatic=WorkModeExperience();automatic.detectedTools=[]
check(automatic.tools.isEmpty,"Auto begins without fake tools")
automatic.discoverTools([.codex]);check(automatic.tools == [.codex],"Codex detected first")
automatic.discoverTools([.claude]);check(automatic.tools == [.codex,.claude],"Claude adds second provider")
automatic.discoverTools([]);check(automatic.tools.count==2,"Idle tools do not make bars flicker")
automatic.discoverTools([.claude]);check(automatic.tools.count==2,"Repeated discovery stays deduplicated")
workTestDefaults.set("codex",forKey:"KuroCat.WorkTools")
check(automatic.tools == [.codex],"Manual tool selection still applies")
CatSettings.shared.isWorkMode=false
workTestDefaults.set("auto",forKey:"KuroCat.WorkTools");automatic.detectedTools=[];automatic.discoverTools([.claude])
check(automatic.tools.isEmpty,"Ordinary mode never auto-adds work providers")
print("Integration checks passed:",count)

CatSettings.shared.isWorkMode=true
workTestDefaults.set("both",forKey:"KuroCat.WorkTools")
let retention=WorkModeExperience()
retention.mergeLive([task("retain-done",.completed,now,now+100),task("retain-wait",.awaiting,now,now+100),task("retain-fail",.failed,now,now+100),task("retain-cancel",.cancelled,now,now+100),task("retain-read",.failed,now,now+100)])
retention.tasks[retention.tasks.firstIndex{$0.key=="retain-read"}!].read=true
retention.prepareForModeExit()
check(retention.tasks.filter{!$0.read}.map{$0.key!}.sorted()==["retain-fail","retain-wait"],"Only unread awaiting and failed survive automatic exit")
check(retention.carryoverTaskKeys==["retain-wait","retain-fail"],"Carryover tracked for reconciliation")
check(retention.fading.count==2,"Completed and cancelled fade out")
retention.mergeLive([task("retain-done",.completed,now,now)])
check(retention.tasks.first{$0.key=="retain-done"}!.read,"Same completed turn cannot return on next scan")
retention.mergeLive([task("retain-wait",.completed,now,now)])
check(retention.tasks.first{$0.key=="retain-wait"}!.read,"Waiting resolved during ordinary mode is not restored as completed")
retention.mergeLive([task("retain-fail",.running,now+10,now+10)])
check(!retention.tasks.first{$0.key=="retain-fail"}!.read,"New active turn survives")
check(!retention.carryoverTaskKeys.contains("retain-fail"),"Resumed turn clears carryover marker")
let restored=try! JSONDecoder().decode([WorkTaskRecord].self,from:workTestDefaults.data(forKey:"KuroCat.WorkLiveTasks")!)
check(restored.first{$0.key=="retain-done"}!.read,"Dismissal persists across restart")
print("Retention checks passed; total checks:",count)

retention.prepareForModeExit()
check(!retention.tasks.contains{!$0.read && $0.state == .completed},"Repeated exit cannot bring completed records back")
check(retention.tasks.filter{!$0.read}.allSatisfy{$0.state == .awaiting || $0.state == .failed},"Shared manual and automatic exit policy retains only unresolved items")
print("Shared mode-exit checks passed; total checks:",count)

check(!WorkSounds.shouldPlay(enabled:false,workMode:true),"Default-off sound stays silent in work mode")
check(!WorkSounds.shouldPlay(enabled:true,workMode:false),"Ordinary mode stays silent even with switch on")
check(WorkSounds.shouldPlay(enabled:true,workMode:true),"Work mode switch enables sound")
let audio=WorkSounds()
audio.configure(enabled:true,workMode:true);check(audio.active,"Audio session becomes active")
audio.configure(enabled:false,workMode:true);check(!audio.active,"Disabling sound stops active session")
audio.configure(enabled:true,workMode:true);audio.configure(enabled:true,workMode:false)
check(!audio.active,"Leaving work mode stops sound")
workTestDefaults.removeObject(forKey:"KuroCat.WorkSounds")
check(!retention.soundEnabled,"New setting defaults off")
CatSettings.shared.isWorkMode=true
retention.perform(NSSelectorFromString("toggleSound"))
check(retention.soundEnabled && WorkSounds.shared.active,"Menu action enables remembered preference")
let soundMenu=retention.menuItem().submenu!.items.first{$0.action==NSSelectorFromString("toggleSound")}!
check(soundMenu.state == .on,"Menu check mark reflects enabled sound")
retention.perform(NSSelectorFromString("toggleSound"))
check(!retention.soundEnabled && !WorkSounds.shared.active,"Menu action switches sound off immediately")
print("Sound checks passed; total checks:",count)

check(WorkSounds.normalizedVolume(-1,fallback:0.16)==0,"Volume clamps below zero")
check(WorkSounds.normalizedVolume(2,fallback:0.16)==1,"Volume clamps above maximum")
check(WorkSounds.normalizedVolume(.nan,fallback:0.16)==0.16,"Invalid saved volume uses default")
WorkSounds.shared.keyboardVolume=0.33;WorkSounds.shared.meowVolume=0.72
check(WorkSounds().keyboardVolume==0.33 && WorkSounds().meowVolume==0.72,"Independent sound volumes persist")
_ = NSApplication.shared
let settingsUI=SettingsWindowController()
func descendants(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap{descendants($0)}}
let controls=descendants(settingsUI.window!.contentView!)
let soundSwitch=controls.first{$0.identifier?.rawValue=="workSoundEnabled"} as! NSSwitch
let keySlider=controls.first{$0.identifier?.rawValue=="workKeyVolume"} as! NSSlider
let meowSlider=controls.first{$0.identifier?.rawValue=="workMeowVolume"} as! NSSlider
check(soundSwitch.state == .off,"Settings panel includes the sound switch with saved state")
check(keySlider.doubleValue==0.33 && meowSlider.doubleValue==0.72,"Settings panel sliders restore separate volumes")
soundSwitch.state = .on;settingsUI.perform(NSSelectorFromString("onToggleWorkSound"))
check(WorkModeExperience.shared.soundEnabled && WorkSounds.shared.active,"Settings panel switch enables audio")
keySlider.doubleValue=0.21;settingsUI.perform(NSSelectorFromString("onWorkKeyVolumeChanged"))
check(WorkSounds.shared.keyboardVolume==0.21 && WorkSounds.shared.meowVolume==0.72,"Keyboard slider leaves meow volume unchanged")
meowSlider.doubleValue=0.56;settingsUI.perform(NSSelectorFromString("onWorkMeowVolumeChanged"))
check(WorkSounds.shared.keyboardVolume==0.21 && WorkSounds.shared.meowVolume==0.56,"Meow slider leaves keyboard volume unchanged")
let stylePopup=controls.first{$0.identifier?.rawValue=="workKeyboardSound"} as! NSPopUpButton
let popSwitch=controls.first{$0.identifier?.rawValue=="workPopSoundEnabled"} as! NSSwitch
let popSlider=controls.first{$0.identifier?.rawValue=="workPopVolume"} as! NSSlider
check(stylePopup.numberOfItems==3,"Settings show Blue Brown Red choices")
check(WorkSounds.shared.keyboardStyle == .blue,"Existing users retain default Blue sound")
stylePopup.selectItem(at:1);settingsUI.perform(NSSelectorFromString("onWorkKeyboardSoundChanged"))
check(WorkSounds().keyboardStyle == .brown,"Brown selection persists")
stylePopup.selectItem(at:2);settingsUI.perform(NSSelectorFromString("onWorkKeyboardSoundChanged"))
check(WorkSounds().keyboardStyle == .red,"Red selection persists")
check(WorkSounds.shared.keyboardVolume==0.21 && WorkSounds.shared.meowVolume==0.56,"Changing switch sound retains both volumes")
workTestDefaults.set("unknown",forKey:"KuroCat.WorkKeyboardSound")
check(WorkSounds.shared.keyboardStyle == .blue,"Invalid selection falls back safely")
stylePopup.selectItem(at:2);settingsUI.perform(NSSelectorFromString("onWorkKeyboardSoundChanged"))
check(popSwitch.state == .on,"Bubble sounds enabled behind the master sound switch by default")
popSwitch.state = .off;settingsUI.perform(NSSelectorFromString("onToggleWorkPopSound"))
check(!WorkSounds().popEnabled,"Bubble sound can be disabled separately")
popSwitch.state = .on;settingsUI.perform(NSSelectorFromString("onToggleWorkPopSound"))
popSlider.doubleValue=0.35;settingsUI.perform(NSSelectorFromString("onWorkPopVolumeChanged"))
check(WorkSounds().popVolume==0.35,"Bubble volume persists independently")
check(WorkSounds.shared.keyboardVolume==0.21 && WorkSounds.shared.meowVolume==0.56,"Bubble volume does not change key or meow levels")

let workBubbleSwitch=controls.first{$0.identifier?.rawValue=="workKeyBadges"} as! NSSwitch
check(workBubbleSwitch.state == .on,"Work bubble preference preserves current default")
workBubbleSwitch.state = .off;settingsUI.perform(NSSelectorFromString("onToggleWorkKeyBadges"))
check(!CatSettings.shared.workKeyBadges,"Work bubble switch saves independently")
CatSettings.shared.showKeyBadges=true;CatSettings.shared.isWorkMode=true
let badgePhysics=CatPhysics()
badgePhysics.triggerKeyDown(.a,at:200)
check(badgePhysics.floatingKeycaps.isEmpty,"Actual typing creates no bubbles when work switch is off")
badgePhysics.triggerKeyDown(.space,at:201,forceBadge:true)
check(badgePhysics.floatingKeycaps.count==1,"Forced work-bar space bubble survives disabled ordinary bubbles")
badgePhysics.triggerKeyDown(.b,at:202)
check(badgePhysics.floatingKeycaps.count==1,"Ordinary synthetic key does not add bubbles")
CatSettings.shared.isWorkMode=false
badgePhysics.triggerKeyDown(.c,at:203)
check(badgePhysics.floatingKeycaps.count==2,"Ordinary mode retains its own existing bubble preference")
CatSettings.shared.showKeyBadges=false;CatSettings.shared.isWorkMode=true
workBubbleSwitch.state = .on;settingsUI.perform(NSSelectorFromString("onToggleWorkKeyBadges"))
badgePhysics.triggerKeyDown(.d,at:204)
check(badgePhysics.floatingKeycaps.count==3,"Work mode can show bubbles independently of ordinary mode")

let typingBeforeExpressionToggle=CatSettings.shared.workAutoTyping
let expressionSwitch=controls.first{$0.identifier?.rawValue=="workRandomExpressions"} as! NSSwitch
check(expressionSwitch.state == .on,"Random expression switch preserves enabled default")
expressionSwitch.state = .off;settingsUI.perform(NSSelectorFromString("onToggleWorkRandomExpressions"))
check(!WorkModeExperience.shared.emotionsEnabled && !WorkModeExperience().emotionsEnabled,"Random expression off setting persists")
check(CatSettings.shared.workKeyBadges && CatSettings.shared.workAutoTyping == typingBeforeExpressionToggle,"Expression setting does not alter independent animation preferences")
expressionSwitch.state = .on;settingsUI.perform(NSSelectorFromString("onToggleWorkRandomExpressions"))
check(WorkModeExperience.shared.emotionsEnabled,"Random expressions can be reenabled")
workTestDefaults.removeObject(forKey:"KuroCat.WorkRandomExpressions")
workTestDefaults.set(false,forKey:"KuroCat.WorkEmotions")
check(!WorkModeExperience.shared.emotionsEnabled,"Legacy expression preference migrates without resetting")
WorkModeExperience.shared.setEmotionsEnabled(true)
check(WorkModeExperience.shared.emotionsEnabled,"Explicit new setting overrides legacy disabled preference")

let card=soundSwitch.superview!
check(card.subviews.allSatisfy{$0.frame.maxY<=card.bounds.height},"All work settings fit within the card")
let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(card.bounds.width*2),pixelsHigh:Int(card.bounds.height*2),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
bitmap.size=card.bounds.size
card.cacheDisplay(in:card.bounds,to:bitmap)
try! bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
soundSwitch.state = .off;settingsUI.perform(NSSelectorFromString("onToggleWorkSound"))
check(!WorkModeExperience.shared.soundEnabled && !WorkSounds.shared.active,"Settings panel switch stops sound")
print("Settings panel and volume checks passed; total checks:",count)

print("Switch sound and bubble setting checks passed; total checks:",count)

print("Keyboard bubbles and sound controls passed; total checks:",count)

print("All work mode options checks passed; total checks:",count)
