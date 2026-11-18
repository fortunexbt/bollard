#include "ProcessBridge.h"
#include <libproc.h>
#include <sys/sysctl.h>
#include <sys/proc_info.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <string.h>
#include <stdlib.h>
#include <dlfcn.h>

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
    e->tty = k->kp_eproc.e_tdev != NODEV;
    e->foreground = e->tty && k->kp_eproc.e_tpgid == k->kp_eproc.e_pgid;
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

int32_t dp_generation(int32_t pid) {
  struct dp_unique u = {0};
  return proc_pidinfo(pid, 17, 0, &u, sizeof(u)) == sizeof(u) ? u.version : 0;
}

int32_t dp_responsible(int32_t pid) {
  static int32_t (*lookup)(int32_t);
  static int resolved;
  if (!resolved) { lookup = dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid"); resolved = 1; }
  int32_t owner = lookup ? lookup(pid) : 0;
  return owner > 0 ? owner : 0;
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

// Every socket a workload can be reached on: listening TCP, bound and unconnected UDP, and
// listening Unix-domain sockets, read from the descriptors of each process this user may inspect.
// macOS 27 withholds the kernel socket table (net.inet.tcp.pcblist_n) from apps, so descriptors are
// the one source that works everywhere and they name the real holder, not the last toucher. A
// socket inherited across fork is reported once per holder; the caller picks the owner.
int dp_sockets(DPSocket **out) {
  *out = NULL;
  int expected = proc_listallpids(NULL, 0);
  if (expected <= 0) return -errno;
  int bytes = (expected + 64) * (int)sizeof(pid_t);
  pid_t *pids = malloc(bytes);
  if (!pids) return -ENOMEM;
  int n = proc_listallpids(pids, bytes);
  if (n <= 0) { int e = errno; free(pids); return -e; }
  struct proc_fdinfo *fds = NULL;
  DPSocket *result = NULL;
  int fdcap = 0, count = 0, capacity = 0;
  for (int i = 0; i < n; i++) {
    int needed = proc_pidinfo(pids[i], PROC_PIDLISTFDS, 0, NULL, 0);
    if (needed <= 0) continue;
    if (needed + 64 * (int)sizeof(*fds) > fdcap) {
      free(fds);
      fdcap = needed + 64 * (int)sizeof(*fds);
      fds = malloc(fdcap);
      if (!fds) { free(pids); free(result); return -ENOMEM; }
    }
    int got = proc_pidinfo(pids[i], PROC_PIDLISTFDS, 0, fds, fdcap);
    for (int k = 0; k < got / (int)sizeof(*fds); k++) {
      if (fds[k].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
      struct socket_fdinfo info;
      if (proc_pidfdinfo(pids[i], fds[k].proc_fd, PROC_PIDFDSOCKETINFO, &info, sizeof(info)) != sizeof(info)) continue;
      const struct socket_info *si = &info.psi;
      DPSocket s = {0};
      const struct in_sockinfo *in = NULL;
      if (si->soi_kind == SOCKINFO_TCP) {
        if (si->soi_proto.pri_tcp.tcpsi_state != TSI_S_LISTEN) continue;
        in = &si->soi_proto.pri_tcp.tcpsi_ini;
        s.transport = DP_TCP;
      } else if (si->soi_kind == SOCKINFO_IN && si->soi_protocol == IPPROTO_UDP) {
        in = &si->soi_proto.pri_in;
        if (in->insi_lport == 0 || in->insi_fport != 0) continue;
        s.transport = DP_UDP;
      } else if (si->soi_kind == SOCKINFO_UN) {
        const char *path = si->soi_proto.pri_un.unsi_addr.ua_sun.sun_path;
        // Skip the per-run scratch sockets runtimes drop in the temporary directory.
        if (!(si->soi_options & SO_ACCEPTCONN) || !path[0] || strstr(path, "/var/folders/")) continue;
        s.transport = DP_UNIX;
        strlcpy(s.path, path, sizeof(s.path));
      } else continue;
      if (in) {
        s.port = ntohs((uint16_t)in->insi_lport);
        int length = (in->insi_vflag & INI_IPV4) ? 4 : 16;
        s.family = length == 4 ? 4 : 6;
        memcpy(s.address, (const uint8_t *)&in->insi_laddr + (length == 4 ? 12 : 0), length);
        uint8_t any = 0;
        for (int b = 0; b < length; b++) any |= s.address[b];
        s.wildcard = any == 0;
      }
      s.pid = pids[i];
      s.socket = si->soi_so;
      if (count == capacity) {
        capacity = capacity ? capacity * 2 : 256;
        DPSocket *grown = realloc(result, capacity * sizeof(DPSocket));
        if (!grown) { free(fds); free(pids); free(result); return -ENOMEM; }
        result = grown;
      }
      result[count++] = s;
    }
  }
  free(fds);
  free(pids);
  *out = result;
  return count;
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
