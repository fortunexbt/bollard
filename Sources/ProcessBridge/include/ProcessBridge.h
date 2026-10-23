#include <stdint.h>
#include <stddef.h>

// One kernel call for the whole process table. Status uses Darwin p_stat (4 stopped, 5 zombie).
typedef struct {
  int32_t pid, ppid, pgid;
  uint32_t uid, status;
  uint64_t start;  // microseconds since the epoch
  char comm[17];
} DPEntry;
int dp_table(DPEntry *buffer, int capacity);

// Per-process detail, read once per process generation.
typedef struct {
  uint64_t unique, parent_unique;
  int32_t version;
  char path[1024];
} DPIdentity;
int dp_identity(int32_t pid, DPIdentity *out);
int dp_args(int32_t pid, char *buffer, int capacity);
int dp_cwd(int32_t pid, char *buffer, int capacity);

typedef struct { uint64_t memory, cpu; } DPUsage;
int dp_usage(int32_t pid, DPUsage *out);

// One kernel call for every TCP listener on the machine, with the socket's last owner.
typedef struct {
  int32_t pid;
  uint32_t uid;
  uint16_t port;
  uint8_t family;  // 4 or 6
  uint8_t wildcard;  // bound to 0.0.0.0 or ::
  uint64_t socket;  // kernel handle, stable for the socket's lifetime
  uint8_t address[16];
} DPListener;
int dp_listeners(DPListener *buffer, int capacity);
// 1 if the process holds a descriptor for the socket, 0 if not, negative errno if unreadable.
int dp_owns_socket(int32_t pid, uint64_t socket);

// Kernel-checked PID generation. Never falls back to kill(pid).
int dp_signal(int32_t pid, uint64_t start, uint64_t unique, int32_t version, int sig);
