#include <libproc.h>
#include <sys/resource.h>
#include <sys/proc_info.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
 if(argc!=3) return 2;
 int pid=atoi(argv[1]), seconds=atoi(argv[2]); if(pid<=1 || seconds<1 || seconds>60) return 2;
 struct rusage_info_v2 a={0},b={0};struct proc_bsdinfo before={0},after={0};
 if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&before,sizeof(before))!=sizeof(before)) return 3;
 if(proc_pid_rusage(pid,RUSAGE_INFO_V2,(rusage_info_t*)&a)) return 3;
 struct timespec wait={seconds,0};nanosleep(&wait,NULL);
 if(proc_pid_rusage(pid,RUSAGE_INFO_V2,(rusage_info_t*)&b)) return 3;
 if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&after,sizeof(after))!=sizeof(after) || before.pbi_start_tvsec!=after.pbi_start_tvsec || before.pbi_start_tvusec!=after.pbi_start_tvusec) return 4;
 double cpu_ms=(double)(b.ri_user_time+b.ri_system_time-a.ri_user_time-a.ri_system_time)/1e6;
 printf("{\"seconds\":%d,\"cpu_ms\":%.3f,\"cpu_percent\":%.5f,\"idle_wakeups\":%llu,\"interrupt_wakeups\":%llu,\"footprint_bytes\":%llu,\"resident_bytes\":%llu}\n",seconds,cpu_ms,cpu_ms/seconds/10,b.ri_pkg_idle_wkups-a.ri_pkg_idle_wkups,b.ri_interrupt_wkups-a.ri_interrupt_wkups,b.ri_phys_footprint,b.ri_resident_size);
}
