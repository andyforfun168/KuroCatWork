#include "../../shared/work/WorkModel.hpp"
#include <cassert>
#include <iostream>
using namespace kurowork;
int main() {
    Model m;
    Task task; task.key="codex:session"; task.turn="turn1"; task.startedAt=10; task.changedAt=10;
    assert(!m.takeTaskPoll(0));
    m.enter(10);
    m.merge({task});
    assert(m.running() && m.typing(.016,false,false,false).active);
    assert(m.typing(.016,false,false,true).active); // Physical typing cannot interrupt autonomous work.
    assert(!m.typing(.016,true,false,true).active); // Dragging still pauses work.
    assert(!m.typing(.016,false,true,true).active); // Petting still pauses work.
    task.state=State::Awaiting; task.changedAt=20; m.merge({task});
    assert(m.waiting() && !m.typing(.016,false,false,false).active);
    assert(!m.angryWaiting(319) && m.angryWaiting(320));
    task.state=State::Completed; task.changedAt=330; m.merge({task});
    m.leave(331); m.tick(332); m.enter(333); m.merge({task});
    assert(m.visible().empty()); // Polling must not resurrect cleared completions.
    task.turn="turn2"; task.state=State::Running; task.startedAt=340; task.changedAt=340; m.merge({task});
    assert(m.visible().size()==1 && m.running());
    auto stale=task; stale.state=State::Failed; stale.changedAt=339; m.merge({stale});
    assert(m.running());
    task.state=State::Failed; task.changedAt=350; m.merge({task});
    m.leave(351); m.enter(352); assert(m.visible().size()==1); // Failures survive mode changes.
    m.tick(2153); assert(!m.enabled); // No active work for 30 minutes.
    m.enter(2200); assert(m.takeTaskPoll(2200)); assert(!m.takeTaskPoll(2201));
    assert(m.takeQuotaPoll(2200)); assert(!m.takeQuotaPoll(2259)); assert(m.takeQuotaPoll(2260));
    m.options.selection=Selection::Automatic;
    task.tool=Tool::Claude;task.key="claude:session";task.state=State::Running;task.changedAt=2300;
    m.merge({task}); assert(m.shows(Tool::Claude) && !m.shows(Tool::Codex));
    assert((Window{120,{}}.remaining()==0));
    auto card=placeHover({1860,1000,40,50},300,400,{0,0,1920,1080});
    assert(card.x==1552 && card.y==680 && card.x+card.width<=1920);
    card=placeHover({-1800,50,200,50},400,300,{-1920,0,1920,1080});
    assert(card.x>=-1920 && card.x+card.width<=0);
    std::cout << "Cross-platform work-state scenarios passed\n";
}
