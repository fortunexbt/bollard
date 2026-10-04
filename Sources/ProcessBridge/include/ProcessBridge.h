#include <stdint.h>
#include <stddef.h>
typedef struct { int32_t pid, ppid; uint32_t uid, status; uint64_t start, unique, parent_unique, memory, cpu; int32_t version; char path[4096], cwd[4096]; } DPProcess;
int dp_pids(int32_t *buffer, int count);
int dp_read(int32_t pid, DPProcess *out);
int dp_args(int32_t pid, char *buffer, int capacity);
int dp_signal(DPProcess expected, int signal);
// Returns port count, or a negative errno. Does not connect to sockets.
int dp_tcp_ports(int32_t pid, int32_t *ports, int capacity);
