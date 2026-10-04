#include "ProcessBridge.h"
#include <libproc.h>
#include <sys/sysctl.h>
#include <sys/proc_info.h>
#include <mach/mach.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <string.h>
#include <stdlib.h>
// Darwin ABI from Apple's proc_info_private.h. Size checked; failure disables actions.
struct dp_unique { uint8_t uuid[16]; uint64_t unique, parent; int32_t version, original_parent_version; uint64_t reserved[2]; };
_Static_assert(sizeof(struct dp_unique) == 56, "Darwin process identity ABI");
int dp_pids(int32_t *buffer, int count) { return proc_listallpids(buffer, count * sizeof(int32_t)); }
int dp_read(int32_t pid, DPProcess *out) {
 struct proc_bsdinfo b = {0}; struct dp_unique u = {0};
 if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &b, sizeof(b)) != sizeof(b)) return 0;
 if (proc_pidinfo(pid, 17, 0, &u, sizeof(u)) != sizeof(u)) return 0;
 memset(out, 0, sizeof(*out)); out->pid=pid; out->ppid=b.pbi_ppid; out->uid=b.pbi_uid; out->status=b.pbi_status;
 out->start=b.pbi_start_tvsec*1000000+b.pbi_start_tvusec; out->unique=u.unique; out->parent_unique=u.parent; out->version=u.version;
 proc_pidpath(pid,out->path,sizeof(out->path));
 struct proc_vnodepathinfo v = {0};
 if(proc_pidinfo(pid,PROC_PIDVNODEPATHINFO,0,&v,sizeof(v)) == sizeof(v)) strlcpy(out->cwd,v.pvi_cdir.vip_path,sizeof(out->cwd));
 struct rusage_info_v2 r = {0};
 if(proc_pid_rusage(pid,RUSAGE_INFO_V2,(rusage_info_t *)&r)==0) { out->memory=r.ri_resident_size; out->cpu=r.ri_user_time+r.ri_system_time; }
 struct dp_unique after={0};
 if(proc_pidinfo(pid,17,0,&after,sizeof(after)) != sizeof(after) || after.unique!=u.unique || after.version!=u.version) return 0;
 return 1;
}
int dp_args(int32_t pid,char *buffer,int capacity) {
 int mib[3]={CTL_KERN,KERN_PROCARGS2,pid}; size_t size=capacity;
 if(sysctl(mib,3,buffer,&size,NULL,0)<0 || size<sizeof(int)) return 0;
 int argc=0; memcpy(&argc,buffer,sizeof(int)); if(argc<1 || argc>8192) return 0;
 char *p=buffer+sizeof(int), *end=buffer+size;
 while(p<end && *p) p++; while(p<end && !*p) p++;
 char *first=p; for(int i=0;i<argc;i++) { while(p<end && *p) p++; if(p==end) return 0; p++; }
 int length=(int)(p-first); memmove(buffer,first,length); return length;
}
int dp_signal(DPProcess expected,int sig) {
 DPProcess now;
 if(!dp_read(expected.pid,&now) || now.start!=expected.start || now.unique!=expected.unique || now.version!=expected.version || now.uid!=getuid()) return ESRCH;
 if(now.pid<=1 || now.pid==getpid()) return EPERM;
 if(sig == SIGSTOP && now.status == 4) return EBUSY;
 audit_token_t token={{0}}; token.val[5]=now.pid; token.val[7]=now.version;
 // Kernel validates PID + generation atomically. Never fall back to kill(pid).
 return proc_signal_with_audittoken(&token,sig);
}

#include <arpa/inet.h>
int dp_tcp_ports(int32_t pid, int32_t *ports, int capacity) {
 errno=0;
 int needed=proc_pidinfo(pid,PROC_PIDLISTFDS,0,NULL,0);
 if(needed<=0) return errno ? -errno : 0;
 struct proc_fdinfo *fds=NULL; int bytes=0, allocated=0;
 for(int retry=0;retry<3;retry++) {
  allocated=needed+32*(int)sizeof(struct proc_fdinfo);
  if(allocated>16*1024*1024) {free(fds);return -EOVERFLOW;}
  struct proc_fdinfo *next=realloc(fds,allocated);
  if(!next) {free(fds);return -ENOMEM;} fds=next;
  errno=0;
  bytes=proc_pidinfo(pid,PROC_PIDLISTFDS,0,fds,allocated);
  if(bytes<=0 && errno) {int e=errno;free(fds);return -e;}
  if(bytes<allocated) break;
  needed=allocated*2;
 }
 if(bytes>=allocated) {free(fds);return -EOVERFLOW;}
 int count=0;
 for(int i=0;i<bytes/(int)sizeof(*fds);i++) {
  if(fds[i].proc_fdtype!=PROX_FDTYPE_SOCKET) continue;
  struct socket_fdinfo info={0};
  int size=proc_pidfdinfo(pid,fds[i].proc_fd,PROC_PIDFDSOCKETINFO,&info,sizeof(info));
  if(size != sizeof(info)) {
   if(errno==EBADF || errno==ESRCH || errno==ENOENT || errno==ENOTSOCK || errno==EOPNOTSUPP) continue;
   int e=errno ? errno : EIO;free(fds);return -e;
  }
  if(info.psi.soi_kind!=SOCKINFO_TCP || info.psi.soi_proto.pri_tcp.tcpsi_state!=TSI_S_LISTEN) continue;
  int port=ntohs((uint16_t)info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport);
  if(count>=capacity) {free(fds);return -EOVERFLOW;}
  ports[count++]=port;
 }
 free(fds);return count;
}
