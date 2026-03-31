# WSL Docker Wrapper Setup

This repository provides a PowerShell setup script for running **Docker Engine inside Ubuntu on WSL 2** while exposing a near-native `docker` command on Windows.

It does **not** install Docker Desktop.

## What the script does

The setup script:

- checks whether `wsl.exe` is available
- checks whether the target WSL distro exists
- converts the distro to **WSL 2** if needed
- verifies that the distro is ready for non-interactive use
- checks whether Docker Engine is already installed inside WSL
- installs Docker Engine and the Compose plugin inside Ubuntu if missing
- adds the default Linux user to the `docker` group
- writes PowerShell wrapper functions so `docker ...` works from Windows
- optionally writes `docker.cmd` and `docker-compose.cmd` shims for `cmd.exe`, IDE terminals, and tools that expect `docker` on `PATH`

The wrappers auto-start `dockerd` inside WSL on demand, without requiring `systemd`, and the Windows shim waits for the daemon to become ready before forwarding the Docker command.

## Requirements

- Windows with **WSL** installed
- An **Ubuntu** WSL distro, or another distro name passed via `-Distro`
- Internet access for package installation inside WSL

## Default behavior

By default, the script assumes:

- distro name: `Ubuntu`
- cmd shims: enabled
- Docker install: only performed if Docker is not already present

## Parameters

### `-Distro <string>`
Target WSL distro name.

Example:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-wsl-docker-wrapper.ps1 -Distro "Ubuntu-24.04"
```

### `-CreateCmdShim`
Creates `docker.cmd` and `docker-compose.cmd` in `%USERPROFILE%\bin`.

This switch is enabled by default in the script.

Example: disable cmd shim creation

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-wsl-docker-wrapper.ps1 -CreateCmdShim:$false
```

### `-ForceDockerInstall`
Forces a Docker reinstall inside the WSL distro even if Docker is already detected.

Example:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-wsl-docker-wrapper.ps1 -ForceDockerInstall
```

## Usage

Run the script from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-wsl-docker-wrapper.ps1
```

If your distro is not named `Ubuntu`:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-wsl-docker-wrapper.ps1 -Distro "Ubuntu-24.04"
```

## What gets installed inside WSL

If Docker is missing, the script installs these packages from Docker’s official Ubuntu repository:

- `docker-ce`
- `docker-ce-cli`
- `containerd.io`
- `docker-buildx-plugin`
- `docker-compose-plugin`

It also removes conflicting packages such as older distro-provided Docker packages before installation.

## PowerShell wrapper behavior

The script writes a block into your PowerShell profile (`$PROFILE.CurrentUserAllHosts`) containing:

- `docker`
- `docker-compose`
- `docker-start`
- `docker-stop`
- `docker-log`

### Wrapper details

- `docker` ensures the Docker daemon is running inside WSL, then forwards all arguments
- `docker-compose` forwards to `docker compose`
- `docker-start` starts `dockerd` inside WSL if it is not already running
- `docker-stop` stops `dockerd`
- `docker-log` prints `/tmp/dockerd.log` from inside WSL

The wrapper is written inside markers so repeated runs update the same block instead of duplicating it.

## cmd shim behavior

If cmd shims are enabled, the script:

1. ensures `%USERPROFILE%\bin` exists
2. adds `%USERPROFILE%\bin` to the user `PATH` if missing
3. writes:
   - `docker.cmd`
   - `docker-compose.cmd`

These shims make Docker available from:

- `cmd.exe`
- many IDE terminals
- tools that call `docker` directly from Windows

Some GUI tools still work better when given the shim path explicitly instead of relying on shell discovery alone.

## VS Code Fallback for a local Windows VS Code window

Configure the Dev Containers extension to use the generated shim directly:

```json
{
  "dev.containers.dockerPath": "C:\\Users\\<you>\\bin\\docker.cmd"
}
```

Then restart VS Code.

## First run after setup

The script performs an automatic Docker smoke test at the end of setup.
If cmd shims are enabled, it also performs a Windows cmd shim smoke test.

Open a new PowerShell window and test:

```powershell
docker version
docker ps
docker compose version
```

If Linux group membership was changed during setup, apply it once by restarting WSL:

```powershell
wsl --shutdown
```

Then open a new terminal and test again.

## Notes

- This setup is intended for **Linux containers in WSL 2**.
- It is designed for **Ubuntu-based WSL distros** because the install path uses Docker’s Ubuntu repository.
- It does not depend on `systemd`.
- `dockerd` is started manually in the background when needed.

## Troubleshooting

### `wsl.exe` not found
Install WSL from an elevated PowerShell:

```powershell
wsl --install -d Ubuntu
```

Then reboot, launch Ubuntu once, complete initial user setup, and rerun the script.

### Distro exists but the script says it is not ready
Open the distro manually once:

```powershell
wsl -d Ubuntu
```

Complete the first-time Linux user creation flow, then rerun the script.

### `docker` works in WSL but not in PowerShell
Open a new PowerShell session so the updated profile is loaded.

You can also load it manually in the current session:

```powershell
. $PROFILE.CurrentUserAllHosts
```

### `docker` works in PowerShell but not in `cmd.exe`
Check whether `%USERPROFILE%\bin` is on your user `PATH`, then open a new `cmd.exe` window.

### VS Code Dev Containers does not find Docker

Use the preferred WSL workflow above: open the folder in a WSL window first, then run `Dev Containers: Reopen in Container`.

If you intentionally use a local Windows VS Code window, set:

```json
{
  "dev.containers.dockerPath": "C:\\Users\\<you>\\bin\\docker.cmd"
}
```

After changing the setting, restart VS Code so it picks up the new Docker path.

### Docker permission denied inside WSL
The Linux user may need the new `docker` group membership applied:

```powershell
wsl --shutdown
```

Then reopen the terminal.

### Daemon startup issues
Inspect the WSL daemon log:

```powershell
docker-log
```

Or directly inside WSL:

```bash
tail -n 200 /tmp/dockerd.log
```

## Security and scope

This setup installs Docker Engine inside the selected WSL distro and modifies:

- the distro’s package sources and packages
- Linux group membership for the default WSL user
- your PowerShell profile
- your user `PATH` if cmd shims are enabled
- `%USERPROFILE%\bin` if cmd shims are enabled

Review the script before running it in managed or locked-down environments.

## Example workflow

After setup, a normal Windows PowerShell session should look like this:

```powershell
docker version
docker ps
docker run hello-world
docker compose up -d
```

All of those commands are forwarded into Docker Engine running inside WSL.
