#include "ProcessBridge.h"
#include <libproc.h>
#include <sys/sysctl.h>
#include <sys/proc_info.h>
#include <netinet/in.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <string.h>
#include <stdlib.h>

// Darwin ABI from Apple's proc_info_private.h. Size checked; failure disables actions.
struct dp_unique { uint8_t uuid[16]; uint64_t unique, parent; int32_t version, original_parent_version; uint64_t reserved[2]; };
_Static_assert(sizeof(struct dp_unique) == 56, "Darwin process identity ABI");

int dp_table(DPEntry *buffer, int capacity) {
  int mib[3] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL};
  size_t size = 0;
  if (sysctl(mib, 3, NULL, &size, NULL, 0) < 0) return -errno;
  size += size / 4 + 64 * sizeof(struct kinfo_proc);
  struct kinfo_proc *procs = malloc(size);
  if (!procs) return -ENOMEM;
  if (sysctl(mib, 3, procs, &size, NULL, 0) < 0) { int e = errno; free(procs); return -e; }
  int count = (int)(size / sizeof(struct kinfo_proc));
  if (count > capacity) { free(procs); return -EOVERFLOW; }
  for (int i = 0; i < count; i++) {
    struct kinfo_proc *k = &procs[i];
    DPEntry *e = &buffer[i];
    e->pid = k->kp_proc.p_pid;
    e->ppid = k->kp_eproc.e_ppid;
    e->pgid = k->kp_eproc.e_pgid;
    e->uid = k->kp_eproc.e_ucred.cr_uid;
    e->status = k->kp_proc.p_stat;
    e->start = (uint64_t)k->kp_proc.p_starttime.tv_sec * 1000000 + (uint64_t)k->kp_proc.p_starttime.tv_usec;
    strlcpy(e->comm, k->kp_proc.p_comm, sizeof(e->comm));
  }
  free(procs);
  return count;
}

int dp_identity(int32_t pid, DPIdentity *out) {
  struct dp_unique u = {0};
  if (proc_pidinfo(pid, 17, 0, &u, sizeof(u)) != sizeof(u)) return 0;
  memset(out, 0, sizeof(*out));
  out->unique = u.unique;
  out->parent_unique = u.parent;
  out->version = u.version;
  proc_pidpath(pid, out->path, sizeof(out->path));
  return 1;
}

int dp_args(int32_t pid, char *buffer, int capacity) {
  int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
  size_t size = capacity;
  if (sysctl(mib, 3, buffer, &size, NULL, 0) < 0 || size < sizeof(int)) return 0;
  int argc = 0;
  memcpy(&argc, buffer, sizeof(int));
  if (argc < 1 || argc > 8192) return 0;
  char *p = buffer + sizeof(int), *end = buffer + size;
  while (p < end && *p) p++;
  while (p < end && !*p) p++;
  char *first = p;
  for (int i = 0; i < argc; i++) {
    while (p < end && *p) p++;
    if (p == end) return 0;
    p++;
  }
  int length = (int)(p - first);
  memmove(buffer, first, length);
  return length;
}

int dp_cwd(int32_t pid, char *buffer, int capacity) {
  struct proc_vnodepathinfo v = {0};
  if (proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &v, sizeof(v)) != sizeof(v)) return 0;
  strlcpy(buffer, v.pvi_cdir.vip_path, capacity);
  return 1;
}

int dp_usage(int32_t pid, DPUsage *out) {
  struct rusage_info_v2 r = {0};
  if (proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&r) != 0) return 0;
  out->memory = r.ri_resident_size;
  out->cpu = r.ri_user_time + r.ri_system_time;
  return 1;
}

// Darwin ABI from XNU in_pcb.h, socketvar.h and tcp_var.h (net.inet.tcp.pcblist_n, as used by
// netstat). Every record starts with a length and kind and is padded to 8 bytes; only the
// leading fields are read, and each record's declared length is checked before use.
#pragma pack(4)
struct dp_xinpgen { uint32_t len; unsigned count; uint64_t gen, sogen; };
struct dp_xgen { uint32_t len, kind; };
struct dp_xinpcb {
  uint32_t len, kind; uint64_t inpp; uint16_t fport, lport; uint64_t ppcb, gencnt;
  int flags; uint32_t flow; uint8_t vflag, ttl, proto;
  uint32_t faddr[4], laddr[4];
};
struct dp_xsocket {
  uint32_t len, kind; uint64_t so; short type; uint32_t options; short linger, state;
  uint64_t pcb; int protocol, family; short qlen, incqlen, qlimit, timeo; uint16_t error;
  int32_t pgid; uint32_t oobmark; uint32_t uid; int32_t last_pid, e_pid;
};
struct dp_xtcpcb { uint32_t len, kind; uint64_t segq; int dupacks; int timer[4]; int state; };
#pragma pack()
enum { DP_XSO_SOCKET = 0x1, DP_XSO_INPCB = 0x10, DP_XSO_TCPCB = 0x20, DP_TCPS_LISTEN = 1, DP_INP_IPV4 = 1 };

int dp_listeners(DPListener *buffer, int capacity) {
  size_t size = 0;
  if (sysctlbyname("net.inet.tcp.pcblist_n", NULL, &size, NULL, 0) < 0) return -errno;
  size += size / 4 + 4096;
  char *data = malloc(size);
  if (!data) return -ENOMEM;
  if (sysctlbyname("net.inet.tcp.pcblist_n", data, &size, NULL, 0) < 0) { int e = errno; free(data); return -e; }
  char *p = data, *end = data + size;
  if (size < sizeof(struct dp_xinpgen)) { free(data); return -EINVAL; }
  p += ((struct dp_xinpgen *)data)->len;
  struct dp_xinpcb *inp = NULL; struct dp_xsocket *so = NULL; struct dp_xtcpcb *tp = NULL;
  int count = 0;
  while (p + sizeof(struct dp_xgen) <= end) {
    struct dp_xgen *g = (struct dp_xgen *)p;
    if (g->len < sizeof(struct dp_xgen) || p + g->len > end) break;
    if (g->kind == DP_XSO_INPCB && g->len >= sizeof(struct dp_xinpcb)) inp = (struct dp_xinpcb *)p;
    else if (g->kind == DP_XSO_SOCKET && g->len >= sizeof(struct dp_xsocket)) so = (struct dp_xsocket *)p;
    else if (g->kind == DP_XSO_TCPCB && g->len >= sizeof(struct dp_xtcpcb)) tp = (struct dp_xtcpcb *)p;
    p += (g->len + 7) & ~7u;
    if (!(inp && so && tp)) continue;
    if (tp->state == DP_TCPS_LISTEN) {
      if (count >= capacity) { free(data); return -EOVERFLOW; }
      DPListener *l = &buffer[count++];
      memset(l, 0, sizeof(*l));
      l->pid = so->last_pid;
      l->uid = so->uid;
      l->port = ntohs(inp->lport);
      l->socket = so->so;
      const uint8_t *local = (const uint8_t *)inp->laddr;
      if (inp->vflag & DP_INP_IPV4) {
        l->family = 4;
        memcpy(l->address, local + 12, 4);
        l->wildcard = inp->laddr[3] == 0;
      } else {
        l->family = 6;
        memcpy(l->address, local, 16);
        l->wildcard = (inp->laddr[0] | inp->laddr[1] | inp->laddr[2] | inp->laddr[3]) == 0;
      }
    }
    inp = NULL; so = NULL; tp = NULL;
  }
  free(data);
  return count;
}

int dp_owns_socket(int32_t pid, uint64_t socket) {
  errno = 0;
  int needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
  if (needed <= 0) return errno ? -errno : 0;
  int allocated = needed + 64 * (int)sizeof(struct proc_fdinfo);
  struct proc_fdinfo *fds = malloc(allocated);
  if (!fds) return -ENOMEM;
  errno = 0;
  int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, allocated);
  if (bytes <= 0) { int e = errno; free(fds); return e ? -e : 0; }
  int found = 0;
  for (int i = 0; i < bytes / (int)sizeof(*fds) && !found; i++) {
    if (fds[i].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
    struct socket_fdinfo info = {0};
    if (proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &info, sizeof(info)) != sizeof(info)) continue;
    found = info.psi.soi_so == socket;
  }
  free(fds);
  return found;
}

int dp_signal(int32_t pid, uint64_t start, uint64_t unique, int32_t version, int sig) {
  struct proc_bsdinfo b = {0};
  struct dp_unique u = {0};
  if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &b, sizeof(b)) != sizeof(b)) return ESRCH;
  if (proc_pidinfo(pid, 17, 0, &u, sizeof(u)) != sizeof(u)) return ESRCH;
  uint64_t now = b.pbi_start_tvsec * 1000000 + b.pbi_start_tvusec;
  if (now != start || u.unique != unique || u.version != version) return ESRCH;
  if (b.pbi_uid != getuid()) return EPERM;
  if (pid <= 1 || pid == getpid()) return EPERM;
  audit_token_t token = {{0}};
  token.val[5] = pid;
  token.val[7] = u.version;
  // The kernel validates PID and generation atomically.
  return proc_signal_with_audittoken(&token, sig);
}
