#include "../../shared/work/WorkSources.hpp"
#include <cassert>
#include <iostream>
int main(int argc,char** argv){using namespace kurowork;
 if(argc>1&&std::string(argv[1])=="app-server"){std::string line;while(std::getline(std::cin,line)){auto j=parse(line);auto method=str(field(j,"method"));if(method=="initialize")std::cout<<"{\"id\":1,\"result\":{}}"<<std::endl;else if(method=="account/rateLimits/read")std::cout<<"{\"id\":2,\"result\":{\"rateLimits\":{\"secondary\":{\"usedPercent\":33,\"windowDurationMins\":10080,\"resetsAt\":1800000000}}}}"<<std::endl;else if(method!="initialized")return 9;}return 0;}
 auto self=fs::absolute(fs::u8path(argv[0])).u8string();
#ifdef _WIN32
 _putenv_s("KUROCAT_CODEX_CLI",self.c_str());
#else
 setenv("KUROCAT_CODEX_CLI",self.c_str(),1);
#endif
 std::atomic<bool> rpcCancel{false};auto rpc=fetchCodex(rpcCancel);assert(!rpc.stale&&!rpc.session&&rpc.week&&rpc.week->remaining()==67);

 auto q=codexQuota(parse(R"({"rateLimits":{"secondary":{"usedPercent":33,"windowDurationMins":10080,"resetsAt":1800000000}}})"),1);
 assert(!q.stale&&!q.session&&q.week&&q.week->remaining()==67);
 auto c=claudeQuota(parse(R"({"five_hour":null,"seven_day":{"utilization":18,"resets_at":"2026-11-27T00:00:00Z"}})"),1);
 assert(!c.session&&c.week&&c.week->remaining()==82);
 assert(stamp(parse("\"1970-01-01T00:00:00Z\""))==0);
 assert(stamp(parse("\"1970-01-01T01:30:00+01:30\""))==0);
 std::atomic<bool> cancel{false};Process child;
#ifdef _WIN32
 assert(child.start({"cmd.exe","/c","echo","test"}));
#else
 assert(child.start({"/usr/bin/printf","test"}));
#endif
 auto output=child.readFor(2,cancel);assert(output.find("test")!=std::string::npos);
 std::cout<<"Quota parsing and native process tests passed\n";
}
