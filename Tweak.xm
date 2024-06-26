#import <PSHeader/Misc.h>
#import <libSandy.h>
#import <version.h>
#import <rootless.h>

#include <sys/sysctl.h>
#include <xpc/xpc.h>

#define MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT 6
#define JETSAM_MEMORY_LIMIT 512
#define DEFAULT_HOSTS_PATH "/Library/Tweak Support/Common/hosts"
#define NEW_HOSTS_PATH ROOT_PATH("/etc/hosts.lmb")
#define ROOTLESS_NEW_HOSTS_PATH "/var/jb/Library/Tweak Support/Common/hosts"

static FILE *etcHosts;

extern "C" int memorystatus_control(uint32_t command, pid_t pid, uint32_t flags, void *buffer, size_t buffersize);

%group mDNSResponder_iOS12

// Allow /etc/hosts to be read on iOS 12 and above
bool (*os_variant_has_internal_diagnostics)(const char *) = NULL;
%hookf(bool, os_variant_has_internal_diagnostics, const char *subsystem) {
    if (subsystem && strcmp(subsystem, "com.apple.mDNSResponder") == 0)
        return 1;
    return %orig(subsystem);
}

%end

%group mDNSResponder

unsigned int *mDNS_StatusCallback_allocated = NULL;

// Reset the memory counter every time it is increased
void (*mDNS_StatusCallback)(void *, int) = NULL;
%hookf(void, mDNS_StatusCallback, void *arg1, int arg2) {
    if (mDNS_StatusCallback_allocated)
        *mDNS_StatusCallback_allocated = 0;
    %orig(arg1, arg2);
}

// Open UHB's hosts instead of DEFAULT_HOSTS_PATH
// This new UHB will place all the blocked addresses to NEW_HOSTS_PATH so we won't mess up with the original file
// If in any cases NEW_HOSTS_PATH got corrupted, we fallback to the original one (DEFAULT_HOSTS_PATH)
%hookf(FILE *, fopen, const char *path, const char *mode) {
    if (path && strcmp(path, DEFAULT_HOSTS_PATH) == 0) {
        if (etcHosts) return etcHosts;
        FILE *r = %orig(ROOTLESS_NEW_HOSTS_PATH, mode);
        if (r) return r;
        r = %orig(NEW_HOSTS_PATH, mode);
        if (r) return r;
    }
    return %orig(path, mode);
}

%end

%group mDNSResponderHelper

int (*accept_client_block_invoke)(int, xpc_object_t);
%hookf(int, accept_client_block_invoke, int arg0, xpc_object_t req_msg) {
    xpc_type_t type = xpc_get_type(req_msg);
    if (type != XPC_TYPE_DICTIONARY) {
        // mDNSResponder died, kill the helper now to respawn mDNSResponder with the helper intact
        exit(0);
    }
    return %orig(arg0, req_msg);
}

%end

%ctor {
    if (getuid()) {
        // mDNSResponder (_mDNSResponder)
        libSandy_applyProfile("LetMeBlock");
        etcHosts = fopen(ROOTLESS_NEW_HOSTS_PATH, "r");
        if (etcHosts == NULL) etcHosts = fopen(NEW_HOSTS_PATH, "r");
        MSImageRef ref = MSGetImageByName("/usr/sbin/mDNSResponder");
        mDNS_StatusCallback = (void (*)(void *, int))_PSFindSymbolCallable(ref, "_mDNS_StatusCallback");
        mDNS_StatusCallback_allocated = (unsigned int *)_PSFindSymbolReadable(ref, "_mDNS_StatusCallback.allocated");
        if (IS_IOS_OR_NEWER(iOS_12_0)) {
            MSImageRef libsys = MSGetImageByName("/usr/lib/system/libsystem_darwin.dylib");
            os_variant_has_internal_diagnostics = (bool (*)(const char *))_PSFindSymbolCallable(libsys, "_os_variant_has_internal_diagnostics");
            %init(mDNSResponder_iOS12);
        }
        %init(mDNSResponder);
        // Spawn mDNSResponderHelper if not already so that it will unlock mDNSResponder's memory limit as soon as possible
        void (*SendDict_ToServer)(xpc_object_t) = (void (*)(xpc_object_t))_PSFindSymbolCallable(ref, "_SendDict_ToServer");
        if (SendDict_ToServer) {
            xpc_object_t dict = xpc_dictionary_create(NULL, NULL, 0);
            SendDict_ToServer(dict);
        } else {
            void (*Init_Connection)(void) = (void (*)(void))_PSFindSymbolCallable(ref, "_Init_Connection");
            if (Init_Connection)
                Init_Connection();
        }
    } else {
        // mDNSResponderHelper (root)
        pid_t pid = 0;
        size_t size;
        int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
        if (sysctl(mib, 4, NULL, &size, NULL, 0) != -1) {
            struct kinfo_proc *processes = (struct kinfo_proc *)malloc(size);
            if (processes) {
                if (sysctl(mib, 4, processes, &size, NULL, 0) != -1) {
                    for (unsigned long i = 0; i < size / sizeof(struct kinfo_proc); ++i) {
                        if (strcmp(processes[i].kp_proc.p_comm, "mDNSResponder") == 0 && pid != processes[i].kp_proc.p_pid) {
                            pid = processes[i].kp_proc.p_pid;
                            memorystatus_control(MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT, pid, JETSAM_MEMORY_LIMIT, NULL, 0);
                            break;
                        }
                    }
                }
                free(processes);
            }
        }
        MSImageRef ref = MSGetImageByName("/usr/sbin/mDNSResponderHelper");
        accept_client_block_invoke = (int (*)(int, xpc_object_t))_PSFindSymbolCallable(ref, "___accept_client_block_invoke");
        if (accept_client_block_invoke) {
            %init(mDNSResponderHelper);
        }
    }
}

%dtor {
    if (etcHosts) fclose(etcHosts);
}
