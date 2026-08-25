/*
 * Whisky Steam helper.
 *
 * The macOS Steam client launches a Windows game through Whisky's
 * compatibility tool. `lsteamclient` carries the Steamworks calls out to the
 * native client, but a game asks several things that never go through that API
 * and that nothing inside a Wine prefix answers:
 *
 *   - is the process in HKCU\Software\Valve\Steam\ActiveProcess\pid alive?
 *     (SteamAPI_IsSteamRunning opens it)
 *   - is there a window of class vguiPopupWindow? (the classic FindWindow test)
 *   - what is SteamPath, and what is ValvePlatformMutex?
 *   - does anything answer the DRM start handshake?
 *
 * On Linux all of it comes from Proton's steam.exe stub, which the game runs as
 * a child of. This is the same shape: it holds the presence open, seeds the
 * environment, then launches the game and lives exactly as long as it does. The
 * contract is Valve's; Proton's steam_helper is where it is written down.
 *
 * Usage:
 *   WhiskySteamHelper.exe [--workdir <dir>] [--exec <program> [args...]]
 *
 * With no --exec it holds the presence open and nothing else.
 */

#include <windows.h>
#include <winternl.h>
#include <shellapi.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define STEAM_DIR L"C:\\Program Files (x86)\\Steam"
#define ARRAY_LENGTH(x) (sizeof(x) / sizeof((x)[0]))

#ifndef DIRECTORY_QUERY
#define DIRECTORY_QUERY 0x0001
#endif

/*
 * How long to give each half of the setup before starting the game anyway.
 * Both are answers a game wants and neither is worth never launching over.
 */
#define PRESENCE_TIMEOUT_MS 5000
#define REGISTRY_TIMEOUT_MS 5000

typedef struct
{
    UNICODE_STRING name;
    UNICODE_STRING type;
} directory_entry;

static WCHAR *(WINAPI *p_wine_get_dos_file_name)(const char *);
static NTSTATUS (WINAPI *p_NtOpenDirectoryObject)(HANDLE *, ACCESS_MASK, OBJECT_ATTRIBUTES *);
static NTSTATUS (WINAPI *p_NtQueryDirectoryObject)(HANDLE, void *, ULONG, BOOLEAN, BOOLEAN,
                                                   ULONG *, ULONG *);

/* Set once the windows a game looks for exist. */
static HANDLE presence_ready;

static void resolve_imports(void)
{
    HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    HMODULE kernel32 = GetModuleHandleW(L"kernel32.dll");

    p_wine_get_dos_file_name = (void *)GetProcAddress(kernel32, "wine_get_dos_file_name");
    p_NtOpenDirectoryObject = (void *)GetProcAddress(ntdll, "NtOpenDirectoryObject");
    p_NtQueryDirectoryObject = (void *)GetProcAddress(ntdll, "NtQueryDirectoryObject");
}

/* ---------------------------------------------------------------- presence */

static DWORD WINAPI window_thread(void *arg)
{
    WNDCLASSEXW window_class = { 0 };
    MSG message;

    (void)arg;

    /* Realise the desktop on this thread before the first window, so creating
     * it does not race the desktop coming up. */
    GetDesktopWindow();

    window_class.cbSize = sizeof(window_class);
    window_class.lpfnWndProc = DefWindowProcW;
    window_class.lpszClassName = L"vguiPopupWindow";
    RegisterClassExW(&window_class);
    CreateWindowW(window_class.lpszClassName, L"Steam", WS_POPUP, 40, 40, 400, 300,
                  NULL, NULL, NULL, NULL);
    CreateWindowA("static", "SteamVR Status", WS_POPUP, 0, 0, 0, 0, NULL, NULL, NULL, NULL);
    SetEvent(presence_ready);

    while (GetMessageW(&message, NULL, 0, 0))
    {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    return 0;
}

static void register_active_process(void)
{
    DWORD pid = GetCurrentProcessId();

    RegSetKeyValueW(HKEY_CURRENT_USER, L"Software\\Valve\\Steam\\ActiveProcess", L"pid",
                    REG_DWORD, &pid, sizeof(pid));
}

/*
 * XBox Game Studios titles run GamingRepair.exe until a registry value says it
 * has already succeeded. It never can here, and the attempt costs about twenty
 * seconds of the game looking hung before its window opens.
 */
static void set_gaming_repair_succeeded(const char *app_id)
{
    HKEY apps, app;
    DWORD succeeded = 1;

    if (!app_id || !*app_id) return;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Valve\\Steam\\Apps", 0,
                      KEY_ALL_ACCESS | KEY_WOW64_32KEY, &apps))
        return;

    if (!RegOpenKeyExA(apps, app_id, 0, KEY_ALL_ACCESS, &app))
    {
        RegSetValueExW(app, L"GamingRepair", 0, REG_DWORD, (BYTE *)&succeeded, sizeof(succeeded));
        RegCloseKey(app);
    }
    RegCloseKey(apps);
}

/*
 * lsteamclient knows the answers a game reads out of the registry: the client's
 * UI language, and whether this app is installed and running. It fills them in
 * from the live client through an export nothing else calls, so this is where
 * it gets asked. It needs the native client up, and returns quietly when it is
 * not.
 */
static void init_steamclient_registry(void)
{
    void (__cdecl *init)(void);
    HMODULE lsteamclient;

    /* Without this the bridge cannot find the client's library, and asking it
     * to connect anyway does not fail, it waits. */
    if (!GetEnvironmentVariableA("STEAM_COMPAT_CLIENT_INSTALL_PATH", NULL, 0)) return;

    if (!(lsteamclient = LoadLibraryW(L"lsteamclient"))) return;
    if ((init = (void *)GetProcAddress(lsteamclient, "steamclient_init_registry"))) init();
    FreeLibrary(lsteamclient);
}

/* Both talk to the client, which is a round trip and occasionally a stall. */
static DWORD WINAPI registry_thread(void *arg)
{
    set_gaming_repair_succeeded((const char *)arg);
    init_steamclient_registry();
    return 0;
}

/*
 * Proton's stub exports both of these and a game reads them because it is a
 * child of the stub. That is the reason this launches the game rather than
 * running beside it.
 */
static void export_steam_environment(void)
{
    WCHAR path[MAX_PATH], *p;

    SetEnvironmentVariableW(L"SteamPath", STEAM_DIR);

    *path = 0;
    GetModuleFileNameW(NULL, path, ARRAY_LENGTH(path));
    for (p = path; *p; ++p) if (*p == '\\') *p = '/';
    SetEnvironmentVariableW(L"ValvePlatformMutex", path);
}

/* --------------------------------------------------------------------- drm */

/*
 * Steam's DRM wrapper hands a request to the client and waits to be told the
 * app started. The event it waits on is named per session, so the only way to
 * reach it is to walk the prefix's object directory for it.
 */
static HANDLE find_ack_event(void)
{
    static const WCHAR *const directories[] =
    {
        L"\\BaseNamedObjects\\Session\\1",
        L"\\BaseNamedObjects"
    };
    static const WCHAR prefix[] = L"STEAM_START_ACK_EVENT";
    const size_t prefix_length = ARRAY_LENGTH(prefix) - 1;
    char buffer[1024];
    unsigned int i;

    if (!p_NtOpenDirectoryObject || !p_NtQueryDirectoryObject) return NULL;

    for (i = 0; i < ARRAY_LENGTH(directories); ++i)
    {
        directory_entry *entry = (directory_entry *)buffer;
        OBJECT_ATTRIBUTES attributes = { 0 };
        UNICODE_STRING name;
        ULONG context = 0, size;
        HANDLE directory;
        BOOLEAN restart;

        name.Buffer = (WCHAR *)directories[i];
        name.Length = (USHORT)(wcslen(directories[i]) * sizeof(WCHAR));
        name.MaximumLength = name.Length + sizeof(WCHAR);

        attributes.Length = sizeof(attributes);
        attributes.ObjectName = &name;

        if (p_NtOpenDirectoryObject(&directory, DIRECTORY_QUERY, &attributes)) continue;

        for (restart = TRUE;
             !p_NtQueryDirectoryObject(directory, buffer, sizeof(buffer), TRUE, restart,
                                       &context, &size);
             restart = FALSE)
        {
            if (entry->name.Length < prefix_length * sizeof(WCHAR)) continue;
            if (wcsncmp(entry->name.Buffer, prefix, prefix_length)) continue;

            CloseHandle(directory);
            return OpenEventW(SYNCHRONIZE | EVENT_MODIFY_STATE, FALSE, entry->name.Buffer);
        }
        CloseHandle(directory);
    }
    return NULL;
}

static DWORD WINAPI drm_thread(void *arg)
{
    HANDLE consume, produce, ack = NULL;

    (void)arg;

    consume = CreateSemaphoreW(NULL, 0, 512, L"STEAM_DIPC_CONSUME");
    /* Valve's own spelling. Matching it is the point. */
    produce = CreateSemaphoreW(NULL, 1, 512, L"SREAM_DIPC_PRODUCE");
    if (!consume || !produce)
    {
        if (consume) CloseHandle(consume);
        if (produce) CloseHandle(produce);
        return 1;
    }

    while (WaitForSingleObject(consume, INFINITE) == WAIT_OBJECT_0)
    {
        if (!ack) ack = find_ack_event();
        if (ack) SetEvent(ack);
        ReleaseSemaphore(produce, 1, NULL);
    }
    return 0;
}

/* ------------------------------------------------------------------ launch */

/* A path Steam gave us is a macOS path. Everything Windows-side needs a DOS
 * path, and only Wine can say which drive reaches it. */
static WCHAR *to_dos_path(const WCHAR *path)
{
    WCHAR *dos;
    char *utf8;
    int length;

    if (path[0] != '/' || !p_wine_get_dos_file_name) return _wcsdup(path);

    length = WideCharToMultiByte(CP_UTF8, 0, path, -1, NULL, 0, NULL, NULL);
    if (!length || !(utf8 = malloc(length))) return _wcsdup(path);
    WideCharToMultiByte(CP_UTF8, 0, path, -1, utf8, length, NULL, NULL);

    dos = p_wine_get_dos_file_name(utf8);
    free(utf8);
    return dos ? dos : _wcsdup(path);
}

/* Wine's CRT split the command line for us, so putting it back together has to
 * use the same rules or an argument with a space in it arrives as two. */
static void append_quoted(WCHAR *out, size_t *pos, const WCHAR *arg)
{
    size_t backslashes = 0, i, n;

    if (*arg && !wcspbrk(arg, L" \t\""))
    {
        for (i = 0; arg[i]; ++i) out[(*pos)++] = arg[i];
        return;
    }

    out[(*pos)++] = '"';
    for (i = 0; arg[i]; ++i)
    {
        if (arg[i] == '\\') { ++backslashes; continue; }

        /* Backslashes are only special in front of a quote, where each has to
         * be doubled and the quote itself escaped. */
        n = arg[i] == '"' ? backslashes * 2 + 1 : backslashes;
        while (n--) out[(*pos)++] = '\\';

        backslashes = 0;
        out[(*pos)++] = arg[i];
    }
    /* The closing quote counts as one to escape against. */
    n = backslashes * 2;
    while (n--) out[(*pos)++] = '\\';
    out[(*pos)++] = '"';
}

/* Worst case per argument: every character doubled, plus both quotes. */
static size_t quoted_size(const WCHAR *arg)
{
    return wcslen(arg) * 2 + 3;
}

static WCHAR *build_command_line(const WCHAR *program, int argc, WCHAR **argv)
{
    size_t size = program ? quoted_size(program) : 0, pos = 0;
    WCHAR *line;
    int i;

    for (i = 0; i < argc; ++i) size += quoted_size(argv[i]) + 1;
    if (!(line = malloc((size + 1) * sizeof(*line)))) return NULL;

    if (program) append_quoted(line, &pos, program);
    for (i = 0; i < argc; ++i)
    {
        if (pos) line[pos++] = ' ';
        append_quoted(line, &pos, argv[i]);
    }
    line[pos] = 0;
    return line;
}

/* Steam hands some titles a launcher URL rather than an executable, and those
 * have to go through the shell the way the real client runs them. */
static BOOL is_executable(const WCHAR *program)
{
    size_t length = wcslen(program);

    return length >= 4 && !_wcsicmp(program + length - 4, L".exe");
}

/*
 * Returns the child's handle, or NULL with `awaited` saying whether there is
 * anything to wait on. `launched` reports whether the target started at all:
 * a shell-handled launcher URL leaves nothing to wait on but has still
 * succeeded, and the helper's exit code must not call it a failure.
 */
static HANDLE start_child(const WCHAR *program, int argc, WCHAR **argv,
                          const WCHAR *workdir, BOOL *awaited, BOOL *launched)
{
    STARTUPINFOW startup = { 0 };
    PROCESS_INFORMATION process;
    WCHAR *command_line;

    startup.cb = sizeof(startup);
    *awaited = FALSE;
    *launched = FALSE;

    if (!is_executable(program))
    {
        WCHAR *parameters = argc > 0 ? build_command_line(NULL, argc, argv) : NULL;
        HINSTANCE shell = ShellExecuteW(NULL, L"open", program, parameters, workdir, SW_SHOWNORMAL);

        free(parameters);
        /* Success is any value above 32; the rest of the range is an error
         * code wearing an HINSTANCE for 16-bit reasons. */
        *launched = (INT_PTR)shell > 32;
        return NULL;
    }

    if (!(command_line = build_command_line(program, argc, argv))) return NULL;

    if (!CreateProcessW(NULL, command_line, NULL, NULL, FALSE, CREATE_UNICODE_ENVIRONMENT,
                        NULL, workdir, &startup, &process))
    {
        free(command_line);
        return NULL;
    }
    free(command_line);
    CloseHandle(process.hThread);
    *awaited = TRUE;
    *launched = TRUE;
    return process.hProcess;
}

/* -------------------------------------------------------------------- main */

static void hold_presence_forever(void)
{
    MSG message;

    while (GetMessageW(&message, NULL, 0, 0))
    {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, PWSTR command_line, int show)
{
    WCHAR *program = NULL, *workdir = NULL, **argv;
    HANDLE presence, child, restart = NULL;
    char app_id[64] = { 0 };
    int argc = 0, i, first = 0;
    BOOL awaited = FALSE;
    BOOL launched = FALSE;
    DWORD code = 0;

    (void)instance; (void)previous; (void)command_line; (void)show;

    resolve_imports();

    if ((argv = CommandLineToArgvW(GetCommandLineW(), &argc)))
    {
        for (i = 1; i < argc; ++i)
        {
            if (!wcscmp(argv[i], L"--workdir") && i + 1 < argc)
            {
                workdir = to_dos_path(argv[++i]);
            }
            else if (!wcscmp(argv[i], L"--exec") && i + 1 < argc)
            {
                program = to_dos_path(argv[i + 1]);
                first = i + 2;
                break;
            }
        }
    }

    /* One helper per prefix owns the presence. A second one launches its game
     * and leaves the answers already on file alone. Named for this helper and
     * not for the one Whisky shipped before it, so that a leftover copy of the
     * older one does not stop this from replacing the process id it left. */
    presence = CreateMutexW(NULL, TRUE, L"WhiskySteamHelper");
    if (presence && GetLastError() != ERROR_ALREADY_EXISTS)
    {
        HANDLE registry;

        CreateEventW(NULL, FALSE, FALSE, L"Steam3Master_SharedMemLock");
        CreateEventW(NULL, FALSE, FALSE, L"Global\\Valve_SteamIPC_Class");

        presence_ready = CreateEventW(NULL, TRUE, FALSE, NULL);
        CreateThread(NULL, 0, window_thread, NULL, 0, NULL);

        if (!GetEnvironmentVariableA("SteamGameId", app_id, sizeof(app_id)))
            GetEnvironmentVariableA("SteamAppId", app_id, sizeof(app_id));
        registry = CreateThread(NULL, 0, registry_thread, app_id, 0, NULL);

        /* The first window in a prefix brings the desktop up with it, which
         * takes about a second here. A game that asks for Steam's window inside
         * that second decides Steam is absent, and does not ask again. */
        WaitForSingleObject(presence_ready, PRESENCE_TIMEOUT_MS);

        /* After the windows, so nothing points a game at this process before
         * the things it will look for exist. */
        register_active_process();

        if (registry)
        {
            WaitForSingleObject(registry, REGISTRY_TIMEOUT_MS);
            CloseHandle(registry);
        }
    }

    if (!program)
    {
        hold_presence_forever();
        return 0;
    }

    export_steam_environment();

    child = start_child(program, argc - first, argv + first, workdir, &awaited, &launched);
    if (!awaited) return launched ? 0 : 1;

    CreateThread(NULL, 0, drm_thread, NULL, 0, NULL);

    /* A game that asks Steam to relaunch it signals this rather than starting a
     * second copy of itself. */
    restart = CreateEventW(NULL, FALSE, FALSE, L"PROTON_STEAM_EXE_RESTART_APP");

    /*
     * Proton's stub waits here on the event `ProcessWineMakeProcessSystem` hands
     * back, which fires once every non-system process in the prefix has gone.
     * That is wrong for a bottle: Whisky's prefixes host launchers, the Windows
     * Steam client and whatever else the user has running, none of which are
     * this game and any of which would hold the session open forever. Waiting on
     * the game is the answer to what Steam asked.
     */
    for (;;)
    {
        HANDLE waits[2] = { child, restart };
        DWORD ret = WaitForMultipleObjects(restart ? 2 : 1, waits, FALSE, INFINITE);

        if (ret != WAIT_OBJECT_0 + 1) break;
        /* The restart is only honoured once the game it would replace is gone. */
        if (WaitForSingleObject(child, 0) == WAIT_TIMEOUT) continue;

        CloseHandle(child);
        child = start_child(program, argc - first, argv + first, workdir, &awaited, &launched);
        if (!awaited) break;
    }

    if (child)
    {
        GetExitCodeProcess(child, &code);
        CloseHandle(child);
    }
    if (restart) CloseHandle(restart);
    return code;
}
