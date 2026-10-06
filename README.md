# dbt dev setup (Windows, dbt Core + Microsoft Fabric)

`setup-dbt.ps1` gives a dbt repo a project-local environment for dbt Core 1.10.15 with Microsoft's `dbt-fabric` 1.10.1 adapter. It needs no admin rights and changes nothing machine-wide.

This repo isn't a dbt project. Add it to each dbt repo under `tools/dbt-setup`, and the script sets up the repo that contains it. The dbt repo keeps its own README.

## Add it to a dbt repo

**Recommended: git subtree.**
- It copies these files into the dbt repo under `tools/dbt-setup`.
- A plain `git clone` of the dbt repo then has everything, and teammates don't need access to this repo.
- `git subtree` ships with Git for Windows.
- Run these from the dbt repo root with a clean working tree:

```powershell
# Add it (once)
git subtree add --prefix tools/dbt-setup https://github.com/<org>/dbt-dev-setup.git main --squash

# Later: pull a newer version
git subtree pull --prefix tools/dbt-setup https://github.com/<org>/dbt-dev-setup.git main --squash
```

**Alternative: git submodule.**
- The dbt repo stores a pointer to an exact commit of this repo instead of a copy.
- Everyone who clones the dbt repo needs read access to this repo.
- They also need `git clone --recurse-submodules`, or `git submodule update --init` after cloning. Otherwise `tools/dbt-setup` is empty.

```powershell
# Add it (once)
git submodule add https://github.com/<org>/dbt-dev-setup.git tools/dbt-setup

# Later: move to the latest version, then commit the updated pointer
git submodule update --remote tools/dbt-setup
```

Either way, the script treats the dbt repo as the project. For a submodule, that's the parent repo. `requirements.txt`, `requirements-lock.txt`, `.venv`, `.vscode` and `.gitignore` are created in the dbt repo, and nothing is written into `tools/dbt-setup`.

## Run it

1. Clone the dbt repo and open the folder in VS Code.
2. Open the integrated terminal (`` Ctrl+` ``) and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\dbt-setup\setup-dbt.ps1
```

3. Follow the **Next steps** printed at the end. They cover reloading the VS Code window, opening a new terminal, setting the `DBT_FABRIC_*` variables, signing in, and running `dbt debug`.

`-ExecutionPolicy Bypass` on that command line applies only to the single `powershell` process it starts. Nothing persistent changes. The script works in Windows PowerShell 5.1 and PowerShell 7+; use `pwsh` instead of `powershell` for 7.

Re-running is safe. On a correct environment it changes nothing and needs no network. Useful switches:

| Switch | Use it when |
|---|---|
| `-CheckOnly` | You want a report without changes (exit code `0` = OK, `2` = changes needed, `1` = error). Include its output when asking for help. |
| `-Recreate` | `.venv` is in a weird state. Deletes and rebuilds it from the lock. |
| `-UpdateLock` | You changed `requirements.txt`. Re-resolves in a fresh `.venv` and rewrites the lock. |
| `-PythonExe <path>` | You want to build from a specific 64-bit Python 3.12/3.13. |
| `-PythonInstallMethod None` | Downloads aren't allowed. The script stops with manual instructions instead. |
| `-AuthMethod ActiveDirectoryInteractive` | You don't have Azure CLI. This only applies to a new profile template. |

## What it touches

| Where | What |
|---|---|
| The dbt repo | `.venv\`, `requirements.txt` (created if missing), `requirements-lock.txt`, `.vscode\settings.json` and `.vscode\extensions.json` (merged, never overwritten), `.gitignore` (missing entries appended) |
| `tools/dbt-setup` (this repo) | Nothing |
| `%USERPROFILE%\.dbt\profiles.yml` | Only if your project's profile is missing. It's appended after a backup, never overwritten, and holds no secrets (`env_var()` only). |
| Only if no Python 3.12/3.13 exists | Python 3.12 under `%LOCALAPPDATA%\uv\python` and uv under `%LOCALAPPDATA%\Programs\uv\<version>`, or the python.org fallback in `%LOCALAPPDATA%\Programs\Python\Python312` |
| Never | Program Files, HKLM, PATH, global or `--user` pip installs, ODBC drivers, the persistent execution policy |

## Prerequisites

- Windows 10/11 and VS Code. The script recommends the Python extension through `.vscode\extensions.json`.
- Network access to PyPI or your internal index, on the first run only. Access to `github.com` (and possibly `releases.astral.sh`) or `www.python.org` is needed only when no Python 3.12/3.13 is installed.
- Keep the repo path to roughly 85 characters or fewer, for example `%USERPROFILE%\src\<repo>`. Longer paths hit the 260-character limit inside `.venv` unless IT has enabled `LongPathsEnabled`.
- The warehouse's SQL connection string (Fabric portal > warehouse > settings), access to it, and outbound TCP 1433.
- Windows App Control must allow the compiled modules pip installs into `.venv`. Smart App Control or an organization App Control for Business (WDAC) policy may block them. See Troubleshooting.
- For `authentication: CLI`, the Azure CLI. The [ZIP package](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-windows) installs without admin.
- No ODBC driver is needed. dbt-fabric 1.10.1 connects through `mssql-python`, which bundles its own driver.

## Requirements and the lock file

- **`requirements.txt`** lives in the dbt repo; the script creates it on the first run. This setup repo doesn't ship one: the pins live in the `VERSION PINS` block at the top of `setup-dbt.ps1`.
- `requirements.txt` lists direct dependencies with exact pins. `dbt-core==1.10.15` and `dbt-fabric==1.10.1` are listed together so pip resolves them in one step. dbt-fabric 1.10.x accepts any dbt-core `>=1.10.0`, and dbt-core 1.12.x pulls an sdist-only parser package. The script stops if these pins differ from its `VERSION PINS` block.
- **`requirements-lock.txt`** pins the full transitive set (about 64 packages). It's produced by `pip freeze` from a freshly built `.venv`, and its header records the Python version and time.
- **First run without a lock:** the script runs `pip install -r requirements.txt` in a fresh `.venv` and writes the lock. **Commit it.**
- **Every later run or clone:** the script runs `pip install -r requirements-lock.txt`, or does nothing if `.venv` already matches. Extra packages in `.venv` that aren't in the lock trigger a warning; `-Recreate` gives a clean venv.
- **Changing dependencies:** edit `requirements.txt` (with `==`), run with `-UpdateLock`, and commit both files. The script refuses a stale lock.
- **Changing the team standard:**
  1. Edit `VERSION PINS` here and merge.
  2. In each dbt repo, pull the update. The script then stops until `requirements.txt` matches.
  3. Edit those two lines, run with `-UpdateLock`, and commit both files.
- The lock is Windows-specific (it includes `colorama`, for example). For this pin set, Python 3.12 and 3.13 resolve to the same packages. You can also generate it from any OS with `uv pip compile requirements.txt --python-platform x86_64-pc-windows-msvc --python-version 3.12 -o requirements-lock.txt`; the script reads that format too.

## Troubleshooting

**"running scripts is disabled on this system"**
- Use the exact command above. `-ExecutionPolicy Bypass` covers that one process only.
- If it still fails, run `Get-ExecutionPolicy -List`. A `MachinePolicy` or `UserPolicy` value is set by Group Policy and can't be bypassed; ask IT.
- If the script was downloaded rather than cloned, run `Unblock-File .\tools\dbt-setup\setup-dbt.ps1`.

**The VS Code terminal won't activate `.venv`** (`Activate.ps1` is blocked by policy)
- You don't need activation: run `.\.venv\Scripts\dbt.exe debug`.
- Or switch the terminal profile to **Command Prompt**, which uses `activate.bat`.
- Or run `Set-ExecutionPolicy -Scope Process Bypass; .\.venv\Scripts\Activate.ps1` in that terminal.

**Proxy, TLS inspection or `CERTIFICATE_VERIFY_FAILED`**
- The script uses `HTTPS_PROXY`, `PIP_INDEX_URL`, `pip.ini` and `PIP_CERT` exactly as configured. `python -m pip config list` shows what pip sees.
- PAC/auto-config proxies don't work with pip or uv. Set `$env:HTTPS_PROXY = "http://proxy:port"` for the session.
- pip 24.2+ and uv (via the script) trust the Windows certificate store.
- `dbt deps` uses certifi. If it fails behind TLS inspection, set `REQUESTS_CA_BUNDLE` to the corporate root CA (PEM).
- Never use `--trusted-host` or turn verification off.

**"Python was not found; run without arguments to install from the Microsoft Store"**
- That message comes from the Store's `python.exe` alias. The script skips it automatically.
- To silence it, turn off the `python.exe` and `python3.exe` aliases under Settings > Apps > Advanced app settings > App execution aliases (per-user, no admin).

**Downloads blocked (no Python 3.12/3.13 and no access to github.com or python.org)**
- The script stops with manual options:
  - Ask IT for 64-bit Python 3.12.
  - Install python.org 3.12.10 "just for me", then pass `-PythonExe`.
  - Set `UV_PYTHON_INSTALL_MIRROR` to an internal mirror.
- uv is preferred because python.org stopped publishing Windows installers for 3.12 after 3.12.10. uv-managed builds still get security fixes.

**"The project path is too long" or install errors with very long file names**
- Clone to a shorter path, such as `%USERPROFILE%\src\<repo>`.

**Repo inside OneDrive**
- It works, but OneDrive syncs and locks thousands of `.venv` files. Prefer a folder outside OneDrive.

**"Could not delete .venv"**
- Something is using it, usually VS Code/Pylance or a running dbt. Close VS Code, run the script from a standalone PowerShell window with `-Recreate`.

**`DLL load failed while importing <module>: An Application Control policy has blocked this file`**
- This isn't a VC++ or install problem.
  - `python.exe` is signed and runs, but the compiled modules pip installs from PyPI (`.pyd` files such as `rpds`, `pydantic_core`, `msgpack`) and the `.venv\Scripts\dbt.exe` launcher are unsigned.
  - An App Control policy that only allows signed or explicitly allowed code refuses to load them.
- The script reports `BLOCKED` and still finishes the VS Code, `.gitignore` and profile steps. It also writes `.venv\app-control-report.csv`, listing every native binary in `.venv` with its signature status, signer and SHA-256.
- Check Windows Security > App & browser control > Smart App Control settings.
  - On a personal PC with Smart App Control **On**, turning it off is your call. Check how to turn it back on for your Windows version first.
  - On a work PC, or with Smart App Control off, the block comes from your organization's policy. Open an IT/security ticket asking for an allow rule for the project's `.venv`, and attach the report.
- Blocks are logged in Event Viewer > Applications and Services Logs > Microsoft > Windows > CodeIntegrity > Operational (event 3077).
- **What IT should know:** the wheels are byte-identical on every machine, and `requirements-lock.txt` pins exact versions. Rules generated from one `.venv` (e.g. with the App Control for Business Wizard) therefore cover everyone, until the lock changes.
- Once IT confirms the rule is in place, re-run the script.

**`DLL load failed` for any other reason**
- Python ships `vcruntime140*.dll` and the mssql-python wheel bundles `msvcp140.dll`, so a missing VC++ runtime is rare.
- If it happens, IT must install the Microsoft Visual C++ 2015-2022 Redistributable (x64), which needs admin.

**`dbt debug` fails**
- `Env var required but not provided`: set the `DBT_FABRIC_*` variables.
- `AzureCliCredential` / `az` errors: install Azure CLI and run `az login`, or switch the profile to `ActiveDirectoryInteractive`.
- Timeouts: outbound TCP 1433 may be blocked on your network.
- `Update available!` in `dbt --version` is expected, because the versions are pinned.

**Executables in `.venv` are blocked** (AppLocker)
- The script can't work around a security policy. IT needs to allow the project's `.venv`. The App Control report above lists the files involved.

## Removing it

- Delete `.venv\`.
- Remove your profile block from `%USERPROFILE%\.dbt\profiles.yml`.
- If the script installed Python, delete `%LOCALAPPDATA%\uv\python` and `%LOCALAPPDATA%\Programs\uv`. For the python.org fallback, uninstall via Settings > Apps.

## Maintaining this repo

Test scenarios and their expected results are in [docs/TEST-MATRIX.md](docs/TEST-MATRIX.md). Keep `setup-dbt.ps1` ASCII-only, because Windows PowerShell 5.1 reads files without a byte-order mark as ANSI.
