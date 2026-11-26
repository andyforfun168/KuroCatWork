#pragma once
#include "AcceptedPickup.hpp"
#include "../SkinSpec.hpp"
#ifdef _WIN32
#include <gdiplus.h>
#else
#include <cairo.h>
#endif
namespace kurowork {
#ifdef _WIN32
using NativeGraphics=Gdiplus::Graphics;
#else
using NativeGraphics=cairo_t;
#endif
class Canvas {
public:
#ifdef _WIN32
    explicit Canvas(NativeGraphics& graphics):g(graphics){}
    NativeGraphics& g;std::vector<Gdiplus::GraphicsState> states;
    static Gdiplus::Color color(SkinColor c){return Gdiplus::Color((BYTE)(std::clamp(c.a,0.,1.)*255),(BYTE)(std::clamp(c.r,0.,1.)*255),(BYTE)(std::clamp(c.g,0.,1.)*255),(BYTE)(std::clamp(c.b,0.,1.)*255));}
    static void native(const Path& p,Gdiplus::GraphicsPath& out){Point last{};for(const auto& s:p.segments){switch(s.kind){
        case 0:out.StartFigure();last=s.a;break;
        case 1:out.AddLine(last.x,last.y,s.a.x,s.a.y);last=s.a;break;
        case 2:out.AddBezier(last.x,last.y,s.a.x,s.a.y,s.b.x,s.b.y,s.c.x,s.c.y);last=s.c;break;
        case 3:out.CloseFigure();break;
    }}}
#else
    explicit Canvas(NativeGraphics* graphics):g(graphics){}
    NativeGraphics* g;
#endif
    void save(){
#ifdef _WIN32
        states.push_back(g.Save());
#else
        cairo_save(g);
#endif
    }
    void restore(){
#ifdef _WIN32
        g.Restore(states.back());states.pop_back();
#else
        cairo_restore(g);
#endif
    }
    void translate(float x,float y){
#ifdef _WIN32
        g.TranslateTransform(x,y);
#else
        cairo_translate(g,x,y);
#endif
    }
    void rotate(float radians){
#ifdef _WIN32
        g.RotateTransform(radians*180.f/3.141592653589793f);
#else
        cairo_rotate(g,radians);
#endif
    }
    void scale(float x,float y){
#ifdef _WIN32
        g.ScaleTransform(x,y);
#else
        cairo_scale(g,x,y);
#endif
    }
    void path(const Path& p){
#ifndef _WIN32
        cairo_new_path(g);for(const auto& s:p.segments){switch(s.kind){
        case 0:cairo_move_to(g,s.a.x,s.a.y);break;
        case 1:cairo_line_to(g,s.a.x,s.a.y);break;
        case 2:cairo_curve_to(g,s.a.x,s.a.y,s.b.x,s.b.y,s.c.x,s.c.y);break;
        case 3:cairo_close_path(g);break;
    }}
#endif
    }
    void fill(const Path& p,SkinColor c){
#ifdef _WIN32
        Gdiplus::GraphicsPath n;native(p,n);Gdiplus::SolidBrush brush(color(c));g.FillPath(&brush,&n);
#else
        path(p);cairo_set_source_rgba(g,c.r,c.g,c.b,c.a);cairo_fill(g);
#endif
    }
    void stroke(const Path& p,SkinColor c,float width){
#ifdef _WIN32
        Gdiplus::GraphicsPath n;native(p,n);Gdiplus::Pen pen(color(c),width);pen.SetStartCap(Gdiplus::LineCapRound);pen.SetEndCap(Gdiplus::LineCapRound);pen.SetLineJoin(Gdiplus::LineJoinRound);g.DrawPath(&pen,&n);
#else
        path(p);cairo_set_source_rgba(g,c.r,c.g,c.b,c.a);cairo_set_line_width(g,width);cairo_set_line_cap(g,CAIRO_LINE_CAP_ROUND);cairo_set_line_join(g,CAIRO_LINE_JOIN_ROUND);cairo_stroke(g);
#endif
    }
    void gradient(const Path& p,Point start,Point end,const std::vector<SkinColor>& colors,const std::vector<float>& stops){
#ifdef _WIN32
        Gdiplus::GraphicsPath n;native(p,n);Gdiplus::LinearGradientBrush brush(Gdiplus::PointF(start.x,start.y),Gdiplus::PointF(end.x,end.y),color(colors.front()),color(colors.back()));
        brush.SetWrapMode(Gdiplus::WrapModeTileFlipXY);std::vector<Gdiplus::Color> cs;for(auto col:colors)cs.push_back(color(col));brush.SetInterpolationColors(cs.data(),stops.data(),(INT)cs.size());g.FillPath(&brush,&n);
#else
        path(p);auto pat=cairo_pattern_create_linear(start.x,start.y,end.x,end.y);for(size_t i=0;i<colors.size();++i){auto c=colors[i];cairo_pattern_add_color_stop_rgba(pat,stops[i],c.r,c.g,c.b,c.a);}cairo_pattern_set_extend(pat,CAIRO_EXTEND_PAD);cairo_set_source(g,pat);cairo_fill(g);cairo_pattern_destroy(pat);
#endif
    }
    void radial(Point center,float radius,const std::vector<SkinColor>& colors,const std::vector<float>& stops){
#ifdef _WIN32
        Gdiplus::GraphicsPath circle;circle.AddEllipse(center.x-radius,center.y-radius,radius*2,radius*2);
        Gdiplus::PathGradientBrush brush(&circle);brush.SetCenterPoint(Gdiplus::PointF(center.x,center.y));
        std::vector<Gdiplus::Color> cs;std::vector<float> reversed;
        for(size_t i=colors.size();i>0;--i){cs.push_back(color(colors[i-1]));reversed.push_back(1-stops[i-1]);}
        brush.SetInterpolationColors(cs.data(),reversed.data(),(INT)cs.size());g.FillPath(&brush,&circle);
#else
        auto pat=cairo_pattern_create_radial(center.x,center.y,0,center.x,center.y,radius);
        for(size_t i=0;i<colors.size();++i){auto c=colors[i];cairo_pattern_add_color_stop_rgba(pat,stops[i],c.r,c.g,c.b,c.a);}cairo_set_source(g,pat);cairo_paint(g);cairo_pattern_destroy(pat);
#endif
    }
    void clip(const Path& p){
#ifdef _WIN32
        Gdiplus::GraphicsPath n;native(p,n);g.SetClip(&n,Gdiplus::CombineModeIntersect);
#else
        path(p);cairo_clip(g);
#endif
    }
};
}
