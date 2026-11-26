import AppKit

enum WorkKeyboardSound: String, CaseIterable {
    case blue, brown, red
    var title: String {
        switch self {
        case .blue: return CatSettings.shared.isEnglish ? "Blue Switch" : "青轴"
        case .brown: return CatSettings.shared.isEnglish ? "Brown Switch" : "茶轴"
        case .red: return CatSettings.shared.isEnglish ? "Red Switch" : "红轴"
        }
    }
}

// Short samples and bounded lazy pools; no playback in ordinary mode or with sound disabled.
final class WorkSounds {
    static let shared = WorkSounds()
    static func shouldPlay(enabled: Bool, workMode: Bool) -> Bool { enabled && workMode }
    static func normalizedVolume(_ value: Double, fallback: Double) -> Double {
        value.isFinite ? min(1,max(0,value)) : fallback
    }
    private(set) var active = false
    private var keys: [NSSound] = []
    private var loadedStyle: WorkKeyboardSound?
    private var meow: NSSound?
    private var quotaPops: [NSSound] = []
    private var taskPops: [NSSound] = []
    private var lastKey: Double = -.infinity
    private var lastPop: Double = -.infinity
    var keyboardStyle: WorkKeyboardSound {
        get {WorkKeyboardSound(rawValue: UserDefaults.standard.string(forKey:"KuroCat.WorkKeyboardSound") ?? "") ?? .blue}
        set {
            UserDefaults.standard.set(newValue.rawValue,forKey:"KuroCat.WorkKeyboardSound")
            for key in keys {key.stop()}
            keys=[];loadedStyle=nil;lastKey = -.infinity
        }
    }
    var keyboardVolume: Double {
        get {Self.normalizedVolume(UserDefaults.standard.object(forKey:"KuroCat.WorkKeyVolume") as? Double ?? 0.16,fallback:0.16)}
        set {
            let value=Self.normalizedVolume(newValue,fallback:0.16)
            UserDefaults.standard.set(value,forKey:"KuroCat.WorkKeyVolume")
            for key in keys {key.volume=Float(value)}
        }
    }
    var meowVolume: Double {
        get {Self.normalizedVolume(UserDefaults.standard.object(forKey:"KuroCat.WorkMeowVolume") as? Double ?? 0.40,fallback:0.40)}
        set {
            let value=Self.normalizedVolume(newValue,fallback:0.40)
            UserDefaults.standard.set(value,forKey:"KuroCat.WorkMeowVolume")
            meow?.volume=Float(value)
        }
    }
    var popEnabled: Bool {
        get {UserDefaults.standard.object(forKey:"KuroCat.WorkPopSounds") as? Bool ?? true}
        set {
            UserDefaults.standard.set(newValue,forKey:"KuroCat.WorkPopSounds")
            if !newValue {for sound in quotaPops+taskPops {sound.stop()}}
        }
    }
    var popVolume: Double {
        get {Self.normalizedVolume(UserDefaults.standard.object(forKey:"KuroCat.WorkPopVolume") as? Double ?? 0.28,fallback:0.28)}
        set {
            let value=Self.normalizedVolume(newValue,fallback:0.28)
            UserDefaults.standard.set(value,forKey:"KuroCat.WorkPopVolume")
            for sound in quotaPops+taskPops {sound.volume=Float(value)}
        }
    }
    func configure(enabled: Bool, workMode: Bool) {
        let next=Self.shouldPlay(enabled:enabled,workMode:workMode)
        if active && !next {stop()}
        active=next
    }
    func stop() {
        for sound in keys+quotaPops+taskPops {sound.stop()}
        meow?.stop();active=false;lastKey = -.infinity;lastPop = -.infinity
    }
    private var resourceRoot: URL? {Bundle.main.resourceURL?.appendingPathComponent("WorkSounds")}
    private func loadKeys() {
        guard loadedStyle != keyboardStyle,let root=resourceRoot else {return}
        let style=keyboardStyle
        keys=(0..<12).compactMap {NSSound(contentsOf:root.appendingPathComponent(style.rawValue).appendingPathComponent(String(format:"key-%02d.wav",$0)),byReference:false)}
        for key in keys {key.volume=Float(keyboardVolume)}
        loadedStyle=style
    }
    func pickup() {
        guard active,meowVolume>0 else {return}
        if meow == nil,let root=resourceRoot {
            meow=NSSound(contentsOf:root.appendingPathComponent("pickup-meow.wav"),byReference:false)
            meow?.volume=Float(meowVolume)
        }
        meow?.stop();meow?.play()
    }
    func key(at time: Double) {
        guard active,keyboardVolume>0,time-lastKey>=0.035 else {return}
        loadKeys()
        guard let sound=keys.filter({!$0.isPlaying}).randomElement() else {return}
        lastKey=time;sound.play()
    }
    // Called once at the actual keycap-to-bar handoff; batches are coalesced.
    func bubble(isQuota: Bool,at time: Double) {
        guard active,popEnabled,popVolume>0,time-lastPop>=0.10,let root=resourceRoot else {return}
        if quotaPops.isEmpty {
            quotaPops=(0..<3).compactMap {_ in NSSound(contentsOf:root.appendingPathComponent("quota-pop.wav"),byReference:false)}
            taskPops=(0..<3).compactMap {_ in NSSound(contentsOf:root.appendingPathComponent("task-pop.wav"),byReference:false)}
            for sound in quotaPops+taskPops {sound.volume=Float(popVolume)}
        }
        guard let sound=(isQuota ? quotaPops:taskPops).first(where:{!$0.isPlaying}) else {return}
        lastPop=time;sound.play()
    }
}
