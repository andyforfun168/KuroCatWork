#pragma once
#include <atomic>
#include <chrono>
#include <string>
#include <thread>
#include <vector>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <pthread.h>
#include <cerrno>
#include <sys/wait.h>
#include <unistd.h>
#endif
namespace kurowork {
inline double wallNow() {return std::chrono::duration<double>(std::chrono::system_clock::now().time_since_epoch()).count();}
#ifdef _WIN32
inline std::wstring wide(const std::string& value) {
    if(value.empty()){ return {};}
    int n=MultiByteToWideChar(CP_UTF8,0,value.data(),(int)value.size(),nullptr,0);
    std::wstring result(n,0); MultiByteToWideChar(CP_UTF8,0,value.data(),(int)value.size(),result.data(),n); return result;
}
inline std::wstring quoteArg(const std::wstring& arg) {
    std::wstring result=L"\""; size_t slashes=0;
    for(wchar_t ch:arg) {if(ch==L'\\'){++slashes;continue;} result.append(slashes*(ch==L'"'?2:1),L'\\');slashes=0;if(ch==L'"')result+=L'\\';result+=ch;}
    result.append(slashes*2,L'\\'); return result+L'"';
}
#endif
// Short-lived, read-only child process. No shell expansion and no user-supplied commands.
class Process {
public:
    ~Process(){stop();}
    Process()=default; Process(const Process&)=delete; Process& operator=(const Process&)=delete;
    bool start(const std::vector<std::string>& args) {
        if(args.empty()){ return false;}
#ifdef _WIN32
        SECURITY_ATTRIBUTES sa{sizeof(sa),nullptr,TRUE}; HANDLE readIn=nullptr,writeOut=nullptr;
        if(!CreatePipe(&readOut_,&writeOut,&sa,0)){ return false;}
        if(!CreatePipe(&readIn,&writeIn_,&sa,0)){CloseHandle(readOut_);readOut_=nullptr;CloseHandle(writeOut);return false;}
        SetHandleInformation(readOut_,HANDLE_FLAG_INHERIT,0);SetHandleInformation(writeIn_,HANDLE_FLAG_INHERIT,0);
        std::wstring command;for(const auto& a:args){if(!command.empty())command+=L' ';command+=quoteArg(wide(a));}
        HANDLE nullError=CreateFileW(L"NUL",GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,&sa,OPEN_EXISTING,0,nullptr);
        STARTUPINFOW si{};si.cb=sizeof(si);si.dwFlags=STARTF_USESTDHANDLES;si.hStdInput=readIn;si.hStdOutput=writeOut;si.hStdError=nullError;
        PROCESS_INFORMATION pi{};
        BOOL ok=CreateProcessW(nullptr,command.data(),nullptr,nullptr,TRUE,CREATE_NO_WINDOW,nullptr,nullptr,&si,&pi);
        CloseHandle(readIn);CloseHandle(writeOut);if(nullError!=INVALID_HANDLE_VALUE)CloseHandle(nullError);
        if(!ok){stop();return false;}process_=pi.hProcess;CloseHandle(pi.hThread);return true;
#else
        int in[2],out[2]; if(pipe(in)!=0)return false;if(pipe(out)!=0){close(in[0]);close(in[1]);return false;}
        std::vector<char*> argv;for(const auto& a:args)argv.push_back(const_cast<char*>(a.c_str()));argv.push_back(nullptr);
        pid_=fork();
        if(pid_==0){setpgid(0,0);dup2(in[0],STDIN_FILENO);dup2(out[1],STDOUT_FILENO);int err=open("/dev/null",O_WRONLY);if(err>=0)dup2(err,STDERR_FILENO);close(in[0]);close(in[1]);close(out[0]);close(out[1]);execvp(argv[0],argv.data());_exit(127);}
        close(in[0]);close(out[1]);
        if(pid_<0){close(in[1]);close(out[0]);pid_=0;return false;}
        writeIn_=in[1];readOut_=out[0];fcntl(readOut_,F_SETFL,O_NONBLOCK);return true;
#endif
    }
    bool write(const std::string& bytes) {
#ifdef _WIN32
        if(!writeIn_){return false;}DWORD n=0;return WriteFile(writeIn_,bytes.data(),(DWORD)bytes.size(),&n,nullptr)&&n==bytes.size();
#else
        if(writeIn_<0){return false;}
        sigset_t mask,old,pending;sigemptyset(&mask);sigaddset(&mask,SIGPIPE);pthread_sigmask(SIG_BLOCK,&mask,&old);sigpending(&pending);bool already=sigismember(&pending,SIGPIPE);bool ok=true;
        size_t at=0;while(at<bytes.size()){auto n=::write(writeIn_,bytes.data()+at,bytes.size()-at);if(n<0&&errno==EINTR)continue;if(n<=0){ok=false;break;}at+=(size_t)n;}
        sigpending(&pending);if(!already&&sigismember(&pending,SIGPIPE)){int signal=0;sigwait(&mask,&signal);}pthread_sigmask(SIG_SETMASK,&old,nullptr);return ok;
#endif
    }
    void closeInput(){
#ifdef _WIN32
        if(writeIn_){CloseHandle(writeIn_);writeIn_=nullptr;}
#else
        if(writeIn_>=0){close(writeIn_);writeIn_=-1;}
#endif
    }
    std::string readFor(double seconds,const std::atomic<bool>& cancelled,bool stopAtLine=false) {
        std::string result; auto end=std::chrono::steady_clock::now()+std::chrono::milliseconds((int)(seconds*1000));
        while(!cancelled && std::chrono::steady_clock::now()<end && result.size()<8*1024*1024) {
            char bytes[16384]; int count=0;bool ended=false;
#ifdef _WIN32
            DWORD ready=0,n=0;
            if(!readOut_||!PeekNamedPipe(readOut_,nullptr,0,nullptr,&ready,nullptr)){ended=true;}
            else if(ready&&ReadFile(readOut_,bytes,(DWORD)std::min<size_t>(sizeof(bytes),ready),&n,nullptr))count=(int)n;
            else if(process_&&WaitForSingleObject(process_,0)==WAIT_OBJECT_0)ended=true;
#else
            auto n=::read(readOut_,bytes,sizeof(bytes));if(n>0)count=(int)n;else if(n==0)ended=true;
#endif
            if(count>0){result.append(bytes,(size_t)count);if(stopAtLine&&result.find('\n')!=std::string::npos)break;}
            else if(ended)break;else std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        return result;
    }
    void stop(){closeInput();
#ifdef _WIN32
        if(process_){if(WaitForSingleObject(process_,0)==WAIT_TIMEOUT)TerminateProcess(process_,0);CloseHandle(process_);process_=nullptr;}
        if(readOut_){CloseHandle(readOut_);readOut_=nullptr;}
#else
        if(pid_>0){int status=0;if(waitpid(pid_,&status,WNOHANG)==0){kill(pid_,SIGTERM);for(int i=0;i<15&&waitpid(pid_,&status,WNOHANG)==0;++i)std::this_thread::sleep_for(std::chrono::milliseconds(10));if(waitpid(pid_,&status,WNOHANG)==0){kill(pid_,SIGKILL);waitpid(pid_,&status,0);}}pid_=0;}
        if(readOut_>=0){close(readOut_);readOut_=-1;}
#endif
    }
private:
#ifdef _WIN32
    HANDLE process_=nullptr,readOut_=nullptr,writeIn_=nullptr;
#else
    pid_t pid_=0; int readOut_=-1,writeIn_=-1;
#endif
};
}
