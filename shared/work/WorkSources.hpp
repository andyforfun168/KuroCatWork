#pragma once
#include "WorkModel.hpp"
#include "WorkProcess.hpp"
#include "../SkinSpec.hpp"
#include <filesystem>
#include <fstream>
#include <sstream>
#include <mutex>
#include <condition_variable>
#include <functional>
#include <cstdlib>
#include <cwctype>
#ifndef _WIN32
#include <sys/stat.h>
#endif
#ifdef _WIN32
#include <winhttp.h>
#include <tlhelp32.h>
#endif
namespace kurowork {
namespace fs=std::filesystem;
using Json=skinjson::Value;
inline Json parse(const std::string& bytes) {Json value;std::string error;skinjson::Parser parser(bytes);if(!parser.parseDocument(value,error))return {};return value;}
inline const Json& field(const Json& j,const char* key){static const Json empty;auto p=j.get(key);return p?*p:empty;}
inline std::string str(const Json& j){return j.type==Json::JString?j.s:"";}
inline double num(const Json& j,double fallback=0){return j.type==Json::JNumber&&std::isfinite(j.n)?j.n:fallback;}
inline std::string readFile(const fs::path& path,size_t limit=4*1024*1024) {
    std::ifstream file(path,std::ios::binary);if(!file)return {};std::string bytes(limit,'\0');file.read(bytes.data(),(std::streamsize)limit);bytes.resize((size_t)file.gcount());return bytes;
}
inline fs::path homePath(){
#ifdef _WIN32
    wchar_t home[32768];DWORD n=GetEnvironmentVariableW(L"USERPROFILE",home,32768);return n>0&&n<32768?fs::path(home):fs::path();
#else
    const char* value=std::getenv("HOME");return value?fs::u8path(value):fs::path();
#endif
}
inline fs::path codexHome(){const char* p=std::getenv("CODEX_HOME");return p&&*p?fs::u8path(p):homePath()/".codex";}
inline double stamp(const Json& j) {
    if(j.type==Json::JNumber){return j.n>1e12?j.n/1000:j.n;}
    auto s=str(j);int y=0,mo=0,d=0,h=0,m=0;double sec=0;
    if(std::sscanf(s.c_str(),"%d-%d-%dT%d:%d:%lf",&y,&mo,&d,&h,&m,&sec)!=6||mo<1||mo>12||d<1||d>31){return 0;}
    // Gregorian civil date -> UTC epoch. ISO source timestamps carry Z or an explicit offset.
    y-=mo<=2;int era=(y>=0?y:y-399)/400;unsigned yo=(unsigned)(y-era*400);
    unsigned doy=(153*(mo+(mo>2?-3:9))+2)/5+d-1;unsigned doe=yo*365+yo/4-yo/100+doy;
    double result=(era*146097+(int)doe-719468)*86400.0+h*3600+m*60+sec;
    size_t zone=s.find_first_of("Z+-",19);
    if(zone!=std::string::npos&&s[zone]!='Z'){int zh=0,zm=0;if(std::sscanf(s.c_str()+zone+1,"%d:%d",&zh,&zm)==2)result+=(s[zone]=='+'?-1:1)*(zh*3600+zm*60);}
    return result;
}
inline std::optional<Window> quotaWindow(const Json& j,const char* used,const char* reset) {
    const auto& u=field(j,used);if(u.type!=Json::JNumber||!std::isfinite(u.n))return {};
    Window w;w.used=std::clamp(u.n,0.0,100.0);double r=stamp(field(j,reset));if(r>0)w.resetsAt=r;return w;
}
inline Quota codexQuota(const Json& object,double now) {
    Quota q;q.updatedAt=now;
    const Json* bucket=&field(object,"rateLimits");
    if(field(object,"rateLimitsByLimitId").type==Json::JObject){bucket=&field(field(object,"rateLimitsByLimitId"),"codex");}
    if(bucket->type!=Json::JObject){q.message="No allowance window returned";return q;}
    q.stale=false;q.message="Connected";
    for(auto key:{"primary","secondary"}) {const auto& w=field(*bucket,key);auto window=quotaWindow(w,"usedPercent","resetsAt");if(num(field(w,"windowDurationMins"))==300)q.session=window;if(num(field(w,"windowDurationMins"))==10080)q.week=window;}
    return q;
}
inline Quota claudeQuota(const Json& object,double now) {
    Quota q;q.updatedAt=now;q.session=quotaWindow(field(object,"five_hour"),"utilization","resets_at");q.week=quotaWindow(field(object,"seven_day"),"utilization","resets_at");q.stale=!(q.session||q.week);q.message=q.stale?"Usage unavailable":"Connected";return q;
}
inline std::string codexBinary(){
    const char* overridePath=std::getenv("KUROCAT_CODEX_CLI");if(overridePath&&*overridePath)return overridePath;
#ifdef _WIN32
    wchar_t found[32768];DWORD n=SearchPathW(nullptr,L"codex.exe",nullptr,32768,found,nullptr);
    if(n>0&&n<32768)return fs::path(std::wstring(found,n)).u8string();
    auto npm=homePath()/"AppData"/"Roaming"/"npm"/"node_modules"/"@openai";
    for(auto root:{npm/"codex"/"node_modules"/"@openai"/"codex-win32-x64",npm/"codex-win32-x64",npm/"codex"}){
        auto file=root/"vendor"/"x86_64-pc-windows-msvc"/"codex"/"codex.exe";std::error_code e;if(fs::is_regular_file(file,e))return file.u8string();
    }
#endif
    return "codex";
}
inline Quota fetchCodex(const std::atomic<bool>& cancelled) {
    Process child;Quota q;q.message="Codex CLI unavailable or not signed in";
    if(!child.start({codexBinary(),"app-server","--listen","stdio://"})){return q;}
    if(!child.write("{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"kurocat_work\",\"version\":\"1.4.6\"},\"capabilities\":{\"experimentalApi\":true}}}\n")){return q;}
    std::string buffer;
    auto response=[&](int id,double timeout)->Json{
        double until=wallNow()+timeout;
        while(!cancelled&&wallNow()<until){buffer+=child.readFor(.1,cancelled);size_t end;
            while((end=buffer.find('\n'))!=std::string::npos){auto j=parse(buffer.substr(0,end));buffer.erase(0,end+1);if(num(field(j,"id"),-1)==id)return field(j,"result");}
            if(buffer.size()>4*1024*1024){break;}
        }return {};
    };
    if(response(1,6).type!=Json::JObject){return q;}
    child.write("{\"method\":\"initialized\"}\n{\"id\":2,\"method\":\"account/rateLimits/read\",\"params\":{}}\n");
    return codexQuota(response(2,8),wallNow());
}
inline Quota fetchClaude(const std::atomic<bool>& cancelled) {
    Quota q;q.message="Sign into Claude Code to read usage";
    auto credentials=parse(readFile(homePath()/".claude"/".credentials.json",262144));
    auto token=str(field(field(credentials,"claudeAiOauth"),"accessToken"));
    if(token.empty()||token.find_first_of("\r\n\"")!=std::string::npos){return q;}
    std::string result;
#ifdef _WIN32
    HINTERNET session=WinHttpOpen(L"KuroCatWork/1.4.6",WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,WINHTTP_NO_PROXY_NAME,WINHTTP_NO_PROXY_BYPASS,0);
    if(!session){return q;}WinHttpSetTimeouts(session,3000,3000,3000,3000);
    DWORD tls=WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2;WinHttpSetOption(session,WINHTTP_OPTION_SECURE_PROTOCOLS,&tls,sizeof(tls));
    HINTERNET connection=WinHttpConnect(session,L"api.anthropic.com",INTERNET_DEFAULT_HTTPS_PORT,0);
    HINTERNET request=connection?WinHttpOpenRequest(connection,L"GET",L"/api/oauth/usage",nullptr,WINHTTP_NO_REFERER,WINHTTP_DEFAULT_ACCEPT_TYPES,WINHTTP_FLAG_SECURE):nullptr;
    if(request){std::wstring headers=L"Authorization: Bearer "+wide(token)+L"\r\nanthropic-beta: oauth-2025-04-20\r\n";
        if(!cancelled&&WinHttpSendRequest(request,headers.c_str(),(DWORD)-1L,WINHTTP_NO_REQUEST_DATA,0,0,0)&&WinHttpReceiveResponse(request,nullptr)){
            DWORD code=0,size=sizeof(code);WinHttpQueryHeaders(request,WINHTTP_QUERY_STATUS_CODE|WINHTTP_QUERY_FLAG_NUMBER,WINHTTP_HEADER_NAME_BY_INDEX,&code,&size,WINHTTP_NO_HEADER_INDEX);
            if(code==200)while(!cancelled&&result.size()<262144){char buf[8192];DWORD n=0;if(!WinHttpReadData(request,buf,sizeof(buf),&n)||!n)break;result.append(buf,n);}
        }WinHttpCloseHandle(request);
    }if(connection)WinHttpCloseHandle(connection);WinHttpCloseHandle(session);
#else
    Process child;
    if(child.start({"curl","--silent","--fail","--proto","=https","--max-time","10","--config","-","https://api.anthropic.com/api/oauth/usage"})) {
        // Send the token over stdin, never in argv or a generated file.
        child.write("header = \"Authorization: Bearer "+token+"\"\nheader = \"anthropic-beta: oauth-2025-04-20\"\n");child.closeInput();result=child.readFor(11,cancelled);
    }
#endif
    if(result.empty()){return q;}return claudeQuota(parse(result),wallNow());
}
inline std::vector<fs::path> recentFiles(const fs::path& root) {
    std::vector<fs::path> paths;std::error_code error;
    fs::recursive_directory_iterator it(root,fs::directory_options::skip_permission_denied,error),end;
    for(size_t scanned=0;!error&&it!=end&&scanned<6000;it.increment(error),++scanned){if(it.depth()>4){it.disable_recursion_pending();continue;}if(it->is_regular_file(error)&&it->path().extension()==".jsonl")paths.push_back(it->path());}
    auto modified=[](const fs::path& p){std::error_code e;auto t=fs::last_write_time(p,e);return e?fs::file_time_type::min():t;};
    std::sort(paths.begin(),paths.end(),[&](const auto& a,const auto& b){return modified(a)>modified(b);});if(paths.size()>30)paths.resize(30);return paths;
}
inline std::optional<Task> sessionTask(const fs::path& path,Tool tool) {
    Task task;task.tool=tool;task.source=tool==Tool::Codex?"CODEX CLI":"CLAUDE CODE";task.project=path.parent_path().filename().u8string();task.title=task.source;
    std::ifstream file(path,std::ios::binary);if(!file)return {};
    std::string first;std::getline(file,first);
    auto meta=parse(first);auto payload=field(meta,"payload");
    std::string id=tool==Tool::Codex?str(field(payload,"id")):str(field(meta,"sessionId"));
    if(id.empty()){id=path.stem().u8string();}task.key=(tool==Tool::Codex?"codex:":"claude-cli:")+id;
    if(tool==Tool::Codex){task.link="codex://threads/"+id;auto cwd=str(field(payload,"cwd"));if(!cwd.empty())task.project=fs::u8path(cwd).filename().u8string();}
    file.seekg(0,std::ios::end);auto size=file.tellg();auto offset=std::max<std::streamoff>(0,(std::streamoff)size-8*1024*1024);file.seekg(offset);if(offset)std::getline(file,first);
    bool found=false;std::string line;
    while(std::getline(file,line)) {
        if(line.size()>4*1024*1024){continue;}
        bool relevant=tool==Tool::Codex?(line.find("task_started")!=std::string::npos||line.find("task_complete")!=std::string::npos||line.find("turn_aborted")!=std::string::npos):(line.find("\"user\"")!=std::string::npos||line.find("\"assistant\"")!=std::string::npos);
        if(!relevant){continue;}auto object=parse(line);double time=stamp(field(object,"timestamp"));if(time<=0)continue;
        if(tool==Tool::Codex){if(str(field(object,"type"))!="event_msg")continue;auto event=field(object,"payload");auto type=str(field(event,"type"));
            if(type=="task_started"){task.state=State::Running;task.startedAt=time;task.turn=str(field(event,"turn_id"));found=true;}
            else if(type=="task_complete"||type=="turn_aborted"){if(task.turn.empty()||str(field(event,"turn_id")).empty()||task.turn==str(field(event,"turn_id"))){task.state=type=="turn_aborted"?State::Cancelled:State::Completed;found=true;}}
            else continue;
        } else {
            auto type=str(field(object,"type"));auto message=field(object,"message");
            if(type=="user"&&field(object,"isMeta").b!=true){bool result=false;for(const auto& item:field(message,"content").items)result|=str(field(item,"type"))=="tool_result";if(!result){task.startedAt=time;task.turn=str(field(object,"uuid"));}task.state=State::Running;found=true;}
            else if(type=="assistant"&&(str(field(message,"stop_reason"))=="end_turn"||str(field(message,"stop_reason"))=="stop_sequence")){task.state=State::Completed;found=true;}else continue;
        }
        task.changedAt=time;
    }
    if(!found|| (Model::busy(task.state)&&wallNow()-task.changedAt>21600)){return {};}
    if(task.startedAt==0){task.startedAt=task.changedAt;}
    return task;
}
inline std::vector<Task> scanTasks(const std::set<Tool>& selected,const std::atomic<bool>& cancelled) {
    std::vector<Task> result;
    for(auto tool:selected){auto root=tool==Tool::Codex?codexHome()/"sessions":homePath()/".claude"/"projects";for(const auto& file:recentFiles(root)){if(cancelled)return {};if(auto task=sessionTask(file,tool))result.push_back(*task);}}
    return result;
}
inline std::set<Tool> openTools(){std::set<Tool> result;
#ifdef _WIN32
    HANDLE snapshot=CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0);if(snapshot==INVALID_HANDLE_VALUE)return result;PROCESSENTRY32W entry{};entry.dwSize=sizeof(entry);if(Process32FirstW(snapshot,&entry))do{if(entry.th32ProcessID==GetCurrentProcessId()||entry.th32ParentProcessID==GetCurrentProcessId())continue;std::wstring name=entry.szExeFile;std::transform(name.begin(),name.end(),name.begin(),::towlower);if(name==L"codex.exe")result.insert(Tool::Codex);if(name==L"claude.exe")result.insert(Tool::Claude);}while(Process32NextW(snapshot,&entry));CloseHandle(snapshot);
#elif defined(__linux__)
    std::error_code error;fs::directory_iterator it("/proc",error),end;for(size_t count=0;!error&&it!=end&&count<6000;it.increment(error),++count){auto name=it->path().filename().string();if(name.empty()||!std::all_of(name.begin(),name.end(),[](unsigned char c){return std::isdigit(c);})||name==std::to_string(getpid()))continue;struct stat info{};if(stat(it->path().c_str(),&info)!=0||info.st_uid!=getuid())continue;auto command=readFile(it->path()/"cmdline",1024);auto first=command.find('\0');std::string exe=fs::u8path(command.substr(0,first)).filename().string();auto status=readFile(it->path()/"status",2048);auto parent=status.find("PPid:");if(parent!=std::string::npos&&std::strtol(status.c_str()+parent+5,nullptr,10)==getpid())continue;if(exe=="codex")result.insert(Tool::Codex);if(exe=="claude")result.insert(Tool::Claude);if(exe=="node"&&first!=std::string::npos){auto second=command.substr(first+1);second.resize(second.find('\0')==std::string::npos?second.size():second.find('\0'));if(second.find("@openai/codex")!=std::string::npos)result.insert(Tool::Codex);if(second.find("claude-code")!=std::string::npos)result.insert(Tool::Claude);}}
#endif
    return result;
}
struct SourceResult {std::vector<Task> tasks;std::map<Tool,Quota> quotas;std::set<Tool> providers;};
class SourceWorker {
public:
    SourceWorker(){thread_=std::thread([this]{run();});}
    ~SourceWorker(){cancelled_=true;{std::lock_guard<std::mutex> lock(mutex_);quit_=true;}condition_.notify_one();thread_.join();}
    void cancel(){cancelled_=true;std::lock_guard<std::mutex> lock(mutex_);++generation_;pending_=false;ready_=false;}
    void request(std::set<Tool> tools,bool quota){std::lock_guard<std::mutex> lock(mutex_);if(working_||pending_)return;cancelled_=false;tools_=std::move(tools);quota_=quota;pending_=true;condition_.notify_one();}
    std::optional<SourceResult> take(){std::lock_guard<std::mutex> lock(mutex_);if(!ready_)return {};ready_=false;return result_;}
private:
    std::mutex mutex_;std::condition_variable condition_;std::thread thread_;std::atomic<bool> cancelled_{false};bool quit_=false,pending_=false,working_=false,ready_=false,quota_=false;unsigned generation_=0;std::set<Tool> tools_;SourceResult result_;
    void run(){for(;;){std::unique_lock<std::mutex> lock(mutex_);condition_.wait(lock,[this]{return quit_||pending_;});if(quit_)return;auto tools=tools_;auto quota=quota_;auto gen=generation_;pending_=false;working_=true;lock.unlock();SourceResult next;next.providers=openTools();next.tasks=scanTasks(tools,cancelled_);if(quota&&!cancelled_)for(auto tool:tools){if(cancelled_)break;next.quotas[tool]=tool==Tool::Codex?fetchCodex(cancelled_):fetchClaude(cancelled_);}lock.lock();working_=false;if(gen==generation_&&!cancelled_){result_=std::move(next);ready_=true;}}}
};
}
