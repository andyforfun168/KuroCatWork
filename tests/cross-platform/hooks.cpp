#include "../../shared/work/WorkHooks.hpp"
#include <cassert>
int main(int argc,char** argv){using namespace kurowork;assert(argc==2);auto root=fs::u8path(argv[1]);fs::create_directories(root);std::string id="12345678-1234-1234-1234-123456789012";
 auto event=[&](const char* name,double time,const char* turn="a"){handleEvent("{\"session_id\":\""+id+"\",\"turn_id\":\""+turn+"\",\"hook_event_name\":\""+name+"\"}",Tool::Codex,root,time);};
 auto file=root/("codex-"+id+".json");
 event("UserPromptSubmit",10);event("PermissionRequest",20);auto value=parse(readFile(file));assert(str(field(value,"state"))=="awaiting"&&num(field(value,"started"))==10);
 event("PostToolUse",30);assert(str(field(parse(readFile(file)),"state"))=="running");event("Stop",40);event("SessionEnd",41);assert(str(field(parse(readFile(file)),"state"))=="completed");
 event("UserPromptSubmit",50,"b");event("Interrupt",60,"b");value=parse(readFile(file));assert(str(field(value,"turn"))=="b"&&num(field(value,"started"))==50&&str(field(value,"state"))=="cancelled");
 auto original=readFile(file);handleEvent("{\"session_id\":\"../invalid\",\"hook_event_name\":\"Stop\"}",Tool::Codex,root,70);assert(readFile(file)==original);
 assert(encode(parse("{\"key\":[1,true,\"quote\\\"\"]}"))=="{\"key\":[1.000000,true,\"quote\\\"\"]}");
 std::cout<<"Native task hook lifecycle and validation passed\n";
}
