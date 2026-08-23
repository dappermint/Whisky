# Steam presence helper

Makes Steam look present *inside* a bottle, so a Windows game launched by the
native macOS Steam client will talk to it.

`make install` builds `WhiskySteamPresence.exe` and drops it into
`WhiskyKit/Sources/WhiskyKit/Steam/Resources/`, where it ships as a bundle
resource. The built binary is committed: Xcode builds do not run `make`, and CI
has no MinGW. Rebuild and commit both together whenever `presence.c` changes.

```
brew install mingw-w64   # provides x86_64-w64-mingw32-gcc
make install
```

## Why a bridge is not enough

`lsteamclient` lets a game reach the real client, and a game that asks whether
Steam is *running* never gets as far as using it. Two checks decide that, and
neither goes through the Steamworks API:

- `SteamAPI_IsSteamRunning` opens the process id in
  `HKCU\Software\Valve\Steam\ActiveProcess\pid`. A bottle that once had the
  Windows client installed still holds that client's long-dead pid.
- `FindWindow` for the class `vguiPopupWindow`, the window Steam's own UI
  registers.

On Linux both answers come from Proton's `steam.exe` stub, which the game runs
as a child of. macOS Steam sits outside the prefix and registers neither, so a
game that checks decides Steam is absent. The signature in a
`WINEDEBUG=+steamclient` trace is a game that creates its interfaces, reads its
Steam ID, then spins `RunFrame` without ever calling `GetAuthSessionTicket`.

This process answers both for the length of the session, plus the two named
events (`Steam3Master_SharedMemLock` and `Global\Valve_SteamIPC_Class`) the same
stub creates. It writes no files and installs nothing, so turning it off leaves
a prefix untouched.

Proton's stub also sets `SteamPath` and `ValvePlatformMutex`. Those reach a game
only by environment inheritance from a parent, which does not apply here, so
they are left out rather than half-implemented.
