#pragma once
#include "WorkSources.hpp"
#include <iostream>
#ifndef _WIN32
#include <sys/file.h>
#endif
namespace kurowork {
inline fs::path workDirectory(){
#ifdef _WIN32
    return homePath()/"AppData"/"Roaming"/"KuroCatWork";
#else
    const char* p=std::getenv("XDG_CONFIG_HOME");return (p&&*p?fs::u8path(p):homePath()/".config")/"kurocatwork";
#endif
}
inline std::string jsonQuote(const std::string& value){std::string out="\"";for(unsigned char c:value){if(c=='"'||c=='\\'){out+='\\';out+=c;}else if(c=='\n')out+="\\n";else if(c=='\r')out+="\\r";else if(c=='\t')out+="\\t";else if(c>=32)out+=c;}return out+'"';}
inline std::string encode(const Json& value){switch(value.type){case Json::JBool:return value.b?"true":"false";case Json::JNumber:return std::to_string(value.n);case Json::JString:return jsonQuote(value.s);case Json::JArray:case Json::JObject:{bool obj=value.type==Json::JObject;std::string out=obj?"{":"[";for(size_t i=0;i<value.items.size();++i){if(i)out+=',';if(obj)out+=jsonQuote(value.keys[i])+":";out+=encode(value.items[i]);}return out+(obj?"}":"]");}default:return "null";}}
inline void put(Json& value,const std::string& key,Json item){value.type=Json::JObject;for(size_t i=0;i<value.keys.size();++i)if(value.keys[i]==key){value.items[i]=std::move(item);return;}value.keys.push_back(key);value.items.push_back(std::move(item));}
inline Json js(const std::string& value){Json j;j.type=Json::JString;j.s=value;return j;}
inline Json jn(double value){Json j;j.type=Json::JNumber;j.n=value;return j;}
inline bool sessionID(const std::string& id){if(id.size()!=36)return false;for(size_t i=0;i<36;++i){if(i==8||i==13||i==18||i==23){if(id[i]!='-')return false;}else if(!std::isxdigit((unsigned char)id[i]))return false;}return true;}
class EventLock {
public:
    explicit EventLock(const fs::path& path){
#ifdef _WIN32
        handle=CreateFileW(path.c_str(),GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);if(handle!=INVALID_HANDLE_VALUE){OVERLAPPED o{};locked=LockFileEx(handle,LOCKFILE_EXCLUSIVE_LOCK,0,1,0,&o)!=0;}
#else
        fd=open(path.c_str(),O_CREAT|O_RDWR,0600);locked=fd>=0&&flock(fd,LOCK_EX)==0;
#endif
    }
    ~EventLock(){
#ifdef _WIN32
        if(handle!=INVALID_HANDLE_VALUE){OVERLAPPED o{};if(locked)UnlockFileEx(handle,0,1,0,&o);CloseHandle(handle);}
#else
        if(fd>=0){if(locked)flock(fd,LOCK_UN);close(fd);}
#endif
    }
    bool locked=false;
private:
#ifdef _WIN32
    HANDLE handle=INVALID_HANDLE_VALUE;
#else
    int fd=-1;
#endif
};
inline bool atomicJson(const fs::path& file,const Json& value){std::error_code e;auto tmp=file;tmp+=".tmp";{std::ofstream out(tmp,std::ios::binary|std::ios::trunc);out<<encode(value);if(!out)return false;}
#ifdef _WIN32
    return MoveFileExW(tmp.c_str(),file.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)!=0;
#else
    fs::rename(tmp,file,e);fs::permissions(file,fs::perms::owner_read|fs::perms::owner_write,fs::perm_options::replace,e);return !e;
#endif
}
inline void handleEvent(const std::string& raw,Tool tool,const fs::path& root=workDirectory()/"work-events",double now=wallNow()){
    if(raw.size()>4*1024*1024){return;}auto input=parse(raw);auto id=str(field(input,"session_id")),event=str(field(input,"hook_event_name"));if(!sessionID(id)||field(input,"agent_id").type!=Json::JNull)return;
    std::error_code e;fs::create_directories(root,e);if(e)return;EventLock lock(root/".lock");if(!lock.locked)return;
    auto path=root/((tool==Tool::Codex?"codex-":"claude-")+id+".json");auto value=parse(readFile(path,16384));if(value.type!=Json::JObject)value=Json{};
    auto turn=str(field(input,"turn_id"));if(!turn.empty()&&str(field(value,"turn"))!=turn){value=Json{};put(value,"turn",js(turn));put(value,"started",jn(now));}
    std::string state=str(field(value,"state"));if(state.empty())state="running";
    if(event=="UserPromptSubmit"){state="running";put(value,"started",jn(now));}
    else if(event=="PermissionRequest")state="awaiting";
    else if(event=="Notification"){auto type=str(field(input,"notification_type"));if(type!="permission_prompt"&&type!="elicitation_dialog")return;state="awaiting";}
    else if(event=="PreToolUse"){if(str(field(input,"tool_name"))=="AskUserQuestion")state="awaiting";}
    else if(event=="PostToolUse"||event=="PostToolUseFailure")state="running";
    else if(event=="StopFailure")state="failed";
    else if(event=="Interrupt")state="cancelled";
    else if(event=="Stop")state="completed";
    else if(event=="SessionEnd"){if(state!="completed")state="cancelled";}
    else return;
    if(str(field(value,"state"))!=state){put(value,"changed",jn(now));}
    put(value,"id",js(id));put(value,"tool",js(tool==Tool::Codex?"codex":"claude"));put(value,"state",js(state));put(value,"updated",jn(now));put(value,"cwd",js(str(field(input,"cwd"))));if(field(value,"started").type==Json::JNull)put(value,"started",jn(now));atomicJson(path,value);
}
inline std::vector<Task> hookTasks(){std::vector<Task> tasks;std::error_code e;auto root=workDirectory()/"work-events";fs::directory_iterator it(root,e),end;for(int count=0;!e&&it!=end&&count<300;it.increment(e),++count){if(it->path().extension()!=".json")continue;auto value=parse(readFile(it->path(),16384));auto id=str(field(value,"id"));if(!sessionID(id))continue;auto state=str(field(value,"state"));Task t;
    if(state=="running"){t.state=State::Running;}else if(state=="awaiting")t.state=State::Awaiting;else if(state=="completed")t.state=State::Completed;else if(state=="failed")t.state=State::Failed;else if(state=="cancelled")t.state=State::Cancelled;else continue;
    t.changedAt=num(field(value,"changed"));if(Model::busy(t.state)&&wallNow()-num(field(value,"updated"))>21600)continue;
    t.tool=str(field(value,"tool"))=="codex"?Tool::Codex:Tool::Claude;t.key=(t.tool==Tool::Codex?"codex:":"claude-cli:")+id;t.title=t.tool==Tool::Codex?"Codex":"Claude Code";t.startedAt=num(field(value,"started"));t.turn=str(field(value,"turn"));t.project=fs::u8path(str(field(value,"cwd"))).filename().u8string();t.source=t.tool==Tool::Codex?"CODEX CLI":"CLAUDE CODE";if(t.tool==Tool::Codex)t.link="codex://threads/"+id;tasks.push_back(t);
}return tasks;}
inline fs::path executablePath(){
#ifdef _WIN32
    wchar_t path[32768];DWORD n=GetModuleFileNameW(nullptr,path,32768);return fs::path(std::wstring(path,n));
#else
    char path[4096];auto n=readlink("/proc/self/exe",path,sizeof(path)-1);if(n<=0)return {};path[n]=0;return fs::path(path);
#endif
}
// Merge only this app's entries, preserving every unrelated hook and backing up existing settings.
inline bool installHooks(Tool tool,std::string& error){
    auto settings=tool==Tool::Codex?codexHome()/"hooks.json":homePath()/".claude"/"settings.json";
    std::error_code e;bool exists=fs::exists(settings,e);Json document;
    if(exists){document=parse(readFile(settings));if(document.type!=Json::JObject){error="Existing hook settings are not valid JSON; no changes were made.";return false;}}
    Json hooks=field(document,"hooks");if(hooks.type!=Json::JNull&&hooks.type!=Json::JObject){error="Unexpected hooks format; no changes were made.";return false;}hooks.type=Json::JObject;
    auto exe=executablePath();if(exe.empty())return false;
    auto command=jsonQuote(exe.generic_u8string())+(tool==Tool::Codex?" --work-codex-event":" --work-claude-event");
    for(auto event:{"UserPromptSubmit","PermissionRequest","Notification","PreToolUse","PostToolUse","PostToolUseFailure","Stop","StopFailure","Interrupt","SessionEnd"}){
        if(tool==Tool::Codex&&(std::string(event)=="Notification"||std::string(event)=="PreToolUse"||std::string(event)=="PostToolUseFailure"||std::string(event)=="StopFailure")){continue;}
        Json list=field(hooks,event);if(list.type!=Json::JNull&&list.type!=Json::JArray){error="Unexpected event format; no changes were made.";return false;}list.type=Json::JArray;
        bool already=false;for(const auto& entry:list.items)for(const auto& handler:field(entry,"hooks").items)already|=str(field(handler,"command"))==command;
        if(!already){Json handler;put(handler,"type",js("command"));put(handler,"command",js(command));Json handlers;handlers.type=Json::JArray;handlers.items.push_back(handler);Json group;put(group,"hooks",handlers);list.items.push_back(group);}put(hooks,event,list);
    }
    put(document,"hooks",hooks);fs::create_directories(settings.parent_path(),e);if(e){error=e.message();return false;}
    if(exists){auto backup=settings;backup+=".kurocatwork-"+std::to_string((long long)wallNow())+".bak";fs::copy_file(settings,backup,fs::copy_options::none,e);if(e){error=e.message();return false;}}
    if(!atomicJson(settings,document)){error="Could not write hook settings";return false;}return true;
}
inline bool eventArgument(const std::string& arg){return arg=="--work-codex-event"||arg=="--work-claude-event";}
inline int eventEntry(const std::string& arg){std::string raw;char bytes[8192];while(std::cin&&raw.size()<4*1024*1024){std::cin.read(bytes,sizeof(bytes));raw.append(bytes,(size_t)std::cin.gcount());}handleEvent(raw,arg=="--work-codex-event"?Tool::Codex:Tool::Claude);return 0;}
}
