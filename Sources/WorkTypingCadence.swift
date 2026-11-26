import Foundation

/// Tracks active autonomous typing time; user input, awaiting and dragging pause this clock.
struct WorkTypingCadence {
    struct Pause {
        var start:Double
        var duration:Double
        var minimumRate:Double
    }
    private(set) var activeTime:Double=0
    private(set) var minute=0
    private(set) var pauses:[Pause]=[]
    init(){schedule()}
    mutating func reset(){activeTime=0;minute=0;schedule()}
    private mutating func schedule(){
        let starts=Bool.random() ? [Double.random(in:20...40)] : [Double.random(in:12...23),Double.random(in:38...49)]
        pauses=starts.map{Pause(start:$0,duration:Double.random(in:3.2...5.5),minimumRate:Double.random(in:0.28...0.42))}
    }
    struct Frame {
        var rate:Double=1
        var slowBeat:Int?=nil
        var isSlow=false
    }
    static func frame(at time:Double,pause:Pause)->Frame {
        let age=time-pause.start
        // Two quicker phrases, then a short continuous return: three seconds in total.
        let slowDuration=2.4,recoveryDuration=0.6
        guard age>=0,age<slowDuration+recoveryDuration else{return Frame()}
        if age<slowDuration {
            let cycle=age.truncatingRemainder(dividingBy:1.2)
            let beatInCycle=Int(cycle/0.25)
            let held=cycle<1 && beatInCycle<4 && cycle-Double(beatInCycle)*0.25<0.09
            let beat=held ? Int(age/1.2)*4+beatInCycle:nil
            return Frame(rate:0.25,slowBeat:beat,isSlow:true)
        }
        let u=max(0,min(1,(age-slowDuration)/recoveryDuration))
        let eased=u*u*(3-2*u)
        return Frame(rate:0.25+0.75*eased)
    }
    mutating func advance(dt:Double,active:Bool)->Frame {
        guard active else{return Frame()}
        activeTime+=max(0,dt)
        let currentMinute=Int(activeTime/60)
        if currentMinute != minute{minute=currentMinute;schedule()}
        let local=activeTime-Double(minute)*60
        return pauses.map{Self.frame(at:local,pause:$0)}.min(by:{$0.rate<$1.rate}) ?? Frame()
    }
}
