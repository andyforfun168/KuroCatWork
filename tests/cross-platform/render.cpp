#include <algorithm>
using std::min;
using std::max;
#include <string>
#include <iostream>
#ifdef _WIN32
#include "../../windows/src/CatRenderer.hpp"
#else
#include "../../linux/src/CatRenderer.hpp"
#endif
#include "../../shared/work/WorkPanel.hpp"
int main() {
#ifdef _WIN32
    Gdiplus::GdiplusStartupInput startup;
    ULONG_PTR token = 0;
    if (Gdiplus::GdiplusStartup(&token, &startup, nullptr) != Gdiplus::Ok) return 1;
    CLSID png{};
    UINT count=0, size=0;
    Gdiplus::GetImageEncodersSize(&count,&size);
    std::vector<unsigned char> storage(size);
    auto encoders=reinterpret_cast<Gdiplus::ImageCodecInfo*>(storage.data());
    Gdiplus::GetImageEncoders(count,size,encoders);
    bool found=false;
    for (UINT i=0;i<count;++i) if (std::wstring(encoders[i].MimeType)==L"image/png") {png=encoders[i].Clsid;found=true;}
    if (!found) return 2;
#endif
    for(int coat=0;coat<4;++coat) for(int pose=0;pose<6;++pose) {
        CatPhysics p; CatSettings settings;
        settings.coatTheme=static_cast<CatCoatTheme>(coat);
        settings.eyeTheme=coat==3 ? EyeColorTheme::WarmAmber : coat==2 ? EyeColorTheme::ReferenceHazel : coat==1 ? EyeColorTheme::SiameseBlue : EyeColorTheme::NeonChartreuse;
        settings.keyboardMarquee=false;
        p.time=2;
        if(pose==1) p.headYaw.value=p.headYaw.target=-0.65f;
        if(pose==2) p.headPitch.value=p.headPitch.target=-0.60f;
        if(pose==3) {p.lieIntensity.value=p.lieIntensity.target=1;p.sleepiness=1;}
        if(pose==4 || pose==5) {p.setDragging(true);p.scruffDrag.value=p.scruffDrag.target=1;p.scruffHoldTime=2;}
        if(pose==5) p.scruffDizzyIntensity.value=p.scruffDizzyIntensity.target=1.f;
        std::string name="cat-"+std::to_string(coat)+"-pose-"+std::to_string(pose)+".png";
#ifdef _WIN32
        Gdiplus::Bitmap bitmap(720,640,PixelFormat32bppPARGB);
        { Gdiplus::Graphics g(&bitmap); g.Clear(Gdiplus::Color(255,81,101,111)); g.ScaleTransform(2,2);
          CatRenderer::draw(g,p,settings,builtInSkin(settings.coatTheme)); }
        std::wstring wide(name.begin(),name.end());
        if(bitmap.Save(wide.c_str(),&png,nullptr)!=Gdiplus::Ok) return 3;
#else
        auto surface=cairo_image_surface_create(CAIRO_FORMAT_ARGB32,720,640);
        auto cr=cairo_create(surface);cairo_set_source_rgb(cr,81./255,101./255,111./255);cairo_paint(cr);cairo_scale(cr,2,2);
        CatRenderer::draw(cr,p,settings,builtInSkin(settings.coatTheme),KeyboardSkinSpec::builtInTheme(0));
        if(cairo_surface_write_to_png(surface,name.c_str())!=CAIRO_STATUS_SUCCESS) return 3;
        cairo_destroy(cr);cairo_surface_destroy(surface);
#endif
    }
    {
      kurowork::Model model;double now=kurowork::wallNow();model.enter(now);model.options.selection=kurowork::Selection::Both;
      for(auto tool:{kurowork::Tool::Codex,kurowork::Tool::Claude}){kurowork::Quota quota;quota.stale=false;quota.week=kurowork::Window{23,now+4*86400};quota.session=kurowork::Window{32,now+7200};model.quotas[tool]=quota;}
      for(int i=0;i<3;++i){kurowork::Task task;task.key=std::to_string(i);task.title=i==0?"Update project":i==1?"Review changes":"Run checks";task.state=i==0?kurowork::State::Awaiting:i==1?kurowork::State::Running:kurowork::State::Failed;task.startedAt=now-90;task.changedAt=now;model.tasks[task.key]=task;}
      kurowork::PanelScene panel;panel.angle=.055f;panel.layout(model);
#ifdef _WIN32
      Gdiplus::Bitmap bitmap(720,1080,PixelFormat32bppPARGB);{Gdiplus::Graphics g(&bitmap);g.Clear(Gdiplus::Color(255,81,101,111));g.ScaleTransform(2,2);CatPhysics p;CatSettings settings;settings.coatTheme=CatCoatTheme::OrangeWhite;settings.eyeTheme=EyeColorTheme::WarmAmber;CatRenderer::draw(g,p,settings,builtInSkin(settings.coatTheme));g.TranslateTransform(103-panel.offsetX,306-panel.offsetY);kurowork::Canvas c(g);panel.draw(c,model,now,true);}if(bitmap.Save(L"work-mode.png",&png,nullptr)!=Gdiplus::Ok)return 4;
#else
      auto surface=cairo_image_surface_create(CAIRO_FORMAT_ARGB32,720,1080);auto cr=cairo_create(surface);cairo_set_source_rgb(cr,81./255,101./255,111./255);cairo_paint(cr);cairo_scale(cr,2,2);CatPhysics p;CatSettings settings;settings.coatTheme=CatCoatTheme::OrangeWhite;settings.eyeTheme=EyeColorTheme::WarmAmber;CatRenderer::draw(cr,p,settings,builtInSkin(settings.coatTheme),KeyboardSkinSpec::builtInTheme(0));cairo_translate(cr,103-panel.offsetX,306-panel.offsetY);kurowork::Canvas c(cr);panel.draw(c,model,now,true);if(cairo_surface_write_to_png(surface,"work-mode.png")!=CAIRO_STATUS_SUCCESS)return 4;cairo_destroy(cr);cairo_surface_destroy(surface);
#endif
    }
#ifdef _WIN32
    CatRenderer::cleanupGdiplusCaches();
    Gdiplus::GdiplusShutdown(token);
#endif
    std::cout << "Rendered 24 native cat pose snapshots\n";
}
