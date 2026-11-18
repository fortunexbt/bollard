#include <stdint.h>
#include <stddef.h>

// One kernel call for the whole process table. Status uses Darwin p_stat (4 stopped, 5 zombie).
typedef struct {
  int32_t pid, ppid, pgid;
  uint32_t uid, status;
  uint8_t tty;  // has a controlling terminal
  uint8_t foreground;  // in that terminal's foreground process group
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
// The process generation alone: exec advances it. 0 when the process is gone.
int32_t dp_generation(int32_t pid);
// The process macOS holds responsible for this one: the terminal, editor or agent whose work it
// is, which survives the parent exiting. 0 when unknown. The lookup is a libsystem function with
// no public header, resolved at run time so its absence only loses the hint.
int32_t dp_responsible(int32_t pid);
int dp_args(int32_t pid, char *buffer, int capacity);
int dp_cwd(int32_t pid, char *buffer, int capacity);

typedef struct { uint64_t memory, cpu; } DPUsage;
int dp_usage(int32_t pid, DPUsage *out);

// A socket a process can be reached on.
enum { DP_TCP = 1, DP_UDP = 2, DP_UNIX = 3 };
typedef struct {
  int32_t pid;
  uint16_t port;
  uint8_t transport;
  uint8_t family;  // 4 or 6; 0 for Unix-domain
  uint8_t wildcard;  // bound to 0.0.0.0 or ::
  uint64_t socket;  // kernel handle, stable for the socket's lifetime
  uint8_t address[16];
  char path[104];  // Unix-domain only
} DPSocket;
// Listening TCP, bound UDP and listening Unix-domain sockets, one record per holding process.
// Returns the count or a negative errno; the caller frees *out.
int dp_sockets(DPSocket **out);

// Kernel-checked PID generation. Never falls back to kill(pid).
int dp_signal(int32_t pid, uint64_t start, uint64_t unique, int32_t version, int sig);
