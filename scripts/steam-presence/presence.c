/*
 * Whisky Steam presence helper.
 *
 * A Windows game asks two questions before it will talk to Steam, and neither
 * of them goes through the Steamworks API, so a working lsteamclient bridge
 * does not answer either one:
 *
 *   - is the process named by HKCU\Software\Valve\Steam\ActiveProcess\pid
 *     still alive? (SteamAPI_IsSteamRunning opens it)
 *   - is there a window of class vguiPopupWindow? (the classic FindWindow test)
 *
 * On Linux the answers come from Proton's steam.exe stub, which the game runs
 * as a child of. macOS Steam is outside the prefix and never registers either,
 * so a game that checks decides Steam is absent and stops before it requests
 * an auth ticket. This holds both answers open for the length of the session.
 *
 * Proton's stub also exports SteamPath and ValvePlatformMutex. Those reach a
 * game only because it inherits the stub's environment, which does not apply
 * here, so they are deliberately left out.
 */

#include <windows.h>

static void register_active_process(void)
{
    DWORD pid = GetCurrentProcessId();

    RegSetKeyValueW(HKEY_CURRENT_USER, L"Software\\Valve\\Steam\\ActiveProcess", L"pid",
                    REG_DWORD, &pid, sizeof(pid));
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, PWSTR command_line, int show)
{
    WNDCLASSEXW window_class = { 0 };
    HANDLE single_instance;
    MSG message;

    (void)instance; (void)previous; (void)command_line; (void)show;

    single_instance = CreateMutexW(NULL, TRUE, L"WhiskySteamPresence");
    if (!single_instance || GetLastError() == ERROR_ALREADY_EXISTS)
        return 0;

    CreateEventW(NULL, FALSE, FALSE, L"Steam3Master_SharedMemLock");
    CreateEventW(NULL, FALSE, FALSE, L"Global\\Valve_SteamIPC_Class");

    /* Realise the desktop on this thread before any window is created, the
     * way Proton's stub does, so the first CreateWindow does not race it. */
    GetDesktopWindow();

    window_class.cbSize = sizeof(window_class);
    window_class.lpfnWndProc = DefWindowProcW;
    window_class.lpszClassName = L"vguiPopupWindow";
    RegisterClassExW(&window_class);
    CreateWindowW(window_class.lpszClassName, L"Steam", WS_POPUP, 40, 40, 400, 300,
                  NULL, NULL, NULL, NULL);
    CreateWindowA("static", "SteamVR Status", WS_POPUP, 0, 0, 0, 0, NULL, NULL, NULL, NULL);

    /* Last, so nothing points a game at this process before the windows and
     * events it will look for exist. */
    register_active_process();

    while (GetMessageW(&message, NULL, 0, 0))
    {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }

    return 0;
}
