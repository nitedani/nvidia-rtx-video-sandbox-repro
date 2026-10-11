// wvt.exe <file> : check a file's signature with WinVerifyTrust, the way a loader or driver would before trusting a module.
// Two checks: the catalog signature (how driver-store files are signed) and the embedded Authenticode signature.
// Both use the same flags (no UI, no revocation, cache-only URL retrieval).
// Exit code: 0 both TRUSTED, 4 at least one is not, 2 the file cannot be opened, 1 usage.
// A file with no catalog fails the catalog check even if its embedded signature is fine: read both lines.
#include <windows.h>
#include <wintrust.h>
#include <softpub.h>
#include <mscat.h>
#include <stdio.h>
#include <stdlib.h>
#pragma comment(lib, "wintrust.lib")
#pragma comment(lib, "crypt32.lib")

// Verifies with the flags both checks share (no UI, no revocation, cache-only URL retrieval), then closes the trust state.
// The caller sets the union choice and its data.
static LONG verify(WINTRUST_DATA* wd) {
    GUID action = WINTRUST_ACTION_GENERIC_VERIFY_V2;
    wd->dwUIChoice = WTD_UI_NONE; wd->fdwRevocationChecks = WTD_REVOKE_NONE;
    wd->dwStateAction = WTD_STATEACTION_VERIFY; wd->dwProvFlags = WTD_CACHE_ONLY_URL_RETRIEVAL;
    LONG r = WinVerifyTrust(NULL, &action, wd);
    wd->dwStateAction = WTD_STATEACTION_CLOSE; WinVerifyTrust(NULL, &action, wd);
    return r;
}

static BOOL verifyCatalog(HANDLE file, const wchar_t* path) {
    BOOL trusted = FALSE;
    HCATADMIN admin = NULL;
    if (!CryptCATAdminAcquireContext(&admin, NULL, 0)) { printf("CryptCATAdminAcquireContext FAILED, GetLastError=%lu (0x%08lx)\n", GetLastError(), GetLastError()); return FALSE; }
    DWORD hashLen = 0; CryptCATAdminCalcHashFromFileHandle(file, &hashLen, NULL, 0);
    BYTE* hash = (BYTE*)malloc(hashLen);
    if (!hash || !CryptCATAdminCalcHashFromFileHandle(file, &hashLen, hash, 0)) {
        printf("calc hash failed %lu\n", GetLastError()); free(hash); CryptCATAdminReleaseContext(admin, 0); return FALSE;
    }
    HCATINFO catalog = CryptCATAdminEnumCatalogFromHash(admin, hash, hashLen, 0, NULL);
    if (!catalog) printf("catalog lookup: no catalog found for this hash (GetLastError=%lu / 0x%08lx)\n", GetLastError(), GetLastError());
    else {
        CATALOG_INFO info = { sizeof info }; CryptCATCatalogInfoFromContext(catalog, &info, 0);
        wchar_t tag[200] = L""; for (DWORD i = 0; i < hashLen && i < 64; i++) swprintf(tag + wcslen(tag), 4, L"%02X", hash[i]);
        WINTRUST_CATALOG_INFO wci = { sizeof wci }; wci.pcwszCatalogFilePath = info.wszCatalogFile; wci.pcwszMemberTag = tag; wci.pcwszMemberFilePath = path;
        wci.hMemberFile = file; wci.pbCalculatedFileHash = hash; wci.cbCalculatedFileHash = hashLen; wci.hCatAdmin = admin;
        WINTRUST_DATA wd = { sizeof wd }; wd.dwUnionChoice = WTD_CHOICE_CATALOG; wd.pCatalog = &wci;
        LONG r = verify(&wd);
        trusted = r == 0;
        printf("WinVerifyTrust (catalog %ls) -> 0x%08lx %s\n", info.wszCatalogFile, (unsigned long)r, trusted ? "TRUSTED" : "NOT TRUSTED");
        CryptCATAdminReleaseCatalogContext(admin, catalog, 0);
    }
    free(hash);
    CryptCATAdminReleaseContext(admin, 0);
    return trusted;
}

static BOOL verifyEmbedded(HANDLE file, const wchar_t* path) {
    WINTRUST_FILE_INFO fi = { sizeof fi }; fi.pcwszFilePath = path; fi.hFile = file;
    WINTRUST_DATA wd = { sizeof wd }; wd.dwUnionChoice = WTD_CHOICE_FILE; wd.pFile = &fi;
    LONG r = verify(&wd);
    printf("WinVerifyTrust (embedded signature)  -> 0x%08lx %s\n", (unsigned long)r, r == 0 ? "TRUSTED" : "NOT TRUSTED");
    return r == 0;
}

int wmain(int argc, wchar_t** argv) {
    if (argc < 2) { puts("usage: wvt <file>"); return 1; }
    HANDLE file = CreateFileW(argv[1], GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    if (file == INVALID_HANDLE_VALUE) { printf("CreateFile failed %lu\n", GetLastError()); return 2; }
    BOOL catalogOk = verifyCatalog(file, argv[1]);
    BOOL embeddedOk = verifyEmbedded(file, argv[1]);
    CloseHandle(file);
    return catalogOk && embeddedOk ? 0 : 4;
}
