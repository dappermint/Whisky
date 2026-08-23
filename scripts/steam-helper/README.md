# Steam helper

Stands in for the Steam client *inside* a bottle, so a Windows game the native
macOS client launched behaves as if it were running under a real one.

`make install` builds `WhiskySteamHelper.exe` and drops it into
`WhiskyKit/Sources/WhiskyKit/Steam/Resources/`, where it ships as a bundle
resource. The built binary is committed: Xcode builds do not run `make`, and CI
has no MinGW. Rebuild and commit both together whenever `helper.c` changes.

```
brew install mingw-w64   # provides x86_64-w64-mingw32-gcc
make install
```

## Why a bridge is not enough

`lsteamclient` lets a game reach the real client. A game that first asks whether
Steam is *running* never gets that far, and several of the things it asks never
go through the Steamworks API at all:

- `SteamAPI_IsSteamRunning` opens the process id in
  `HKCU\Software\Valve\Steam\ActiveProcess\pid`. A bottle that once had the
  Windows client installed still holds that client's long-dead pid.
- `FindWindow` for the class `vguiPopupWindow`, the window Steam's UI registers.
- `SteamPath` and `ValvePlatformMutex`, read from the environment.
- Steam's DRM wrapper hands a request to the client over a pair of named
  semaphores and waits to be told the app started.

On Linux all of it comes from Proton's `steam.exe` stub, which the game runs as
a child of. The signature of missing it in a `WINEDEBUG=+steamclient` trace is a
game that creates its interfaces, reads its Steam ID, then spins `RunFrame`
without ever calling `GetAuthSessionTicket`.

## What it does

```
WhiskySteamHelper.exe [--workdir <dir>] [--exec <program> [args...]]
```

Being the game's parent is the point: the environment it sets is inherited, and
it lives exactly as long as the game does, so the prefix is not left holding a
process after the session ends.

| | |
|---|---|
| `ActiveProcess\pid` | its own, written last so nothing arrives early |
| `vguiPopupWindow` + `SteamVR Status` windows | on their own thread |
| `Steam3Master_SharedMemLock`, `Global\Valve_SteamIPC_Class` | named events |
| `SteamPath`, `ValvePlatformMutex` | environment, inherited by the game |
| `Apps\<id>\GamingRepair` | set, or XBox Game Studios titles stall ~20s |
| `Software\Valve\Steam\language`, `Apps\<id>\Installed`/`Running` | filled in by `lsteamclient`'s `steamclient_init_registry` |
| `STEAM_DIPC_CONSUME` / `SREAM_DIPC_PRODUCE` | the DRM start handshake |
| `PROTON_STEAM_EXE_RESTART_APP` | relaunches the game in place |
| non-`.exe` targets | go through `ShellExecute`, the way launcher URLs need |

Only the first helper in a prefix takes the presence; a second one launches its
game and leaves the answers already on file alone.

Whisky runs it with `--workdir` set to the install root, because Steam runs a
game from there and not from wherever the executable sits inside it. Paths may
be macOS paths: it converts them itself, which is what Steam passes.
