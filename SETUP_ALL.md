# setup_all usage

There are two interactive setup entrypoints:

- `setup_all.ps1` runs on Windows. It asks whether to stop the current Docker Desktop stack, whether to install/use Debian WSL, whether to copy the project into WSL, and whether to run Linux setup.
- `setup_all.sh` runs inside Debian/WSL or a Linux server. It asks whether to install Docker Engine, start Docker, run the GPU smoke test, and start the stack.

Windows-side run:

```powershell
cd C:\Users\maxim\sci-assistant
powershell -ExecutionPolicy Bypass -File .\setup_all.ps1
```

If your WSL distro is not named `Debian`:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup_all.ps1 -Distro Ubuntu
```

Linux/WSL-side run:

```bash
cd ~/sci-assistant
./setup_all.sh
```

The actual service startup remains `start-all.sh` in WSL/Linux and `start-all.ps1` on Windows/Docker Desktop. For server-like testing, use the WSL/Linux path.
## Stop later

From Windows PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\stop_all.ps1
```

The stop helper asks for the WSL distro and whether to stop, down, remove volumes, show status, stop Docker, or run `wsl --shutdown`.