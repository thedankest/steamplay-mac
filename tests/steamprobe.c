/* steamprobe: does Steamworks reach the real Steam client through lsteamclient?
 *
 * Loads steam_api64.dll (x64) or steam_api.dll (i386) from the current directory (copy one
 * from a game; Valve's file, never committed), initialises it for SteamAppId (default 480,
 * Spacewar) and asks the client a few things. Run it through the steam.exe shim, as a game
 * would be. Prints the SteamID only as "set"/"zero": it identifies the user's account.
 * Exit code 0 = SteamAPI init succeeded and a user handle came back. With STEAMPROBE_LOG set,
 * output goes to that file (the shim starts the game without our stdout). */
#include <windows.h>
#include <stdio.h>
#include <stdint.h>

#ifdef _WIN64
#define API_DLL "steam_api64.dll"
#else
#define API_DLL "steam_api.dll"
#endif

typedef int (__cdecl *bool_fn)(void);
typedef int (__cdecl *initflat_fn)(char *err);
typedef int32_t (__cdecl *int_fn)(void);
typedef void *(__cdecl *ptr_fn)(void);
typedef uint64_t (__cdecl *u64_obj_fn)(void *);
typedef int (__cdecl *bool_obj_fn)(void *);
typedef uint32_t (__cdecl *u32_obj_fn)(void *);
typedef void (__cdecl *void_fn)(void);

static void *first_export(HMODULE m, const char *const *names, const char **found)
{
    for (; *names; names++)
    {
        void *p = (void *)GetProcAddress(m, *names);
        if (p) { if (found) *found = *names; return p; }
    }
    return NULL;
}

int main(void)
{
    static const char *const users[] = {"SteamAPI_SteamUser_v023", "SteamAPI_SteamUser_v022",
        "SteamAPI_SteamUser_v021", "SteamAPI_SteamUser_v020", NULL};
    static const char *const utils[] = {"SteamAPI_SteamUtils_v010", "SteamAPI_SteamUtils_v009", NULL};
    char appid[16], err[1024] = "";
    const char *how = NULL;
    HMODULE api, lsc;
    int ok = 0, hu = -1;
    int_fn hpipe, huser;
    void_fn shutdown;

    if (GetEnvironmentVariableA("STEAMPROBE_LOG", err, sizeof(err)) && !freopen(err, "w", stdout))
        return 3;
    setvbuf(stdout, NULL, _IONBF, 0);
    err[0] = 0;

    if (!GetEnvironmentVariableA("SteamAppId", appid, sizeof(appid)))
    {
        SetEnvironmentVariableA("SteamAppId", "480");
        SetEnvironmentVariableA("SteamGameId", "480");
        strcpy(appid, "480");
    }
    printf("steamprobe %s: SteamAppId=%s\n", sizeof(void *) == 8 ? "x64" : "i386", appid);

    if (!(api = LoadLibraryA(API_DLL)))
    {
        printf("FAIL: LoadLibrary(%s) error %lu\n", API_DLL, GetLastError());
        return 2;
    }

    if (GetProcAddress(api, "SteamAPI_Init"))
    {
        how = "SteamAPI_Init";
        ok = ((bool_fn)GetProcAddress(api, "SteamAPI_Init"))();
    }
    else if (GetProcAddress(api, "SteamAPI_InitFlat"))
    {
        how = "SteamAPI_InitFlat";
        ok = ((initflat_fn)GetProcAddress(api, "SteamAPI_InitFlat"))(err) == 0;
    }
    printf("%s: %s%s%s\n", how ? how : "no init export", ok ? "ok" : "FAILED", *err ? " - " : "", err);

    lsc = GetModuleHandleA("lsteamclient.dll");
    printf("lsteamclient.dll loaded: %s\n", lsc ? "yes" : "no");
    if (!ok) return 1;

    hpipe = (int_fn)GetProcAddress(api, "SteamAPI_GetHSteamPipe");
    huser = (int_fn)GetProcAddress(api, "SteamAPI_GetHSteamUser");
    if (huser) hu = huser();
    printf("HSteamPipe %d, HSteamUser %d\n", hpipe ? hpipe() : -1, hu);
    if (GetProcAddress(api, "SteamAPI_IsSteamRunning"))
        printf("IsSteamRunning %d\n", ((bool_fn)GetProcAddress(api, "SteamAPI_IsSteamRunning"))());

    {
        const char *n = NULL;
        ptr_fn get_user = (ptr_fn)first_export(api, users, &n);
        u64_obj_fn get_id = (u64_obj_fn)GetProcAddress(api, "SteamAPI_ISteamUser_GetSteamID");
        bool_obj_fn logged = (bool_obj_fn)GetProcAddress(api, "SteamAPI_ISteamUser_BLoggedOn");
        void *user = get_user ? get_user() : NULL;
        if (user && get_id && logged)
        {
            uint64_t id = get_id(user);
            printf("%s: BLoggedOn %d, SteamID %s (universe %u, type %u)\n", n, logged(user),
                   id ? "set" : "zero", (unsigned)(id >> 56), (unsigned)((id >> 52) & 0xf));
        }
        else printf("ISteamUser: no flat accessor in this steam_api (old SDK)\n");
    }
    {
        const char *n = NULL;
        ptr_fn get_utils = (ptr_fn)first_export(api, utils, &n);
        u32_obj_fn get_app = (u32_obj_fn)GetProcAddress(api, "SteamAPI_ISteamUtils_GetAppID");
        void *u = get_utils ? get_utils() : NULL;
        if (u && get_app) printf("%s: GetAppID %u\n", n, get_app(u));
    }

    if ((shutdown = (void_fn)GetProcAddress(api, "SteamAPI_Shutdown"))) shutdown();
    printf("%s\n", hu > 0 ? "PASS" : "FAIL: no user handle");
    return hu > 0 ? 0 : 1;
}
