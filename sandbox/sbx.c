// sbx.exe <mode> <exe> [args...] : run a program under a token like Chromium's GPU-process sandbox.
//   modes, combined with '+':
//     lowil       Low integrity level
//     restricted  restricted token: privileges stripped, Administrators deny-only, restricting SIDs
//                 = users, everyone, restricted, user, logon (default; names below)
//     job         kill-on-close job object with UI restrictions
//     none        plain CreateProcess (control); cannot be combined
// Env: SBX_RS=<comma list> picks the restricting SIDs instead of the default five. Exact names:
//      users everyone restricted user logon auth interactive system allapp netsvc locsvc svc admins
//      (users = BUILTIN Users, user = the current user, logon = the logon session, auth = Authenticated Users,
//       allapp = ALL APPLICATION PACKAGES, netsvc / locsvc = NETWORK / LOCAL SERVICE, svc = SERVICE)
//      SBX_WRITE_RESTRICTED=1 sets WRITE_RESTRICTED (restricting SIDs are only checked for write access).
// Prints "sbx: child pid N" to stderr when the child starts.
// Exit code: the child's, or 120-125 if sbx itself failed (kept clear of the 0-4 the tools in this repo use):
//   120 bad arguments, 121 cannot open or duplicate the token, 122 cannot build the restricted token,
//   123 cannot lower integrity, 124 cannot create the process, 125 cannot set up the job object.
#include <windows.h>
#include <sddl.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#pragma comment(lib, "advapi32.lib")

enum { kBadArgs = 120, kTokenFailed = 121, kRestrictedFailed = 122, kIntegrityFailed = 123, kCreateFailed = 124, kJobFailed = 125 };
#define USAGE "usage: sbx <lowil|restricted|job|none>[+...] <exe> [args]"

enum { MODE_LOWIL, MODE_RESTRICTED, MODE_JOB, MODE_NONE, kModeCount };
static const char* const kModeNames[kModeCount] = { "lowil", "restricted", "job", "none" };

// The restricting SIDs SBX_RS can name. They go into the token in this order, whatever the order in the list.
enum { SID_USERS, SID_EVERYONE, SID_RESTRICTED, SID_USER, SID_LOGON, SID_AUTH, SID_INTERACTIVE, SID_SYSTEM, SID_ALLAPP, SID_NETSVC, SID_LOCSVC, SID_SVC, SID_ADMINS, kSidCount };
static const char* const kSidNames[kSidCount] = { "users", "everyone", "restricted", "user", "logon", "auth", "interactive", "system", "allapp", "netsvc", "locsvc", "svc", "admins" };
static const char* const kDefaultSids = "users,everyone,restricted,user,logon";
#define BIT(i) (1u << (i))

// Parses a list such as "lowil+job" (sep '+') or "users,auth" (sep ',') into one bit per name; says which name is unknown.
static BOOL parseList(const char* list, char sep, const char* const* names, int count, const char* what, unsigned* mask) {
    *mask = 0;
    for (const char* p = list; ; ) {
        const char* end = strchr(p, sep); size_t len = end ? (size_t)(end - p) : strlen(p);
        int i = 0; while (i < count && !(strlen(names[i]) == len && !strncmp(p, names[i], len))) i++;
        if (i == count) { printf("unknown %s '%.*s'\n", what, (int)len, p); return FALSE; }
        *mask |= BIT(i);
        if (!end) return TRUE;
        p = end + 1;
    }
}

// SBX_RS (kDefaultSids when not set) and SBX_WRITE_RESTRICTED (0 or 1).
static BOOL readEnv(unsigned* sids, BOOL* writeRestricted) {
    const char* rs = getenv("SBX_RS");
    if (!parseList(rs ? rs : kDefaultSids, ',', kSidNames, kSidCount, "SBX_RS", sids)) return FALSE;
    const char* wr = getenv("SBX_WRITE_RESTRICTED");
    if (wr && strcmp(wr, "0") && strcmp(wr, "1")) { puts("SBX_WRITE_RESTRICTED must be 0 or 1"); return FALSE; }
    *writeRestricted = wr && !strcmp(wr, "1");
    return TRUE;
}

// Appends `arg` quoted the way the C runtime and CommandLineToArgvW read it (quotes escaped, backslashes before a quote doubled).
static BOOL appendArg(char* cmd, size_t capacity, const char* arg) {
    size_t used = strlen(cmd);
    if (used + 2 * strlen(arg) + 4 >= capacity) { puts("command line too long"); return FALSE; }
    char* out = cmd + used;
    *out++ = '"';
    for (const char* p = arg; ; p++) {
        size_t backslashes = 0;
        while (*p == '\\') { backslashes++; p++; }
        if (!*p) { for (size_t i = 0; i < backslashes * 2; i++) *out++ = '\\'; break; }
        if (*p == '"') { for (size_t i = 0; i < backslashes * 2 + 1; i++) *out++ = '\\'; *out++ = '"'; }
        else { for (size_t i = 0; i < backslashes; i++) *out++ = '\\'; *out++ = *p; }
    }
    *out++ = '"'; *out++ = ' '; *out = 0;
    return TRUE;
}

// "exe arg arg". SearchPath also finds a bare name in the current folder, which CreateProcess skips when NoDefaultCurrentDirectoryInExePath is set.
static BOOL buildCommandLine(int argc, char** argv, char* cmd, size_t capacity) {
    char full[MAX_PATH]; DWORD n = SearchPathA(NULL, argv[2], ".exe", MAX_PATH, full, NULL);
    if (!appendArg(cmd, capacity, n && n < MAX_PATH ? full : argv[2])) return FALSE;
    for (int i = 3; i < argc; i++) if (!appendArg(cmd, capacity, argv[i])) return FALSE;
    return TRUE;
}

typedef struct { BYTE buf[SECURITY_MAX_SID_SIZE]; PSID sid; } SidBuf;

static void wellKnown(SidBuf* s, WELL_KNOWN_SID_TYPE type) {
    DWORD size = sizeof s->buf; s->sid = CreateWellKnownSid(type, NULL, s->buf, &size) ? s->buf : NULL;
}

// The group list is allocated once and kept for the life of this short-lived launcher.
static PSID logonSessionSid(HANDLE self) {
    DWORD size = 0; GetTokenInformation(self, TokenGroups, NULL, 0, &size);
    TOKEN_GROUPS* g = (TOKEN_GROUPS*)malloc(size);
    if (!g || !GetTokenInformation(self, TokenGroups, g, size, &size)) return NULL;
    for (DWORD i = 0; i < g->GroupCount; i++) if ((g->Groups[i].Attributes & SE_GROUP_LOGON_ID) == SE_GROUP_LOGON_ID) return g->Groups[i].Sid;
    return NULL;
}

// Restricted token derived from the process token (Windows only lets us assign such a child without extra privileges).
static HANDLE makeRestrictedToken(HANDLE self, unsigned sidMask, BOOL writeRestricted) {
    BYTE userBuf[256]; DWORD n = 0;
    GetTokenInformation(self, TokenUser, userBuf, sizeof userBuf, &n);
    SidBuf sids[kSidCount] = {0};
    wellKnown(&sids[SID_USERS], WinBuiltinUsersSid);          wellKnown(&sids[SID_EVERYONE], WinWorldSid);
    wellKnown(&sids[SID_RESTRICTED], WinRestrictedCodeSid);
    sids[SID_USER].sid = ((TOKEN_USER*)userBuf)->User.Sid;
    sids[SID_LOGON].sid = logonSessionSid(self);
    wellKnown(&sids[SID_AUTH], WinAuthenticatedUserSid);      wellKnown(&sids[SID_INTERACTIVE], WinInteractiveSid);
    wellKnown(&sids[SID_SYSTEM], WinLocalSystemSid);
    ConvertStringSidToSidA("S-1-15-2-1", &sids[SID_ALLAPP].sid);
    wellKnown(&sids[SID_NETSVC], WinNetworkServiceSid);       wellKnown(&sids[SID_LOCSVC], WinLocalServiceSid);
    wellKnown(&sids[SID_SVC], WinServiceSid);                 wellKnown(&sids[SID_ADMINS], WinBuiltinAdministratorsSid);

    SID_AND_ATTRIBUTES restricting[kSidCount]; int count = 0;
    for (int i = 0; i < kSidCount; i++) {
        if (!(sidMask & BIT(i))) continue;
        if (!sids[i].sid) { printf("cannot build the SID '%s'\n", kSidNames[i]); return NULL; }
        restricting[count].Sid = sids[i].sid; restricting[count].Attributes = 0; count++;
    }
    SID_AND_ATTRIBUTES denyAdmins = { sids[SID_ADMINS].sid, 0 };
    DWORD flags = DISABLE_MAX_PRIVILEGE; if (writeRestricted) flags |= WRITE_RESTRICTED;
    HANDLE restricted = NULL;
    if (!CreateRestrictedToken(self, flags, 1, &denyAdmins, 0, NULL, count, restricting, &restricted)) { printf("CreateRestrictedToken failed %lu\n", GetLastError()); return NULL; }
    return restricted;
}

static BOOL lowerIntegrity(HANDLE tok) {
    PSID low = NULL; ConvertStringSidToSidA("S-1-16-4096", &low);
    TOKEN_MANDATORY_LABEL tml = { { low, SE_GROUP_INTEGRITY } };
    if (!SetTokenInformation(tok, TokenIntegrityLevel, &tml, sizeof tml + GetLengthSid(low))) { printf("SetTokenInformation(integrity) failed %lu\n", GetLastError()); return FALSE; }
    return TRUE;
}

// The job handle is intentionally never closed: the job (kill-on-close) lives as long as this launcher.
static BOOL putInJob(HANDLE process) {
    HANDLE job = CreateJobObjectA(NULL, NULL);
    if (!job) { printf("CreateJobObject failed %lu\n", GetLastError()); return FALSE; }
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION li = {0}; li.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    JOBOBJECT_BASIC_UI_RESTRICTIONS ui = { JOB_OBJECT_UILIMIT_DESKTOP | JOB_OBJECT_UILIMIT_EXITWINDOWS | JOB_OBJECT_UILIMIT_GLOBALATOMS | JOB_OBJECT_UILIMIT_HANDLES | JOB_OBJECT_UILIMIT_READCLIPBOARD | JOB_OBJECT_UILIMIT_WRITECLIPBOARD | JOB_OBJECT_UILIMIT_SYSTEMPARAMETERS | JOB_OBJECT_UILIMIT_DISPLAYSETTINGS };
    if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &li, sizeof li) ||
        !SetInformationJobObject(job, JobObjectBasicUIRestrictions, &ui, sizeof ui) ||
        !AssignProcessToJobObject(job, process)) { printf("job object setup failed %lu\n", GetLastError()); return FALSE; }
    return TRUE;
}

int main(int argc, char** argv) {
    if (argc < 3) { puts(USAGE); return kBadArgs; }
    const char* modeList = argv[1]; unsigned modes = 0, sids = 0; BOOL writeRestricted = FALSE;
    if (!parseList(modeList, '+', kModeNames, kModeCount, "mode", &modes)) return kBadArgs;
    if ((modes & BIT(MODE_NONE)) && modes != BIT(MODE_NONE)) { puts("mode 'none' cannot be combined"); return kBadArgs; }
    if (!readEnv(&sids, &writeRestricted)) return kBadArgs;
    char cmd[2048] = {0};
    if (!buildCommandLine(argc, argv, cmd, sizeof cmd)) return kBadArgs;

    HANDLE self = NULL, tok = NULL;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ALL_ACCESS, &self)) { printf("OpenProcessToken failed %lu\n", GetLastError()); return kTokenFailed; }
    if (!DuplicateTokenEx(self, TOKEN_ALL_ACCESS, NULL, SecurityImpersonation, TokenPrimary, &tok)) { printf("DuplicateTokenEx failed %lu\n", GetLastError()); return kTokenFailed; }
    if (modes & BIT(MODE_RESTRICTED)) { HANDLE r = makeRestrictedToken(self, sids, writeRestricted); if (!r) return kRestrictedFailed; CloseHandle(tok); tok = r; }
    if ((modes & BIT(MODE_LOWIL)) && !lowerIntegrity(tok)) return kIntegrityFailed;

    STARTUPINFOA si = { sizeof si }; PROCESS_INFORMATION pi = {0};
    BOOL ok = (modes & BIT(MODE_NONE)) ? CreateProcessA(NULL, cmd, NULL, NULL, TRUE, CREATE_SUSPENDED, NULL, NULL, &si, &pi)
                                          : CreateProcessAsUserA(tok, NULL, cmd, NULL, NULL, TRUE, CREATE_SUSPENDED, NULL, NULL, &si, &pi);
    if (!ok) { printf("CreateProcess failed %lu\n", GetLastError()); return kCreateFailed; }
    fprintf(stderr, "sbx: child pid %lu\n", pi.dwProcessId); fflush(stderr);
    if ((modes & BIT(MODE_JOB)) && !putInJob(pi.hProcess)) { TerminateProcess(pi.hProcess, kJobFailed); return kJobFailed; }
    ResumeThread(pi.hThread);
    WaitForSingleObject(pi.hProcess, INFINITE);

    DWORD code = 0; GetExitCodeProcess(pi.hProcess, &code);
    printf("sbx[%s] child pid %lu exited with %lu\n", modeList, pi.dwProcessId, code);
    return (int)code;
}
