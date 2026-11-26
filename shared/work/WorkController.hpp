#pragma once
#include "WorkSources.hpp"
#include "WorkAudio.hpp"
#include "WorkHooks.hpp"
#include <random>
namespace kurowork {
inline std::string escaped(const std::string& s){std::string result="\"";for(unsigned char c:s){if(c=='"'||c=='\\'){result+='\\';result+=c;}else if(c=='\n')result+="\\n";else if(c=='\r')result+="\\r";else if(c=='\t')result+="\\t";else if(c>=32)result+=c;}return result+'"';}
inline fs::path statePath(){
#ifdef _WIN32
    return homePath()/"AppData"/"Roaming"/"KuroCatWork"/"work-state.json";
#else
    const char* config=std::getenv("XDG_CONFIG_HOME");return (config&&*config?fs::u8path(config):homePath()/".config")/"kurocatwork"/"work-state.json";
#endif
}
struct Birth {std::string key;Tool tool;double started;float x=82,y=-90;};
class Controller {
public:
    Model model;SourceWorker sources;Audio audio;
    float elapsed=0,autoAge=0,nextKey=0,birthAge=0,opacity=0;
    bool showsAll=false,realTyping=false,toolChosen=false;
    int pendingBirths=0;double lastSave=0;std::vector<Birth> births;std::deque<std::pair<std::string,Tool>> birthQueue;
    void queueBirth(const std::string& key,Tool tool){birthQueue.emplace_back(key,tool);}
    void queueTools(){birthQueue.clear();births.clear();for(auto tool:{Tool::Codex,Tool::Claude})if(model.shows(tool))queueBirth(tool==Tool::Codex?"quota:codex":"quota:claude",tool);}
    std::mt19937 random{std::random_device{}()};
    Controller(){load();}
    void toggle(){if(model.enabled){model.leave(wallNow());sources.cancel();audio.stop();}else{model.enter(wallNow());queueTools();}save();}
    void select(Selection selection){toolChosen=true;model.options.selection=selection;model.detected.clear();model.nextTaskPoll=model.nextQuotaPoll=0;sources.cancel();audio.stop();if(model.enabled)queueTools();save();}
    void save(){
        std::error_code e;auto path=statePath();fs::create_directories(path.parent_path(),e);if(e)return;
        std::string json="{\"toolChosen\":"+std::string(toolChosen?"true":"false")+",\"popSound\":"+(model.options.popSound?"true":"false")+",\"enabled\":"+std::string(model.enabled?"true":"false")+",\"selection\":"+std::to_string((int)model.options.selection)+",\"autoTyping\":"+(model.options.autonomousTyping?"true":"false")+",\"expressions\":"+(model.options.randomExpressions?"true":"false")+",\"bubbles\":"+(model.options.typingBubbles?"true":"false")+",\"dismissed\":[";
        bool comma=false;for(const auto& key:model.dismissed){if(comma)json+=',';comma=true;json+=escaped(key);}json+="],\"sound\":"+std::string(model.options.sound?"true":"false")+",\"axis\":"+std::to_string(model.options.switchType)+",\"keyboardVolume\":"+std::to_string(model.options.keyboardVolume)+",\"meowVolume\":"+std::to_string(model.options.meowVolume)+",\"popVolume\":"+std::to_string(model.options.popVolume)+",\"tasks\":[";comma=false;
        for(const auto& pair:model.tasks){const auto& t=pair.second;if(t.read||t.state==State::Running||t.state==State::Completed)continue;if(comma)json+=',';comma=true;
            json+="{\"key\":"+escaped(t.key)+",\"turn\":"+escaped(t.turn)+",\"title\":"+escaped(t.title)+",\"link\":"+escaped(t.link)+",\"project\":"+escaped(t.project)+",\"source\":"+escaped(t.source)+",\"tool\":"+std::to_string((int)t.tool)+",\"state\":"+std::to_string((int)t.state)+",\"started\":"+std::to_string(t.startedAt)+",\"changed\":"+std::to_string(t.changedAt)+"}";
        }json+="]}";
        auto staging=path;staging+=".tmp";{std::ofstream f(staging,std::ios::binary|std::ios::trunc);f<<json;if(!f)return;}
#ifdef _WIN32
        MoveFileExW(staging.c_str(),path.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH);
#else
        fs::rename(staging,path,e);fs::permissions(path,fs::perms::owner_read|fs::perms::owner_write,fs::perm_options::replace,e);
#endif
    }
    void load(){auto json=parse(readFile(statePath(),1024*1024));if(json.type!=Json::JObject)return;
        toolChosen=field(json,"toolChosen").b;
        if(field(json,"popSound").type==Json::JBool)model.options.popSound=field(json,"popSound").b;
        model.options.selection=(Selection)std::clamp((int)num(field(json,"selection")),0,3);
        if(field(json,"autoTyping").type==Json::JBool){model.options.autonomousTyping=field(json,"autoTyping").b;}
        if(field(json,"expressions").type==Json::JBool){model.options.randomExpressions=field(json,"expressions").b;}
        if(field(json,"bubbles").type==Json::JBool){model.options.typingBubbles=field(json,"bubbles").b;}
        model.options.sound=field(json,"sound").b;model.options.switchType=std::clamp((int)num(field(json,"axis")),0,2);
        if(field(json,"keyboardVolume").type==Json::JNumber){model.options.keyboardVolume=std::clamp(num(field(json,"keyboardVolume")),0.,1.);}
        if(field(json,"meowVolume").type==Json::JNumber){model.options.meowVolume=std::clamp(num(field(json,"meowVolume")),0.,1.);}
        if(field(json,"popVolume").type==Json::JNumber){model.options.popVolume=std::clamp(num(field(json,"popVolume")),0.,1.);}
        for(const auto& value:field(json,"dismissed").items)if(value.type==Json::JString)model.dismissed.insert(value.s);
        for(const auto& value:field(json,"tasks").items){Task t;t.key=str(field(value,"key"));t.turn=str(field(value,"turn"));t.title=str(field(value,"title"));t.link=str(field(value,"link"));t.project=str(field(value,"project"));t.source=str(field(value,"source"));t.tool=(Tool)std::clamp((int)num(field(value,"tool")),0,1);t.state=(State)std::clamp((int)num(field(value,"state")),0,4);t.startedAt=num(field(value,"started"));t.changedAt=num(field(value,"changed"));if(!t.key.empty()&&!Model::busy(t.state)&&t.state!=State::Completed)model.tasks[t.key]=t;else if(t.state==State::Awaiting)model.tasks[t.key]=t;}
        if(field(json,"enabled").b){model.enter(wallNow());queueTools();}
    }
    template<class Physics,class Engine,class Settings,class Skin>
    void beforeStep(float dt,Physics& p,const Engine& input,Settings& settings,const Skin& skin,bool dragging,double monotonic){
        elapsed+=std::min(dt,.1f);double now=wallNow();bool was=model.enabled;model.tick(now);if(was&&!model.enabled){sources.cancel();audio.stop();save();}
        opacity=std::clamp(opacity+(model.enabled?dt*7:-dt*5),0.f,1.f);
        p.workMode=model.enabled;p.workAwaiting=model.waiting();p.workAngry=model.angryWaiting(now);p.workKeys.clear();
        settings.keyboardMarquee=model.enabled;p.workShowBubbles=model.options.typingBubbles;
        if(!model.enabled){p.workAutonomous=false;p.workRandomAngry=false;p.workDizzy=false;p.workBlinkClosure=0;return;}
        if(auto result=sources.take()){
            for(const auto& hook:hookTasks()){
                auto task=std::find_if(result->tasks.begin(),result->tasks.end(),[&](const Task& t){return t.key==hook.key;});
                if(task!=result->tasks.end()){if(hook.changedAt>=task->changedAt&&(hook.turn.empty()||task->turn.empty()||hook.turn==task->turn)){task->state=hook.state;task->changedAt=hook.changedAt;}}
                else result->tasks.push_back(hook);
            }
            if(model.options.selection==Selection::Automatic)for(auto tool:result->providers)if(model.detected.insert(tool).second)queueBirth(tool==Tool::Codex?"quota:codex":"quota:claude",tool);
            for(const auto& task:result->tasks)if(!model.tasks.count(task.key)&&model.shows(task.tool)&&birthQueue.size()<3)queueBirth(task.key,task.tool);
            auto previousTools=model.detected;model.merge(result->tasks);
            if(model.options.selection==Selection::Automatic)for(auto tool:model.detected)if(!previousTools.count(tool))queueBirth(tool==Tool::Codex?"quota:codex":"quota:claude",tool);
            for(const auto& entry:result->quotas){auto old=model.quotas.find(entry.first);if(entry.second.stale&&old!=model.quotas.end()){old->second.stale=true;old->second.message=entry.second.message;}else model.quotas[entry.first]=entry.second;}save();
        }
        bool quota=model.takeQuotaPoll(now),tasks=model.takeTaskPoll(now);
        if(quota||tasks){std::set<Tool> tools;if(model.options.selection==Selection::Automatic||model.options.selection==Selection::Both)tools={Tool::Codex,Tool::Claude};else tools={model.options.selection==Selection::Claude?Tool::Claude:Tool::Codex};sources.request(std::move(tools),quota);}
        if(now-lastSave>30){save();lastSave=now;}
        realTyping=!input.activeKeys.empty()||monotonic-input.lastKeyActivityTime<.35;
        auto frame=model.typing(dt,dragging,p.petHeadIntensity>.05f||p.petBodyIntensity>.05f,realTyping);
        p.workAutonomous=frame.active;
        if(dragging&&!wasDragging_){audio.play(Sound::Pickup,model.options);}wasDragging_=dragging;
        if(!input.activeKeys.empty()&&elapsed-lastRealSound_>.065f){audio.play(Sound::Key,model.options,model.options.switchType);lastRealSound_=elapsed;}
        births.erase(std::remove_if(births.begin(),births.end(),[&](const Birth& b){return now-b.started>1;}),births.end());
        if(!dragging&&!realTyping&&!birthQueue.empty()&&elapsed-birthAge>.38f){auto next=birthQueue.front();birthQueue.pop_front();birthAge=elapsed;audio.play(next.first.find("quota:")==0?Sound::Quota:Sound::Task,model.options);p.workKeys.insert(PhysicalKey::Space);size_t count=p.floatingKeycaps.size();emit(p,settings,skin,input,PhysicalKey::Space,true);Birth birth{next.first,next.second,now,82,-90};if(p.floatingKeycaps.size()>count){auto cap=p.floatingKeycaps.back();birth.x=cap.position.x-103;birth.y=cap.position.y-306;p.floatingKeycaps.pop_back();}births.push_back(birth);}
        if(frame.active){autoAge+=dt;if(autoAge>=nextKey){nextKey=autoAge+(float)frame.interval;audio.play(Sound::Key,model.options,model.options.switchType);
            const PhysicalKey left[]={PhysicalKey::A,PhysicalKey::S,PhysicalKey::D,PhysicalKey::F,PhysicalKey::W};const PhysicalKey right[]={PhysicalKey::J,PhysicalKey::K,PhysicalKey::L,PhysicalKey::I,PhysicalKey::O};
            left_=left[random()%5];right_=right[random()%5];emit(p,settings,skin,input,left_,false);emit(p,settings,skin,input,right_,false);keyUntil_=elapsed+.055f;}
            if(elapsed<keyUntil_){p.workKeys.insert(left_);p.workKeys.insert(right_);}
        }
        if(model.options.randomExpressions&&frame.active&&elapsed>nextExpression_){bool longTask=false;for(const auto& entry:model.tasks)longTask|=entry.second.state==State::Running&&now-entry.second.startedAt>=3600;expression_=longTask?(random()%10<8?1:0):(random()%2);expressionUntil_=elapsed+2.5f;nextExpression_=elapsed+45+random()%31;}
        p.workRandomAngry=frame.active&&elapsed<expressionUntil_&&expression_==0;
        bool dizzy=frame.active&&elapsed<expressionUntil_&&expression_==1;
        if(previousDizzy_&&!dizzy){blinkStart_=elapsed;}
        previousDizzy_=dizzy;p.workDizzy=dizzy;
        float blinkAge=elapsed-blinkStart_;p.workBlinkClosure=0;
        if(blinkAge>=0&&blinkAge<.23f){float t=blinkAge<.095f?blinkAge:blinkAge-.135f;if(t>=0&&t<.095f)p.workBlinkClosure=std::sin(t/.095f*3.14159265f);if(blinkAge<.0475f)p.workDizzy=true;}

    }
private:
    bool previousDizzy_=false;float blinkStart_=-100;
    bool wasDragging_=false;float lastRealSound_=0;
    PhysicalKey left_=PhysicalKey::F,right_=PhysicalKey::J;float keyUntil_=0,nextExpression_=55,expressionUntil_=0;int expression_=0;
    template<class P,class S,class K,class E>static void emit(P& p,const S& settings,const K& skin,const E& input,PhysicalKey key,bool force){auto copy=settings;copy.showKeyBadges=force||p.workShowBubbles;bool previous=p.workShowBubbles;if(force)p.workShowBubbles=true;
#ifdef _WIN32
        p.triggerKeyDown(key,copy,skin.typingStyle==SkinTypingStyle::Douni,&input.activeKeys);
#else
        p.triggerKeyDown(key,copy,skin.typingStyle,&input);
#endif
        p.workShowBubbles=previous;
    }
};
}
