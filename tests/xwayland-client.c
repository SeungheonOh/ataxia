#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <poll.h>

static void report_state(Display *d, Window w) {
 Atom type; int format; unsigned long count, remaining; unsigned char *data=NULL;
 Atom state=XInternAtom(d,"_NET_WM_STATE",False);
 Atom hidden=XInternAtom(d,"_NET_WM_STATE_HIDDEN",False);
 Atom fullscreen=XInternAtom(d,"_NET_WM_STATE_FULLSCREEN",False);
 int is_hidden=0, is_fullscreen=0;
 if(XGetWindowProperty(d,w,state,0,64,False,XA_ATOM,&type,&format,&count,&remaining,&data)==Success && format==32){
  for(unsigned long i=0;i<count;i++){
   is_hidden |= ((Atom *)data)[i]==hidden;
   is_fullscreen |= ((Atom *)data)[i]==fullscreen;
  }
 }
 if(data)XFree(data);
 printf("state hidden %d fullscreen %d\n",is_hidden,is_fullscreen);
}

int main(void) {
 Display *d=XOpenDisplay(NULL); if(!d)return 2;
 int screen=DefaultScreen(d); Window root=RootWindow(d,screen);
 Window w=XCreateSimpleWindow(d,root,30,40,480,320,0,0,0x3366cc);
 XClassHint hint={"ataxia-fixture","AtaxiaFixture"}; XSetClassHint(d,w,&hint);
 long events=ExposureMask|StructureNotifyMask|KeyPressMask|KeyReleaseMask|ButtonPressMask|ButtonReleaseMask|PointerMotionMask|FocusChangeMask|PropertyChangeMask;
 XStoreName(d,w,"XWayland fixture"); XSelectInput(d,w,events);
 Atom close=XInternAtom(d,"WM_DELETE_WINDOW",False); XSetWMProtocols(d,w,&close,1);
 XMapWindow(d,w);XFlush(d);
 usleep(300000);
 if(getenv("ATAXIA_TEST_X11_CONFIGURE")){XMoveResizeWindow(d,w,50,60,500,340);XFlush(d);}
 XSetWindowAttributes a={.override_redirect=True,.background_pixel=0xcc6633};
 int contract=getenv("ATAXIA_TEST_X11_CONTRACT")!=NULL;
 Window popup=XCreateWindow(d,root,contract?450:70,90,120,80,0,CopyFromParent,InputOutput,CopyFromParent,CWOverrideRedirect|CWBackPixel,&a);
 XSelectInput(d,popup,events); XSetTransientForHint(d,popup,w);XMapWindow(d,popup);XFlush(d);
 int done=0;
 for(int i=0;i<400 && !done;i++){
  while(XPending(d)) {
   XEvent e;XNextEvent(d,&e);const char *name=e.xany.window==popup?"popup":"root";
   switch(e.type){
    case ConfigureNotify: if(e.xany.window==w)printf("size %d %d\n",e.xconfigure.width,e.xconfigure.height);break;
    case ButtonPress: case ButtonRelease:
     printf("button %s %u %d %d %d\n",name,e.xbutton.button,e.type==ButtonPress,e.xbutton.x,e.xbutton.y);break;
    case KeyPress: case KeyRelease: printf("key %s %u %d\n",name,e.xkey.keycode,e.type==KeyPress);break;
    case FocusIn: case FocusOut: printf("focus %s %d\n",name,e.type==FocusIn);break;
    case PropertyNotify: if(e.xany.window==w && e.xproperty.atom==XInternAtom(d,"_NET_WM_STATE",False))report_state(d,w);break;
    case ClientMessage: if((Atom)e.xclient.data.l[0]==close){puts("close");done=1;}break;
   }
  }
  fflush(stdout);struct pollfd p={ConnectionNumber(d),POLLIN,0};poll(&p,1,20);
 }
 XDestroyWindow(d,popup);XDestroyWindow(d,w);XCloseDisplay(d);return 0;
}
