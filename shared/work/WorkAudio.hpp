#pragma once
#include "WorkSources.hpp"
#include <deque>
#ifdef _WIN32
#include <mmsystem.h>
#endif
namespace kurowork {
enum class Sound {Key,Pickup,Quota,Task};
class Audio {
public:
    Audio(){thread_=std::thread([this]{run();});}
    ~Audio(){{std::lock_guard<std::mutex> lock(mutex_);quit_=true;}condition_.notify_one();thread_.join();}
    void stop(){std::lock_guard<std::mutex> lock(mutex_);queue_.clear();generation_++;}
    void play(Sound kind,const Options& options,int axis=0){if(!options.sound||(kind!=Sound::Key&&kind!=Sound::Pickup&&!options.popSound))return;std::lock_guard<std::mutex> lock(mutex_);if(queue_.size()>4)queue_.pop_front();queue_.push_back({kind,kind==Sound::Key?options.keyboardVolume:kind==Sound::Pickup?options.meowVolume:options.popVolume,axis,generation_});condition_.notify_one();}
    static fs::path root(){
#ifdef _WIN32
        wchar_t path[32768];DWORD n=GetModuleFileNameW(nullptr,path,32768);return n>0?fs::path(std::wstring(path,n)).parent_path()/"Resources"/"WorkSounds":fs::path();
#else
        char path[4096];auto n=readlink("/proc/self/exe",path,sizeof(path)-1);if(n<=0)return {};path[n]=0;auto local=fs::path(path).parent_path()/"Resources"/"WorkSounds";std::error_code e;if(fs::exists(local,e))return local;return "/usr/share/kurocatwork/WorkSounds";
#endif
    }
private:
    struct Job{Sound kind;double volume;int axis;unsigned generation;};std::mutex mutex_;std::condition_variable condition_;std::thread thread_;std::deque<Job> queue_;bool quit_=false;unsigned generation_=0,index_=0;
    void run(){for(;;){Job job;{std::unique_lock<std::mutex> lock(mutex_);condition_.wait(lock,[this]{return quit_||!queue_.empty();});if(quit_)return;job=queue_.front();queue_.pop_front();if(job.generation!=generation_)continue;}
        auto base=root();fs::path file;
        if(job.kind==Sound::Key){const char* types[]={"blue","brown","red"};char key[32];std::snprintf(key,sizeof(key),"key-%02u.wav",index_++%12);file=base/types[std::clamp(job.axis,0,2)]/key;}
        else file=base/(job.kind==Sound::Pickup?"pickup-meow.wav":job.kind==Sound::Quota?"quota-pop.wav":"task-pop.wav");
        auto wav=readFile(file,1024*1024);if(wav.size()<44||wav.substr(0,4)!="RIFF"||wav.substr(8,4)!="WAVE")continue;
        auto u16=[&](size_t o){return (unsigned char)wav[o]|((unsigned char)wav[o+1]<<8);};auto u32=[&](size_t o){return (unsigned)u16(o)|((unsigned)u16(o+2)<<16);};unsigned channels=0,rate=0,bits=0;size_t at=12,data=0,length=0;
        while(at+8<=wav.size()){auto size=u32(at+4);if(size>wav.size()-at-8)break;if(wav.compare(at,4,"fmt ")==0&&size>=16&&u16(at+8)==1){channels=u16(at+10);rate=u32(at+12);bits=u16(at+22);}if(wav.compare(at,4,"data")==0){data=at+8;length=size;}at+=8+size+(size&1);}
        if(bits!=16||!channels||!rate||!data||length<2){continue;}
        std::string pcm=wav.substr(data,length);double volume=std::clamp(job.volume,0.,1.);for(size_t i=0;i+1<pcm.size();i+=2){int sample=(int16_t)((unsigned char)pcm[i]|((unsigned char)pcm[i+1]<<8));sample=(int)(sample*volume);pcm[i]=(char)sample;pcm[i+1]=(char)(sample>>8);}
#ifdef _WIN32
        WAVEFORMATEX format{};format.wFormatTag=WAVE_FORMAT_PCM;format.nChannels=(WORD)channels;format.nSamplesPerSec=rate;format.wBitsPerSample=16;format.nBlockAlign=(WORD)(channels*2);format.nAvgBytesPerSec=rate*format.nBlockAlign;HWAVEOUT device=nullptr;
        if(waveOutOpen(&device,WAVE_MAPPER,&format,0,0,CALLBACK_NULL)!=MMSYSERR_NOERROR){continue;}WAVEHDR header{};header.lpData=pcm.data();header.dwBufferLength=(DWORD)pcm.size();waveOutPrepareHeader(device,&header,sizeof(header));waveOutWrite(device,&header,sizeof(header));
        for(int n=0;n<200&&!(header.dwFlags&WHDR_DONE);++n){{std::lock_guard<std::mutex> lock(mutex_);if(quit_||job.generation!=generation_)break;}std::this_thread::sleep_for(std::chrono::milliseconds(10));}waveOutReset(device);waveOutUnprepareHeader(device,&header,sizeof(header));waveOutClose(device);
#else
        Process child;std::atomic<bool> cancel{false};if(child.start({"paplay","--raw","--format=s16le","--rate="+std::to_string(rate),"--channels="+std::to_string(channels)})){child.write(pcm);child.closeInput();child.readFor(2,cancel);}
#endif
    }}
};
}
