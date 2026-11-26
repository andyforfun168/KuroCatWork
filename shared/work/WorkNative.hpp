#pragma once
#include "WorkPanel.hpp"
#ifdef _WIN32
#include <shellapi.h>
#include <commctrl.h>
#else
#include <gtk/gtk.h>
#endif
namespace kurowork {
inline bool allowedLink(const std::string& link){
    auto prefix=[](const std::string& s,const std::string& p){return s.compare(0,p.size(),p)==0;};
    if(prefix(link,"https://claude.ai/chat/")||prefix(link,"https://claude.ai/code/")){return link.find_first_of("\r\n") == std::string::npos;}
    const std::string base="codex://threads/";if(!prefix(link,base)||link.size()!=base.size()+36)return false;
    auto id=link.substr(base.size());for(size_t i=0;i<id.size();++i)if(i==8||i==13||i==18||i==23){if(id[i]!='-')return false;}else if(!std::isxdigit((unsigned char)id[i]))return false;return true;
}
class NativePanel {
public:
    Controller controller;PanelScene scene;Model paintedModel;bool english=false;float scale=1;
    NativePanel()=default;
    ~NativePanel(){controller.save();
#ifdef _WIN32
        if(hwnd_){DestroyWindow(hwnd_);}if(tip_)DestroyWindow(tip_);
#else
        if(window_){gtk_widget_destroy(window_);}
#endif
    }
    void toggle(){
        if(!controller.model.enabled && !controller.toolChosen){
#ifdef _WIN32
            auto owner=FindWindowW(L"KuroCatWorkOverlayWindowClass",nullptr);auto menu=CreatePopupMenu();AppendMenuW(menu,MF_STRING,1,L"Codex");AppendMenuW(menu,MF_STRING,2,L"Claude");AppendMenuW(menu,MF_STRING,3,english?L"Both":L"两者");AppendMenuW(menu,MF_STRING,4,english?L"Automatic":L"自动识别");POINT cursor{};GetCursorPos(&cursor);UINT choice=TrackPopupMenu(menu,TPM_RETURNCMD|TPM_NONOTIFY,cursor.x,cursor.y,0,owner,nullptr);DestroyMenu(menu);if(!choice)return;controller.model.options.selection=(Selection)(choice-1);
#else
            auto dialog=gtk_dialog_new_with_buttons(english?"Choose tools":"选择工具",nullptr,GTK_DIALOG_DESTROY_WITH_PARENT,"Codex",1,"Claude",2,english?"Both":"两者",3,english?"Automatic":"自动识别",4,nullptr);int choice=gtk_dialog_run(GTK_DIALOG(dialog));gtk_widget_destroy(dialog);if(choice<1||choice>4)return;controller.model.options.selection=(Selection)(choice-1);
#endif
        }
        controller.toolChosen=true;controller.toggle();
    }
    void action(const Hit& hit){if(hit.key=="__more"){scene.expanded=!scene.expanded;return;}if(hit.tool)return;
        auto found=controller.model.tasks.find(hit.key);if(found==controller.model.tasks.end())return;auto task=found->second;
        if(allowedLink(task.link)){
#ifdef _WIN32
            auto result=(INT_PTR)ShellExecuteW(nullptr,L"open",wide(task.link).c_str(),nullptr,nullptr,SW_SHOWNORMAL);
            if(result<=32){MessageBoxW(hwnd_,wide(task.source+"\n"+task.project+"\n"+task.title).c_str(),L"KuroCatWork",MB_OK);return;}
#else
            GError* error=nullptr;if(!gtk_show_uri_on_window(GTK_WINDOW(window_),task.link.c_str(),GDK_CURRENT_TIME,&error)){if(error)g_error_free(error);return;}
#endif
            if(!Model::busy(task.state)){controller.model.dismiss(task.key,wallNow());controller.save();}
        }else{
            // Local terminal sessions have no standard deep link. Show their actual source rather than opening a fabricated chat.
#ifdef _WIN32
            auto result=MessageBoxW(hwnd_,wide(task.source+"\n"+task.project+"\n"+task.title+(english?"\nReturn to the terminal to handle this task.\nMark this result as read?":"\n请返回对应终端处理。\n将此结果标为已读？")).c_str(),L"KuroCatWork",Model::busy(task.state)?MB_OK:MB_YESNO);
            if(!Model::busy(task.state)&&result==IDYES){controller.model.dismiss(task.key,wallNow());}
#else
            GtkWidget* dialog=gtk_message_dialog_new(GTK_WINDOW(window_),GTK_DIALOG_DESTROY_WITH_PARENT,GTK_MESSAGE_INFO,Model::busy(task.state)?GTK_BUTTONS_OK:GTK_BUTTONS_YES_NO,"%s",(task.source+"\n"+task.project+"\n"+task.title+(english?"\nReturn to the terminal to handle this task.\nMark this result as read?":"\n请返回对应终端处理。\n将此结果标为已读？")).c_str());int result=gtk_dialog_run(GTK_DIALOG(dialog));gtk_widget_destroy(dialog);if(!Model::busy(task.state)&&result==GTK_RESPONSE_YES)controller.model.dismiss(task.key,wallNow());
#endif
            controller.save();
        }
    }
    void show(int x,int y,float currentScale,bool visible,bool dragging,float swing=0){
        scale=std::max(.2f,currentScale);if(dragging&&!dragging_)scene.dragStarted=wallNow();scene.dragging=dragging;dragging_=dragging;scene.births=controller.births;scene.pending.clear();for(const auto& item:controller.birthQueue)scene.pending.insert(item.first);
        if((!controller.model.enabled&&controller.opacity<=.01f)||!visible){
#ifdef _WIN32
            if(hwnd_){ShowWindow(hwnd_,SW_HIDE);}
#else
            if(window_){gtk_widget_hide(window_);}
#endif
            return;
        }
        if(controller.model.enabled){paintedModel=controller.model;}
        scene.angle=swing;
        scene.layout(controller.model.enabled?controller.model:paintedModel);
        x+=(int)((100-scene.offsetX)*scale);y+=(int)((120-scene.offsetY)*scale);
        int w=(int)std::ceil(scene.viewWidth*scale),h=(int)std::ceil(scene.viewHeight*scale);h=std::max(h,(int)(70*scale));
#ifdef _WIN32
        if(!hwnd_){WNDCLASSEXW klass{};klass.cbSize=sizeof(klass);klass.hInstance=GetModuleHandleW(nullptr);klass.lpfnWndProc=proc;klass.lpszClassName=L"KuroCatWorkBars";klass.hCursor=LoadCursorW(nullptr,IDC_HAND);RegisterClassExW(&klass);hwnd_=CreateWindowExW(WS_EX_LAYERED|WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE|WS_EX_TOPMOST,klass.lpszClassName,L"KuroCatWork",WS_POPUP,x,y,w,h,nullptr,nullptr,klass.hInstance,this);}
        MONITORINFO monitor{sizeof(monitor)};POINT anchor{x,y};GetMonitorInfoW(MonitorFromPoint(anchor,MONITOR_DEFAULTTONEAREST),&monitor);
        x=std::clamp(x,(int)monitor.rcWork.left,std::max((int)monitor.rcWork.left,(int)monitor.rcWork.right-w));y=std::clamp(y,(int)monitor.rcWork.top,std::max((int)monitor.rcWork.top,(int)monitor.rcWork.bottom-h));
        SetWindowPos(hwnd_,HWND_TOPMOST,x,y,w,h,SWP_NOACTIVATE|SWP_SHOWWINDOW);
        HDC screen=GetDC(nullptr),dc=CreateCompatibleDC(screen);BITMAPINFO info{};info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);info.bmiHeader.biWidth=w;info.bmiHeader.biHeight=-h;info.bmiHeader.biPlanes=1;info.bmiHeader.biBitCount=32;info.bmiHeader.biCompression=BI_RGB;void* pixels=nullptr;HBITMAP bitmap=CreateDIBSection(screen,&info,DIB_RGB_COLORS,&pixels,nullptr,0);if(!bitmap){DeleteDC(dc);ReleaseDC(nullptr,screen);return;}auto old=SelectObject(dc,bitmap);
        {Gdiplus::Bitmap image(w,h,w*4,PixelFormat32bppPARGB,(BYTE*)pixels);Gdiplus::Graphics g(&image);g.Clear(Gdiplus::Color(0,0,0,0));g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);g.ScaleTransform(scale,scale);Canvas canvas(g);scene.draw(canvas,controller.model.enabled?controller.model:paintedModel,wallNow(),english);}
        POINT dest{x,y},source{};SIZE size{w,h};BLENDFUNCTION blend{AC_SRC_OVER,0,(BYTE)(255*std::clamp(controller.opacity,0.f,1.f)),AC_SRC_ALPHA};UpdateLayeredWindow(hwnd_,screen,&dest,&size,dc,&source,0,&blend,ULW_ALPHA);SelectObject(dc,old);DeleteObject(bitmap);DeleteDC(dc);ReleaseDC(nullptr,screen);
#else
        if(!window_){window_=gtk_window_new(GTK_WINDOW_TOPLEVEL);gtk_window_set_decorated(GTK_WINDOW(window_),FALSE);gtk_window_set_skip_taskbar_hint(GTK_WINDOW(window_),TRUE);gtk_window_set_skip_pager_hint(GTK_WINDOW(window_),TRUE);gtk_window_set_keep_above(GTK_WINDOW(window_),TRUE);gtk_window_set_accept_focus(GTK_WINDOW(window_),FALSE);gtk_window_stick(GTK_WINDOW(window_));gtk_widget_set_app_paintable(window_,TRUE);auto visual=gdk_screen_get_rgba_visual(gtk_widget_get_screen(window_));if(visual)gtk_widget_set_visual(window_,visual);gtk_widget_add_events(window_,GDK_BUTTON_PRESS_MASK|GDK_POINTER_MOTION_MASK|GDK_SCROLL_MASK);gtk_widget_set_has_tooltip(window_,TRUE);
            g_signal_connect(window_,"draw",G_CALLBACK((+[](GtkWidget*,cairo_t* cr,gpointer data)->gboolean{auto& self=*(NativePanel*)data;cairo_set_operator(cr,CAIRO_OPERATOR_SOURCE);cairo_set_source_rgba(cr,0,0,0,0);cairo_paint(cr);cairo_set_operator(cr,CAIRO_OPERATOR_OVER);cairo_scale(cr,self.scale,self.scale);Canvas canvas(cr);self.scene.draw(canvas,self.controller.model.enabled?self.controller.model:self.paintedModel,wallNow(),self.english);
                auto region=cairo_region_create();for(const auto& hit:self.scene.hits){float minX=1e8f,minY=1e8f,maxX=-1e8f,maxY=-1e8f;for(auto point:{Point{(float)hit.rect.x,(float)hit.rect.y},Point{(float)(hit.rect.x+hit.rect.width),(float)hit.rect.y},Point{(float)hit.rect.x,(float)(hit.rect.y+hit.rect.height)},Point{(float)(hit.rect.x+hit.rect.width),(float)(hit.rect.y+hit.rect.height)}}){auto p=rotate(point,Point{},self.scene.angle);float x=(p.x+self.scene.offsetX)*self.scale,y=(p.y+self.scene.offsetY)*self.scale;minX=std::min(minX,x);maxX=std::max(maxX,x);minY=std::min(minY,y);maxY=std::max(maxY,y);}cairo_rectangle_int_t rect{(int)std::floor(minX),(int)std::floor(minY),(int)std::ceil(maxX-minX),(int)std::ceil(maxY-minY)};cairo_region_union_rectangle(region,&rect);}auto window=gtk_widget_get_window(self.window_);if(window)gdk_window_input_shape_combine_region(window,region,0,0);cairo_region_destroy(region);return TRUE;})),this);
            g_signal_connect(window_,"button-press-event",G_CALLBACK(+[](GtkWidget*,GdkEventButton* event,gpointer data)->gboolean{auto& self=*(NativePanel*)data;if(self.dragging_)return TRUE;if(auto h=self.scene.hit(event->x/self.scale,event->y/self.scale))self.action(*h);return TRUE;}),this);
            g_signal_connect(window_,"scroll-event",G_CALLBACK((+[](GtkWidget*,GdkEventScroll* event,gpointer data)->gboolean{auto& self=*(NativePanel*)data;if(self.scene.expanded)self.scene.scrollRows=std::max(0,self.scene.scrollRows+(event->direction==GDK_SCROLL_UP?-1:1));return TRUE;})),this);
            g_signal_connect(window_,"motion-notify-event",G_CALLBACK(+[](GtkWidget*,GdkEventMotion* event,gpointer data)->gboolean{auto& self=*(NativePanel*)data;auto hit=self.scene.hit(event->x/self.scale,event->y/self.scale);self.scene.hover=hit?hit->key:"";return FALSE;}),this);
            g_signal_connect(window_,"query-tooltip",G_CALLBACK(+[](GtkWidget*,gint x,gint y,gboolean,GtkTooltip* tooltip,gpointer data)->gboolean{auto& self=*(NativePanel*)data;if(self.dragging_)return FALSE;auto hit=self.scene.hit(x/self.scale,y/self.scale);if(!hit)return FALSE;auto detail=PanelScene::detail(*hit,self.controller.model,self.english);if(detail.empty())return FALSE;gtk_tooltip_set_text(tooltip,detail.c_str());return TRUE;}),this);
        }
        auto display=gtk_widget_get_display(window_);auto monitor=gdk_display_get_monitor_at_point(display,x,y);if(monitor){GdkRectangle bounds{};gdk_monitor_get_workarea(monitor,&bounds);x=std::clamp(x,bounds.x,std::max(bounds.x,bounds.x+bounds.width-w));y=std::clamp(y,bounds.y,std::max(bounds.y,bounds.y+bounds.height-h));}
        gtk_widget_set_opacity(window_,controller.opacity);
        gtk_window_move(GTK_WINDOW(window_),x,y);gtk_window_resize(GTK_WINDOW(window_),w,h);gtk_widget_show(window_);gtk_widget_queue_draw(window_);
#endif
    }
#ifdef _WIN32
    void menu(HMENU parent,UINT base){HMENU menu=CreatePopupMenu();auto add=[&](UINT id,const wchar_t* label,bool checked){AppendMenuW(menu,MF_STRING|(checked?MF_CHECKED:0),base+id,label);};
        add(0,english?L"Work mode (double-click cat)":L"工作模式（双击小猫）",controller.model.enabled);AppendMenuW(menu,MF_SEPARATOR,0,nullptr);
        for(int i=0;i<4;++i){const wchar_t* en[]={L"Codex",L"Claude",L"Both tools",L"Automatic"};const wchar_t* zh[]={L"仅 Codex",L"仅 Claude",L"同时显示",L"自动识别"};add(1+i,english?en[i]:zh[i],(int)controller.model.options.selection==i);}
        add(5,english?L"Autonomous typing":L"自主双手打字",controller.model.options.autonomousTyping);add(6,english?L"Random expressions":L"自主打字随机表情",controller.model.options.randomExpressions);add(7,english?L"Keyboard bubbles":L"打字气泡",controller.model.options.typingBubbles);
        AppendMenuW(menu,MF_STRING,base+8,english?L"CLI connection help…":L"CLI 连接说明…");add(9,english?L"Work sounds":L"工作模式声音",controller.model.options.sound);
        add(10,english?L"Blue switches":L"青轴",controller.model.options.switchType==0);add(11,english?L"Brown switches":L"茶轴",controller.model.options.switchType==1);add(12,english?L"Red switches":L"红轴",controller.model.options.switchType==2);
        add(13,english?L"Bar pop sounds":L"状态条 / 任务条弹出声",controller.model.options.popSound);
        AppendMenuW(menu,MF_STRING,base+14,english?L"Sound volumes…":L"音量调节…");
        AppendMenuW(menu,MF_STRING,base+15,english?L"Connect Claude Code task hooks…":L"连接 Claude Code 任务监听…");
        AppendMenuW(menu,MF_STRING,base+16,english?L"Connect Codex task hooks…":L"连接 Codex 任务监听…");
        AppendMenuW(parent,MF_POPUP,(UINT_PTR)menu,english?L"Work mode":L"工作模式");}
#else
    void menu(GtkWidget* parent){auto submenu=gtk_menu_new();auto item=gtk_menu_item_new_with_label(english?"Work mode":"工作模式");gtk_menu_item_set_submenu(GTK_MENU_ITEM(item),submenu);gtk_menu_shell_append(GTK_MENU_SHELL(parent),item);
        const char* en[]={"Work mode (double-click cat)","Codex","Claude","Both tools","Automatic","Autonomous typing","Random expressions","Keyboard bubbles","CLI connection help…","Work sounds","Blue switches","Brown switches","Red switches","Bar pop sounds","Sound volumes…","Connect Claude Code task hooks…","Connect Codex task hooks…"};
        const char* zh[]={"工作模式（双击小猫）","仅 Codex","仅 Claude","同时显示","自动识别","自主双手打字","自主打字随机表情","打字气泡","CLI 连接说明…","工作模式声音","青轴","茶轴","红轴","状态条 / 任务条弹出声","音量调节…","连接 Claude Code 任务监听…","连接 Codex 任务监听…"};
        for(int i=0;i<17;++i){auto child=gtk_check_menu_item_new_with_label(english?en[i]:zh[i]);bool checked=i==0?controller.model.enabled:i<=4?(int)controller.model.options.selection==i-1:i==5?controller.model.options.autonomousTyping:i==6?controller.model.options.randomExpressions:i==7?controller.model.options.typingBubbles:i==9?controller.model.options.sound:i>=10&&i<=12?controller.model.options.switchType==i-10:i==13?controller.model.options.popSound:false;gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(child),checked);g_object_set_data(G_OBJECT(child),"command",GINT_TO_POINTER(i));g_signal_connect(child,"activate",G_CALLBACK(+[](GtkMenuItem* child,gpointer data){((NativePanel*)data)->command(GPOINTER_TO_INT(g_object_get_data(G_OBJECT(child),"command")));}),this);gtk_menu_shell_append(GTK_MENU_SHELL(submenu),child);}}
#endif
    void command(int id){if(id==0)toggle();else if(id<=4)controller.select((Selection)(id-1));else if(id==5)controller.model.options.autonomousTyping=!controller.model.options.autonomousTyping;else if(id==6)controller.model.options.randomExpressions=!controller.model.options.randomExpressions;else if(id==7)controller.model.options.typingBubbles=!controller.model.options.typingBubbles;else if(id==9){controller.model.options.sound=!controller.model.options.sound;if(!controller.model.options.sound)controller.audio.stop();}
        else if(id>=10&&id<=12)controller.model.options.switchType=id-10;
        else if(id==13)controller.model.options.popSound=!controller.model.options.popSound;
        else if(id==14)volumes();
        else if(id==15||id==16)connectHooks(id==16?Tool::Codex:Tool::Claude);
        else if(id==8){
#ifdef _WIN32
        MessageBoxW(hwnd_,english?L"Install and sign into the Codex / Claude Code CLI first.\nCodex: codex login\nClaude: claude\nLocal terminal sessions appear as task bubbles. Quota windows not provided by the tool show N/A.":L"请先安装并登录 Codex / Claude Code CLI。\nCodex：codex login\nClaude：claude\n小猫读取本地任务。工具没有提供的额度显示为 N/A。",L"KuroCatWork",MB_OK);
#else
        GtkWidget* dialog=gtk_message_dialog_new(nullptr,GTK_DIALOG_DESTROY_WITH_PARENT,GTK_MESSAGE_INFO,GTK_BUTTONS_OK,"%s",english?"Install and sign into Codex / Claude Code CLI first.\nCodex: codex login\nClaude: claude\nMissing quota windows show N/A.":"请先安装并登录 Codex / Claude Code CLI。\nCodex：codex login\nClaude：claude\n工具未提供的额度显示为 N/A。");gtk_dialog_run(GTK_DIALOG(dialog));gtk_widget_destroy(dialog);
#endif
        }controller.save();}
    void connectHooks(Tool tool){bool allow=false;
#ifdef _WIN32
        allow=MessageBoxW(hwnd_,english?L"Merge KuroCatWork task hooks into this tool’s settings? Existing settings are preserved and backed up. Hooks only record task status locally.":L"将 KuroCatWork 任务监听合并到工具设置？原有设置会保留并备份。监听只在本地记录任务状态。",L"KuroCatWork",MB_YESNO|MB_ICONQUESTION)==IDYES;
#else
        auto dialog=gtk_message_dialog_new(nullptr,GTK_DIALOG_DESTROY_WITH_PARENT,GTK_MESSAGE_QUESTION,GTK_BUTTONS_YES_NO,"%s",english?"Merge KuroCatWork task hooks? Existing settings are preserved and backed up. Only task status is recorded locally.":"合并 KuroCatWork 任务监听？原设置会保留并备份，只在本地记录任务状态。");allow=gtk_dialog_run(GTK_DIALOG(dialog))==GTK_RESPONSE_YES;gtk_widget_destroy(dialog);
#endif
        if(!allow){return;}std::string error;bool ok=installHooks(tool,error);
#ifdef _WIN32
        MessageBoxW(hwnd_,ok?(english?L"Connected. Restart the CLI session to load the hooks.":L"已连接。请重启对应 CLI 会话，使监听生效。"):wide(error).c_str(),L"KuroCatWork",MB_OK);
#else
        auto result=gtk_message_dialog_new(nullptr,GTK_DIALOG_DESTROY_WITH_PARENT,ok?GTK_MESSAGE_INFO:GTK_MESSAGE_ERROR,GTK_BUTTONS_OK,"%s",ok?(english?"Connected. Restart the CLI session to load the hooks.":"已连接。请重启对应 CLI 会话。"):error.c_str());gtk_dialog_run(GTK_DIALOG(result));gtk_widget_destroy(result);
#endif
    }
    void volumes(){
#ifdef _WIN32
        if(volumeWindow_){ShowWindow(volumeWindow_,SW_SHOW);return;}
        INITCOMMONCONTROLSEX init{sizeof(init),ICC_BAR_CLASSES};InitCommonControlsEx(&init);
        WNDCLASSW cls{};cls.hInstance=GetModuleHandleW(nullptr);cls.lpszClassName=L"KuroCatWorkVolumes";cls.hbrBackground=(HBRUSH)(COLOR_WINDOW+1);cls.lpfnWndProc=volumeProc;RegisterClassW(&cls);
        volumeWindow_=CreateWindowExW(WS_EX_TOOLWINDOW,cls.lpszClassName,english?L"Work sound volumes":L"工作模式音量",WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU, CW_USEDEFAULT,CW_USEDEFAULT,410,275,nullptr,nullptr,cls.hInstance,this);ShowWindow(volumeWindow_,SW_SHOW);
#else
        auto dialog=gtk_dialog_new_with_buttons(english?"Work sound volumes":"工作模式音量",nullptr,GTK_DIALOG_DESTROY_WITH_PARENT,english?"Close":"关闭",GTK_RESPONSE_CLOSE,nullptr);auto box=gtk_dialog_get_content_area(GTK_DIALOG(dialog));
        const char* en[]={"Keyboard","Meow","Bar pops"};const char* zh[]={"按键声","喵叫","气泡弹出声"};
        for(int i=0;i<3;++i){auto label=gtk_label_new(english?en[i]:zh[i]);gtk_box_pack_start(GTK_BOX(box),label,FALSE,FALSE,4);auto slider=gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL,0,100,1);gtk_widget_set_size_request(slider,320,-1);double* value=i==0?&controller.model.options.keyboardVolume:i==1?&controller.model.options.meowVolume:&controller.model.options.popVolume;gtk_range_set_value(GTK_RANGE(slider),*value*100);g_signal_connect(slider,"value-changed",G_CALLBACK(+[](GtkRange* range,gpointer value){*(double*)value=gtk_range_get_value(range)/100;}),value);gtk_box_pack_start(GTK_BOX(box),slider,FALSE,FALSE,4);}gtk_widget_show_all(dialog);gtk_dialog_run(GTK_DIALOG(dialog));gtk_widget_destroy(dialog);controller.save();
#endif
    }
private:
#ifdef _WIN32
    HWND volumeWindow_=nullptr;HWND sliders_[3]{};
    static LRESULT CALLBACK volumeProc(HWND window,UINT message,WPARAM wp,LPARAM lp){auto self=(NativePanel*)GetWindowLongPtrW(window,GWLP_USERDATA);
        if(message==WM_NCCREATE){self=(NativePanel*)((CREATESTRUCTW*)lp)->lpCreateParams;SetWindowLongPtrW(window,GWLP_USERDATA,(LONG_PTR)self);}
        if(!self){return DefWindowProcW(window,message,wp,lp);}
        if(message==WM_CREATE){const wchar_t* en[]={L"Keyboard",L"Meow",L"Bar pops"};const wchar_t* zh[]={L"按键声",L"喵叫",L"气泡弹出声"};for(int i=0;i<3;++i){CreateWindowW(L"STATIC",self->english?en[i]:zh[i],WS_VISIBLE|WS_CHILD,18,18+i*68,115,22,window,nullptr,nullptr,nullptr);auto slider=CreateWindowW(TRACKBAR_CLASSW,L"",WS_VISIBLE|WS_CHILD|TBS_AUTOTICKS,140,12+i*68,230,45,window,(HMENU)(INT_PTR)(5000+i),nullptr,nullptr);self->sliders_[i]=slider;SendMessageW(slider,TBM_SETRANGE,TRUE,MAKELPARAM(0,100));double value=i==0?self->controller.model.options.keyboardVolume:i==1?self->controller.model.options.meowVolume:self->controller.model.options.popVolume;SendMessageW(slider,TBM_SETPOS,TRUE,(LPARAM)(value*100));}return 0;}
        if(message==WM_HSCROLL){for(int i=0;i<3;++i){double value=SendMessageW(self->sliders_[i],TBM_GETPOS,0,0)/100.;if(i==0)self->controller.model.options.keyboardVolume=value;else if(i==1)self->controller.model.options.meowVolume=value;else self->controller.model.options.popVolume=value;}self->controller.save();return 0;}
        if(message==WM_DESTROY){self->volumeWindow_=nullptr;return 0;}return DefWindowProcW(window,message,wp,lp);
    }
#endif
    bool dragging_=false;
#ifdef _WIN32
    HWND hwnd_=nullptr,tip_=nullptr;std::wstring hoverText_;
    static LRESULT CALLBACK proc(HWND hwnd,UINT message,WPARAM wp,LPARAM lp){auto self=(NativePanel*)GetWindowLongPtrW(hwnd,GWLP_USERDATA);if(message==WM_NCCREATE){self=(NativePanel*)((CREATESTRUCTW*)lp)->lpCreateParams;SetWindowLongPtrW(hwnd,GWLP_USERDATA,(LONG_PTR)self);}if(!self)return DefWindowProcW(hwnd,message,wp,lp);
        if(message==WM_MOUSEACTIVATE){return MA_NOACTIVATE;}
        if(message==WM_MOUSEMOVE){auto h=self->scene.hit((short)LOWORD(lp)/self->scale,(short)HIWORD(lp)/self->scale);self->scene.hover=h?h->key:"";
            if(!self->tip_){self->tip_=CreateWindowExW(WS_EX_TOPMOST,TOOLTIPS_CLASSW,nullptr,WS_POPUP|TTS_ALWAYSTIP|TTS_NOPREFIX,CW_USEDEFAULT,CW_USEDEFAULT,CW_USEDEFAULT,CW_USEDEFAULT,hwnd,nullptr,GetModuleHandleW(nullptr),nullptr);TOOLINFOW tool{};tool.cbSize=sizeof(tool);tool.uFlags=TTF_IDISHWND|TTF_SUBCLASS;tool.hwnd=hwnd;tool.uId=(UINT_PTR)hwnd;tool.lpszText=LPSTR_TEXTCALLBACKW;SendMessageW(self->tip_,TTM_ADDTOOLW,0,(LPARAM)&tool);SendMessageW(self->tip_,TTM_SETMAXTIPWIDTH,0,(LPARAM)(320*self->scale));}return 0;}
        if(message==WM_NOTIFY&&((NMHDR*)lp)->code==TTN_GETDISPINFOW){POINT cursor{};GetCursorPos(&cursor);ScreenToClient(hwnd,&cursor);auto h=self->scene.hit(cursor.x/self->scale,cursor.y/self->scale);self->hoverText_=wide(h?PanelScene::detail(*h,self->controller.model,self->english):"");((NMTTDISPINFOW*)lp)->lpszText=self->hoverText_.data();return 0;}

        if(message==WM_LBUTTONUP&&!self->dragging_){if(auto hit=self->scene.hit((short)LOWORD(lp)/self->scale,(short)HIWORD(lp)/self->scale))self->action(*hit);return 0;}
        if(message==WM_NCHITTEST){return HTCLIENT;}
        return DefWindowProcW(hwnd,message,wp,lp);
    }
#else
    GtkWidget* window_=nullptr;
#endif
};
}
