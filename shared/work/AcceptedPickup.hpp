#pragma once
#include <algorithm>
#include <cmath>
#include <vector>
namespace kurowork {
struct Point {float x=0,y=0;};
inline Point mix(Point a,Point b,float t){return {a.x+(b.x-a.x)*t,a.y+(b.y-a.y)*t};}
inline float mix(float a,float b,float t){return a+(b-a)*t;}
inline Point rotate(Point p,Point pivot,float a){float x=p.x-pivot.x,y=p.y-pivot.y;return {pivot.x+x*std::cos(a)-y*std::sin(a),pivot.y+x*std::sin(a)+y*std::cos(a)};}
struct Segment {int kind;Point a,b,c;};
struct Path {
    std::vector<Segment> segments;Point current;
    void move(Point p){segments.push_back({0,p,{},{}});current=p;}
    void line(Point p){segments.push_back({1,p,{},{}});current=p;}
    void curve(Point a,Point b,Point p){segments.push_back({2,a,b,p});current=p;}
    void quad(Point control,Point p){curve(mix(current,control,2.f/3),mix(p,control,2.f/3),p);}
    void close(){segments.push_back({3,{},{},{}});}
};
struct PickupLimb {Point root,tip;float startW,endW,bend;};
inline Path limbPath(const PickupLimb& l,bool closed=true){
    float dx=l.tip.x-l.root.x,dy=l.tip.y-l.root.y,len=std::max(1.f,std::hypot(dx,dy));
    float ux=dx/len,uy=dy/len,nx=-uy,ny=ux,r0=l.startW/2,r1=l.endW/2;
    Point a{l.root.x+nx*r0,l.root.y+ny*r0},b{l.root.x-nx*r0,l.root.y-ny*r0};
    Point c{l.tip.x+nx*r1,l.tip.y+ny*r1},d{l.tip.x-nx*r1,l.tip.y-ny*r1};
    Path p;p.move(a);p.quad({(a.x+c.x)/2+l.bend/2+nx*1.4f,(a.y+c.y)/2+ny*1.4f},c);
    p.curve({c.x+ux*r1*1.25f,c.y+uy*r1*1.25f},{d.x+ux*r1*1.25f,d.y+uy*r1*1.25f},d);
    p.quad({(b.x+d.x)/2+l.bend/2-nx*1.4f,(b.y+d.y)/2-ny*1.4f},b);
    if(closed){p.curve({b.x-ux*r0*.85f,b.y-uy*r0*.85f},{a.x-ux*r0*.85f,a.y-uy*r0*.85f},a);p.close();}return p;
}
inline Path limbInk(const PickupLimb& l){
    float dx=l.tip.x-l.root.x,dy=l.tip.y-l.root.y,len=std::max(1.f,std::hypot(dx,dy)),ux=dx/len,uy=dy/len,nx=-uy,ny=ux,r0=l.startW/2,r1=l.endW/2;
    Point a{l.root.x+nx*r0,l.root.y+ny*r0},b{l.root.x-nx*r0,l.root.y-ny*r0},c{l.tip.x+nx*r1,l.tip.y+ny*r1},d{l.tip.x-nx*r1,l.tip.y-ny*r1};
    Point ml{(a.x+c.x)/2+l.bend/2+nx*1.4f,(a.y+c.y)/2+ny*1.4f},mr{(b.x+d.x)/2+l.bend/2-nx*1.4f,(b.y+d.y)/2-ny*1.4f};
    auto bez=[](Point a,Point b,Point c){return mix(mix(a,b,.26f),mix(b,c,.26f),.26f);};
    Path p;p.move(bez(a,ml,c));p.quad(mix(ml,c,.26f),c);p.curve({c.x+ux*r1*1.25f,c.y+uy*r1*1.25f},{d.x+ux*r1*1.25f,d.y+uy*r1*1.25f},d);p.quad(mix(mr,d,.26f),bez(b,mr,d));
    for(float side:{-1.f,1.f}){p.move({l.tip.x+nx*side*2.5f+ux*1.6f,l.tip.y+ny*side*2.5f+uy*1.6f});p.line({l.tip.x+nx*side*2.5f+ux*l.endW*.44f,l.tip.y+ny*side*2.5f+uy*l.endW*.44f});}return p;
}
// Geometry copied from the accepted macOS build 20261126.22, in its native 360x320 space.
// Rendering backends consume the same paths; platform input fixes cannot change these proportions.
struct Pickup {
    Point head,back,grip,rump,bellyR,bellyL,chest,tailRoot,tailC1,tailC2,tailTip;
    Path body,face,tail,underside;
    PickupLimb backLeft,backRight,frontLeft,frontRight;
    float pendulum=0,startle=0,shift=0,liftY=0;
    Pickup(float time,float lift,float start,float swingH,float swingY,float tailSwing,float bodyShift,float hs,float bw,float cheekWidth,float cheekFullness,float crownBase,float crownWidth,float cheekY,float cheekTop,float tailLength){
        startle=start;swingH=std::clamp(swingH,-.95f,.95f);swingY=std::clamp(swingY,-.80f,.80f);
        lift=std::clamp(lift,0.f,1.f);lift=lift*lift*(3-2*lift);
        float idle=std::sin(time*4.2f)*.045f*(1-start),limbSwing=std::clamp(swingH*.85f,-.82f,.82f)*(1-start*.45f)+idle,up=std::max(0.f,-swingY);
        shift=bodyShift-swingH*11;liftY=-lift*12+swingY*7.5f+std::sin(time*3.8f)*2*(1-start);
        head={146+shift,mix(136.f,158.f,start)+liftY};back={202+shift,mix(146.f,172.f,start)+liftY};
        grip={188+shift,mix(88.f,124.f,start)+liftY};rump={246+shift+(bw-1)*12,mix(150.f,186.f,start)+liftY};
        bellyR={212+shift,mix(188.f,212.f,start)+liftY};bellyL={136+shift,mix(182.f,206.f,start)+liftY};chest={116+shift,mix(164.f,188.f,start)+liftY};
        float half=cheekWidth*cheekFullness*hs,crown=crownBase*hs,chin=33*hs;
        Point neck{head.x-half*.64f,head.y+8*hs},neckStart{head.x-10,head.y-16*hs};
        body.move(neckStart);body.curve({neckStart.x,grip.y+15*hs},{grip.x-27,grip.y+6},{grip.x-5,grip.y+.8f});
        body.curve({grip.x-3,grip.y+.25f},{grip.x-1.5f,grip.y},grip);
        body.curve({grip.x+1.5f,grip.y},{grip.x+3,grip.y+.3f},{grip.x+5,grip.y+1});
        body.curve({grip.x+31,grip.y+8},{rump.x+4,mix(108.f,148.f,start)+liftY},rump);
        body.curve({rump.x-2,mix(178.f,210.f,start)+liftY},{bellyR.x+22,bellyR.y},bellyR);
        body.curve({182+shift,mix(190.f,214.f,start)+liftY},{154+shift,mix(188.f,212.f,start)+liftY},bellyL);
        body.curve({122+shift,mix(180.f,204.f,start)+liftY},{114+shift,mix(174.f,198.f,start)+liftY},chest);
        body.curve({116+shift,mix(156.f,178.f,start)+liftY},{neck.x-2,neck.y+10},neck);body.close();
        face.move({head.x,head.y+crown});
        face.curve({head.x+crownWidth*hs,head.y+crown},{head.x+half+1.5f*hs,head.y+cheekTop*hs},{head.x+half,head.y+cheekY*hs});
        face.curve({head.x+half*.96f,head.y+chin*.86f},{head.x+half*.56f,head.y+chin},{head.x,head.y+chin});
        face.curve({head.x-half*.56f,head.y+chin},{head.x-half*.96f,head.y+chin*.86f},{head.x-half,head.y+cheekY*hs});
        face.curve({head.x-half-1.5f*hs,head.y+cheekTop*hs},{head.x-crownWidth*hs,head.y+crown},{head.x,head.y+crown});face.close();
        tailRoot={rump.x-10,mix(148.f,180.f,start)+liftY};float length=86*tailLength*(1+swingY*.15f);
        float angle=std::clamp((tailSwing*(1-start*.25f)+idle*1.4f)*.88f,-1.12f,.56f);
        tailC1=rotate({tailRoot.x+20+up*10,tailRoot.y+length*.22f-up*12},tailRoot,angle*.45f);
        tailC2=rotate({tailRoot.x+23+up*22,tailRoot.y+length*.66f-up*34},tailRoot,angle*.90f);
        tailTip=rotate({tailRoot.x+16+up*26,tailRoot.y+length-up*52},tailRoot,angle*1.24f);
        tail.move(tailRoot);tail.curve(tailC1,tailC2,tailTip);
        auto limb=[&](Point ra,Point ta,Point rb,Point tb,float w0,float w1,float bend,float swing,float splay){
            Point r=mix(ra,rb,start),t=mix(ta,tb,start);t={r.x+(t.x-r.x)*(1+swingY*.17f),r.y+(t.y-r.y)*(1+swingY*.17f)-up*7};
            return PickupLimb{r,rotate(t,r,limbSwing*swing+up*.24f*splay),w0,w1,bend+limbSwing*14*swing};};
        auto pt=[&](float x,float y){return Point{x+shift,y+liftY};};
        backLeft=limb(pt(196,170),pt(192,208),pt(174,194),pt(164,222),15.5f,12.5f,-2,.66f,-.25f);
        backRight=limb(pt(220,162),pt(218,212),pt(226,186),pt(238,224),20.5f,15.5f,4,.78f,1);
        frontLeft=limb(pt(132,162),pt(132,214),pt(129,184),pt(129,222),20,15.5f,-3.5f,.72f,-1);
        frontRight=limb(pt(165,165),pt(165,220),pt(174,188),pt(174,224),20.5f,16,3,.76f,.35f);
        float edge=std::min({frontLeft.root.y,frontRight.root.y,backLeft.root.y,backRight.root.y})-17;
        underside.move({chest.x-6,edge-10});underside.curve({head.x+4,edge-2},{back.x-20,edge+1},{back.x+2,edge});
        underside.curve({rump.x-13,edge},{rump.x-3,edge-4},{rump.x+6,edge-22});
        underside.line({rump.x+12,bellyR.y+30});underside.line({chest.x-20,bellyL.y+30});underside.close();
        pendulum=std::clamp(swingH*.14f,-.14f,.14f);
    }
};
}
namespace kurowork {
struct Attachment {Point origin;float angle;};
template<class P>inline Pickup pickupFor(const P& p,bool dragging){float start=dragging?(p.scruffHoldTime<.14f?1.f:std::max(0.f,1.f-(p.scruffHoldTime-.14f)/.08f)):(p.scruffDropTimer>.01f?std::min(1.f,p.scruffDropTimer/.12f):1.f);return Pickup(p.time,p.scruffDrag.value,start,p.scruffSwing.value,p.scruffSwingY.value,p.scruffTailSwing.value,p.bodyShiftX.value,1,1,42.5f,1,-30,26,5,-14,1);}
inline Point canvasTransform(Point p,bool flipped,float rotation){if(flipped)p.x=360-p.x;float rad=rotation*3.14159265f/180;float fit=1-std::abs(std::sin(rad))*.14f;p={(p.x-180)*fit+180,(p.y-160)*fit+160};return rotate(p,{180,160},rad);}
template<class P>inline Point cursorGrip(const P& p,bool dragging,bool flipped,float rotation){return canvasTransform(pickupFor(p,dragging).grip,flipped,rotation);}
template<class P>inline Attachment panelAttachment(const P& p,bool dragging,bool flipped,float rotation){
    Point source{103,306};float amount=std::clamp(p.scruffDrag.value/.90f,0.f,1.f);amount=amount*amount*(3-2*amount);
    auto pose=pickupFor(p,dragging);float hand=std::atan2(pose.frontRight.tip.y-pose.frontRight.root.y,pose.frontRight.tip.x-pose.frontRight.root.x)-1.57079632679f;
    auto worldGrip=rotate(pose.frontRight.tip,pose.grip,pose.pendulum);Point grip=mix(Point{184,242},worldGrip,amount);float angle=(-.36f+hand+pose.pendulum)*amount;
    auto offset=rotate(source,{184,242},angle);Point origin{grip.x+offset.x-184,grip.y+offset.y-242};origin=canvasTransform(origin,flipped,rotation);
    return {origin,(flipped?-(.055f+angle):.055f+angle)+rotation*3.14159265f/180};
}
}
