#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <stdio.h>
#include <unistd.h>
#include <poll.h>
int main(void) {
 Display *d=XOpenDisplay(NULL); if(!d)return 2;
 int screen=DefaultScreen(d); Window root=RootWindow(d,screen);
 Window w=XCreateSimpleWindow(d,root,30,40,480,320,0,0,0x3366cc);
 XClassHint hint={"ataxia-fixture","AtaxiaFixture"}; XSetClassHint(d,w,&hint);
 XStoreName(d,w,"XWayland fixture"); XSelectInput(d,w,ExposureMask|StructureNotifyMask|KeyPressMask|ButtonPressMask);
 XMapWindow(d,w);XFlush(d);
 usleep(300000);
 XSetWindowAttributes a={.override_redirect=True,.background_pixel=0xcc6633};
 Window popup=XCreateWindow(d,root,70,90,120,80,0,CopyFromParent,InputOutput,CopyFromParent,CWOverrideRedirect|CWBackPixel,&a);
 XSetTransientForHint(d,popup,w);XMapWindow(d,popup);XFlush(d);
 for(int i=0;i<300;i++){
  while(XPending(d)) {XEvent e;XNextEvent(d,&e);if(e.type==ConfigureNotify)printf("size %d %d\n",e.xconfigure.width,e.xconfigure.height);}
  fflush(stdout);struct pollfd p={ConnectionNumber(d),POLLIN,0};poll(&p,1,20);
 }
 XDestroyWindow(d,popup);XDestroyWindow(d,w);XCloseDisplay(d);return 0;
}
