#pragma once
#include "WorkController.hpp"
#include "NativeCanvas.hpp"
#ifndef _WIN32
#include <pango/pangocairo.h>
#endif
namespace kurowork {
inline Path roundBox(float x,float y,float w,float h,float r){
    r=std::min({r,w/2,h/2});constexpr float k=.55228475f;Path p;p.move({x+r,y});p.line({x+w-r,y});p.curve({x+w-r+k*r,y},{x+w,y+r-k*r},{x+w,y+r});p.line({x+w,y+h-r});p.curve({x+w,y+h-r+k*r},{x+w-r+k*r,y+h},{x+w-r,y+h});p.line({x+r,y+h});p.curve({x+r-k*r,y+h},{x,y+h-r+k*r},{x,y+h-r});p.line({x,y+r});p.curve({x,y+r-k*r},{x+r-k*r,y},{x+r,y});p.close();return p;
}
inline SkinColor tint(Tool tool){return tool==Tool::Codex?SkinColor::rgba(.22,.56,.91):SkinColor::rgba(.91,.50,.25);}
inline SkinColor tint(State state){switch(state){case State::Running:return SkinColor::rgba(.72,.53,.09);case State::Awaiting:return SkinColor::rgba(.58,.35,.80);case State::Completed:return SkinColor::rgba(.20,.61,.40);default:return SkinColor::rgba(.84,.26,.31);}}
inline const char* stateName(State state,bool en){switch(state){case State::Running:return en?"Running":"运行中";case State::Awaiting:return en?"Waiting for you":"等待处理";case State::Completed:return en?"Completed":"已完成";case State::Failed:return en?"Failed":"失败";default:return en?"Terminated":"已终止";}}
inline std::string duration(double seconds){int s=(int)std::max(0.,seconds);if(s>=86400)return std::to_string(s/86400)+"d "+std::to_string(s/3600%24)+"h";if(s>=3600)return std::to_string(s/3600)+"h "+std::to_string(s/60%60)+"m";return std::to_string(s/60)+"m "+std::to_string(s%60)+"s";}
inline void text(Canvas& c,const std::string& value,float x,float y,float size,SkinColor ink,float width=300,bool bold=false){
#ifdef _WIN32
    auto w=wide(value);Gdiplus::FontFamily family(L"Microsoft YaHei");Gdiplus::Font font(&family,size,bold?Gdiplus::FontStyleBold:Gdiplus::FontStyleRegular,Gdiplus::UnitPixel);Gdiplus::SolidBrush brush(Canvas::color(ink));Gdiplus::StringFormat format;format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);format.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap);c.g.DrawString(w.c_str(),(INT)w.size(),&font,Gdiplus::RectF(x,y,width,size*1.7f),&format,&brush);
#else
    auto layout=pango_cairo_create_layout(c.g);pango_layout_set_text(layout,value.c_str(),(int)value.size());auto font=pango_font_description_new();pango_font_description_set_family(font,"sans-serif");pango_font_description_set_absolute_size(font,size*PANGO_SCALE);pango_font_description_set_weight(font,bold?PANGO_WEIGHT_BOLD:PANGO_WEIGHT_NORMAL);pango_layout_set_font_description(layout,font);pango_layout_set_width(layout,(int)(width*PANGO_SCALE));pango_layout_set_ellipsize(layout,PANGO_ELLIPSIZE_END);pango_layout_set_single_paragraph_mode(layout,TRUE);cairo_set_source_rgba(c.g,ink.r,ink.g,ink.b,ink.a);cairo_move_to(c.g,x,y);pango_cairo_show_layout(c.g,layout);pango_font_description_free(font);g_object_unref(layout);
#endif
}
struct Hit {Rect rect;std::string key;std::optional<Tool> tool;};
class PanelScene {
public:
    std::vector<Birth> births;std::set<std::string> pending;bool dragging=false;double dragStarted=0;
    std::map<std::string,float> hoverAmounts;
    std::vector<Hit> hits;bool expanded=false;std::string hover;int scrollRows=0;float offsetX=100,offsetY=120,viewWidth=230,viewHeight=100;
    float height=55;float angle=.055f;
    std::vector<Task> displayTasks(const Model& model) const {auto rows=model.visible(expanded);if(expanded&&rows.size()>10){size_t start=std::min((size_t)std::max(0,scrollRows),rows.size()-10);return std::vector<Task>(rows.begin()+start,rows.begin()+start+10);}return rows;}
    void layout(const Model& model){float h=42+(float)displayTasks(model).size()*44+(!expanded&&model.visible(true).size()>3?25.f:0.f)+7;float minX=0,maxX=0,minY=births.empty()?0.f:-140.f,maxY=0;for(auto p:{Point{0,0},Point{190,0},Point{0,h},Point{190,h}}){auto r=rotate(p,Point{},angle);minX=std::min(minX,r.x);maxX=std::max(maxX,r.x);minY=std::min(minY,r.y);maxY=std::max(maxY,r.y);}offsetX=8-minX;offsetY=8-minY;viewWidth=maxX-minX+16;viewHeight=maxY-minY+16;}
    bool begin(Canvas& c,const std::string& key,float x,float y,float w,float h,double now,int row){
        c.save();if(pending.count(key)){c.restore();return false;}
        if(dragging){float age=(float)(now-dragStarted)-row*.035f;if(age<.5f&&age>0)c.translate(0,-std::sin(age*15)*std::exp(-age*7)*9);}
        for(const auto& birth:births)if(birth.key==key){float age=(float)(now-birth.started);auto color=tint(birth.tool);
            if(age<.18f){float yy=birth.y-std::sin(age/.18f*1.5708f)*18;auto glow=color;glow.a=.12;c.fill(roundBox(birth.x-16,yy-16,32,32,8),glow);c.fill(roundBox(birth.x-12,yy-12,24,24,6),color);c.restore();return false;}
            float t=std::clamp((age-.18f)/.36f,0.f,1.f);t=t*t*(3-2*t);float cx=birth.x+(x+w/2-birth.x)*t,cy=birth.y-18+(y+h/2-birth.y+18)*t;
            c.translate(cx,cy);c.scale((24+(w-24)*t)/w,(24+(h-24)*t)/h);c.translate(-x-w/2,-y-h/2);break;
        }return true;
    }
    void draw(Canvas& c,const Model& model,double now,bool en){
        hits.clear();c.save();c.translate(offsetX,offsetY);c.rotate(angle);
        std::vector<Tool> tools;for(auto t:{Tool::Codex,Tool::Claude})if(model.shows(t))tools.push_back(t);
        if(tools.empty()){text(c,en?"Select Codex / Claude in the menu":"右键选择 Codex / Claude",8,6,11,SkinColor::rgba(.35,.38,.42));}
        float w=tools.size()>1?91:190;
        for(size_t i=0;i<tools.size();++i){auto tool=tools[i];float x=i*(w+8);SkinColor col=tint(tool);if(!begin(c,tool==Tool::Codex?"quota:codex":"quota:claude",x,0,w,30,now,0))continue;auto box=roundBox(x,0,w,30,14);
            c.fill(roundBox(x,3,w,30,14),SkinColor::rgba(col.r*.55,col.g*.55,col.b*.55));c.fill(box,SkinColor::rgba(.99,.985,.97));
            auto found=model.quotas.find(tool);const Quota* q=found==model.quotas.end()?nullptr:&found->second;auto main=q?(q->session?q->session:q->week):std::optional<Window>{};
            if(main){c.save();c.clip(box);auto fill=roundBox(x,0,w*(float)(main->remaining()/100),30,0);auto color=col;color.a=q->stale?.12:.24;c.fill(fill,color);c.restore();}
            c.stroke(box,col,2.3f);
            if(q&&q->week){float remaining=q->week->resetsAt?(float)std::clamp((*q->week->resetsAt-now)/604800.,0.,1.):0;
                // Continuous seven-day track, white emptiness at the same width as filled track.
                auto track=roundBox(x,0,w,30,14);c.stroke(track,SkinColor::rgba(1,1,1),1.6f);
                // Build a continuous rounded perimeter using arc-length samples.
                Path ring;float radius=15,straight=w-30,arc=3.14159265f*radius,total=2*straight+2*arc;
                auto point=[&](float fraction){float d=fraction*total;if(d<straight)return Point{x+radius+d,0};d-=straight;if(d<arc){float a=-1.5707963f+d/radius;return Point{x+w-radius+radius*std::cos(a),15+radius*std::sin(a)};}d-=arc;if(d<straight)return Point{x+w-radius-d,30};d-=straight;float a=1.5707963f+d/radius;return Point{x+radius+radius*std::cos(a),15+radius*std::sin(a)};};
                if(remaining>0){ring.move(point(0));for(int j=1;j<=200;++j)ring.line(point(remaining*j/200));c.stroke(ring,col,1.6f);}
                for(int k=1;k<7;++k){auto a=point(k/7.f),b=point(k/7.f+.0001f);float dx=b.x-a.x,dy=b.y-a.y,len=std::max(.0001f,std::hypot(dx,dy));Path div;div.move({a.x-dy/len,a.y+dx/len});div.line({a.x+dy/len,a.y-dx/len});c.stroke(div,col,.65f);}
                if(q->session){auto strip=roundBox(x+12,23,w-24,3.2f,0);auto light=col;light.a=.18;c.fill(strip,light);c.fill(roundBox(x+12,23,(w-24)*(float)(q->week->remaining()/100),3.2f,0),col);}
            }
            std::string label=tool==Tool::Codex?"CODEX":"CLAUDE";if(!main)label+=" · N/A";text(c,label,x+12,6,10.5f,col,w-20,true);hits.push_back({{x,0,w,30},"",tool});c.restore();
        }
        auto tasks=displayTasks(model);float y=42;
        int row=1;for(const auto& t:tasks){if(!begin(c,t.key,0,y,190,36,now,row++)){y+=44;continue;}auto col=tint(t.state);auto box=roundBox(0,y,190,36,9);double opacity=1;auto fade=model.fading.find(t.key);if(fade!=model.fading.end())opacity=1-std::clamp((now-fade->second)/.8,0.,1.);auto color=col;color.a=opacity;
            c.fill(roundBox(0,y+3,190,36,9),SkinColor::rgba(col.r*.6,col.g*.6,col.b*.6,opacity));c.fill(box,SkinColor::rgba(.99,.985,.97,opacity));c.stroke(box,color,1.8f);
            text(c,t.title,10,y+3,11,SkinColor::rgba(.22,.25,.29,opacity),108,true);text(c,std::string(stateName(t.state,en))+" · "+duration((Model::busy(t.state)?now:t.changedAt)-t.startedAt),10,y+19,8.7f,color,110);
            if(!Model::busy(t.state)||t.state==State::Awaiting){float& hoverValue=hoverAmounts[t.key];hoverValue+=((hover==t.key?1.f:0.f)-hoverValue)*.22f;c.save();c.translate(154,y+17.5f);c.scale(1+hoverValue*.06f,1+hoverValue*.06f);c.translate(-154,-y-17.5f);auto button=roundBox(124,y+5,60,25,7);auto light=col;light.a=.10*opacity;c.fill(button,light);const char* title=t.state==State::Awaiting?(en?"Open chat":"打开处理"):t.state==State::Completed?(en?"View result":"查看结果"):(en?"Details":"查看详情");text(c,title,128,y+10,9,color,54,true);c.restore();}
            hits.push_back({{0,y,190,36},t.key,{}});c.restore();y+=44;
        }
        if(!expanded&&model.visible(true).size()>3){text(c,en?"More tasks…":"更多任务…",8,y,10,SkinColor::rgba(.4,.4,.45));hits.push_back({{0,y,190,24},"__more",{}});y+=25;}
        height=y+40;c.restore();
    }
    std::optional<Hit> hit(float x,float y){float px=x-offsetX,py=y-offsetY;float c=std::cos(-angle),s=std::sin(-angle);float xx=px*c-py*s,yy=px*s+py*c;for(const auto& h:hits)if(xx>=h.rect.x&&xx<=h.rect.x+h.rect.width&&yy>=h.rect.y&&yy<=h.rect.y+h.rect.height)return h;return {};}
    static std::string detail(const Hit& hit,const Model& model,bool en){
        if(hit.tool){auto found=model.quotas.find(*hit.tool);if(found==model.quotas.end())return en?"Not connected. Sign into the corresponding CLI.":"尚未连接，请先登录对应工具的 CLI。";const auto& q=found->second;std::string text=(*hit.tool==Tool::Codex?"Codex":"Claude")+std::string(en?" usage\n":" 额度\n");for(auto window:{std::make_pair("Session",q.session),std::make_pair("Week",q.week)}){if(!window.second)continue;text+=std::string(window.first)+": "+std::to_string((int)window.second->remaining())+"% left\n";if(window.second->resetsAt)text+=duration(*window.second->resetsAt-wallNow())+" until reset\n";}text+=q.message;return text;}
        auto t=model.tasks.find(hit.key);if(t==model.tasks.end())return {};return t->second.title+"\n"+stateName(t->second.state,en)+"\n"+t->second.project+"\n"+t->second.source;
    }
};
}
