# Self-Hosted Runner Toolkit

**Set up and manage free GitHub Actions self-hosted runners on your own Windows, macOS and Linux machines with one interactive script per OS.**

Turn an old PC, a spare Mac, a Raspberry Pi or a free cloud VM into GitHub Actions runners for all your repos. The scripts handle sign-in, many repos, several GitHub accounts, organizations, background services, health checks and cleanup, so you don't have to repeat GitHub's manual setup steps for every repo.

| OS | Script | Runs as |
|---|---|---|
| Windows 10/11, Windows Server | [`runner-manager.ps1`](runner-manager.ps1) | Windows services |
| macOS (Apple silicon and Intel) | [`runner-manager.sh`](runner-manager.sh) | launchd agents |
| Linux (x64, arm64, arm) | [`runner-manager.sh`](runner-manager.sh) | systemd services |

---

## Contents

- [Why this exists](#why-this-exists)
- [What the scripts do](#what-the-scripts-do)
- [Quick start](#quick-start)
- [The menu](#the-menu)
- [Command-line mode](#command-line-mode)
- [How it works](#how-it-works)
- [Using your runners in workflows](#using-your-runners-in-workflows)
- [Platform notes](#platform-notes)
- [Troubleshooting](#troubleshooting)
- [Where to run runners for free](#where-to-run-runners-for-free)
- [Security](#security)
- [Uninstalling](#uninstalling)
- [FAQ](#faq)

---

## Why this exists

GitHub-hosted runners are convenient, but on **private repos** they come with a monthly minutes allowance (2,000 minutes on the Free plan, 3,000 on Pro). macOS minutes count **10×**, so a Swift project can use up the allowance in a few days. **Self-hosted runners**, meaning your own machines, don't use those minutes.

> **Pricing note:** In December 2025 GitHub announced a small per-minute platform charge for self-hosted runners in private repos, then postponed it after feedback. At the time of writing (late 2026), self-hosted runners are free to use. Check [GitHub's pricing page](https://github.com/pricing) for the current terms.

Setting up self-hosted runners by hand has some rough edges, and these scripts were written to deal with each of them:

1. **One runner per repo on personal accounts.** Only organizations can share one runner across all their repos. On a personal account (`github.com/you`) a runner belongs to **one repo**, so every repo needs its own registration token, folder, setup command and background service. With ten repos, that's ten manual setups.
2. **Tokens and commands differ per repo.** GitHub's "New self-hosted runner" page shows commands with a one-time token for that repo only. Copying and pasting them for each repo is slow and easy to get wrong.
3. **Windows gotchas** that make ordinary workflows fail on a Windows runner:
   - `run:` steps use **PowerShell** by default, so bash scripts (`set -o pipefail`, `if [ ... ]`) fail.
   - **PowerShell scripts are blocked** by default ("running scripts is disabled on this system").
   - The runner service runs as **NETWORK SERVICE**, which can't see tools installed only on your user PATH ("node is not recognized").
   - `bash` may resolve to **WSL's bash** instead of Git Bash, or not exist at all.
   - **Long paths** (deep `node_modules`) and **sleep mode** break builds.
4. **Half-finished setups** leave broken services, stale "Offline" runners on GitHub, and folders that are hard to clean up.
5. **Several GitHub accounts or organizations** on one machine get confusing quickly.
6. **macOS apps need macOS runners.** Xcode, AppKit/SwiftUI, code signing and notarization only work on a Mac, so Mac-app repos can't use a Windows runner.

---

## What the scripts do

Both scripts have the same features:

- **Guided first run:** installs GitHub CLI if it's missing and signs you in through the browser.
- **Multiple GitHub accounts:** sign in to several, switch between them, and each runner remembers which account manages it.
- **Add runners in bulk:** pick repos from a list (`1,3,5`, `2-4` or `all`), type `owner/repo`, paste a GitHub URL, or add an **organization runner**.
- **Choose where runners live:** a default folder, or a different folder per runner, plus moving a runner later.
- **Runner download:** downloads the latest version automatically, or uses **a download link you paste**, or **a file you already have**, and every file is checked against its **SHA-256 checksum** before it's used.
- **Background services:** start, stop and restart one runner or all of them; they start automatically after a reboot.
- **Status at a glance:** service state, GitHub's view (Online / Busy / Offline), labels, account and folder for every runner.
- **Labels:** set custom labels like `php8` or `swift` and get the matching `runs-on:` line.
- **Logs:** show a runner's latest log with errors highlighted, plus the service log.
- **Health check:** disk space, which tools the runners can see, and OS settings (Windows script policy, Git Bash, long paths, sleep, Xcode tools, systemd), with **one-step fixes** where possible.
- **Cleanup:** work folders, old logs, stale runners on GitHub, leftovers from failed setups, and the cached download.
- **Your list and "Fresh start":** keep a list of repos and rebuild all their runners in one go.
- **Command-line mode:** every common action works without the menu, for shortcuts and scheduled tasks.
- **Settings are saved** next to the script, so the next run remembers everything.

---

## Quick start

### Windows

1. Open **PowerShell as Administrator** and download [`runner-manager.ps1`](runner-manager.ps1) into a folder only Administrators can change:
   ```powershell
   mkdir "$env:ProgramFiles\runner-manager" -Force; cd "$env:ProgramFiles\runner-manager"
   Invoke-WebRequest https://raw.githubusercontent.com/jaiedsabid/self-hosted-runner-toolkit/main/runner-manager.ps1 -OutFile runner-manager.ps1
   ```
   Don't keep it in a folder like `C:\runner-manager`: Windows lets every user of the PC change files in folders created directly under `C:\`, and the script runs as Administrator. If it finds itself in such a folder, it offers to lock the folder down.
2. In the same Administrator window, run:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\runner-manager.ps1
   ```
   `-ExecutionPolicy Bypass` lets this one script run without changing your system settings.
3. Follow the prompts: install GitHub CLI if asked, sign in, then choose **2) Add runner(s)**.
4. Run **11) Health check** once and accept the suggested fixes.

### macOS and Linux

1. Download the script:
   ```bash
   mkdir -p ~/runner-manager && cd ~/runner-manager
   curl -fsSLO https://raw.githubusercontent.com/jaiedsabid/self-hosted-runner-toolkit/main/runner-manager.sh
   chmod +x runner-manager.sh
   ```
2. Run it as your **normal user**, not with `sudo`:
   ```bash
   ./runner-manager.sh
   ```
   It asks for your password only when needed (Linux services, system packages, macOS sleep settings).
3. Follow the prompts: install GitHub CLI if asked, sign in, then choose **2) Add runner(s)**.
4. Run **11) Health check** once.

### Requirements

| | Windows | macOS | Linux |
|---|---|---|---|
| OS | Windows 10/11 or Server 2016+, 64-bit | macOS 12+ recommended | Any distro with systemd (Ubuntu, Debian, Fedora, Raspberry Pi OS…) |
| Shell | Windows PowerShell 5.1 (built in) | bash 3.2+ (built in) | bash |
| GitHub CLI | 2.40+ (installed via `winget` if missing) | 2.40+ (Homebrew or direct download) | 2.40+ (direct download) |
| Rights | Run as Administrator | Normal user | Normal user with `sudo` |
| GitHub | Admin rights on each repo (or org owner for organization runners) | same | same |

---

## The menu

```
===== GitHub Runner Manager =====
 Account: your-github-login
 Runners
   1) Show status
   2) Add runner(s) (pick repos, type a repo, or an organization)
   3) Remove a runner
   4) Start a runner
   5) Stop a runner
   6) Restart all runners
   7) Move a runner to another folder
   8) Change a runner's labels
 Maintenance
   9) View a runner's log
  10) Cleanup (work folders, old logs, stale runners, leftovers)
  11) Health check
 Setup
  12) Fresh start (remove and set up again everything in your list)
  13) Manage your list
  14) Settings
   A) Accounts (switch, sign in, sign out)
   0) Exit
```

| Option | What it does |
|---|---|
| **1 Show status** | Lists every runner: service state, GitHub status (Online, Busy, Offline), labels, managing account and folder. |
| **2 Add runner(s)** | **Pick from a list** of repos where you're an admin (yours or another owner's), **type a repo** (`name`, `owner/name` or a GitHub URL), or add an **organization runner** shared by all the org's repos. Then choose the folder(s). |
| **3 Remove** | Stops and removes the service, unregisters the runner from GitHub, and deletes its folder. |
| **4 / 5 Start / Stop** | Pick one runner or **A) All**. |
| **6 Restart all** | Useful after installing tools or changing PATH. |
| **7 Move** | Moves a runner to another folder or drive. Behind the scenes it removes the runner and sets it up again there. |
| **8 Labels** | Sets custom labels (e.g. `php8,node20`) and shows the `runs-on:` line to use. |
| **9 View log** | Last 40 lines of the runner's log with errors in red, plus the service log on request. |
| **10 Cleanup** | Work folders (keeps or clears the tool cache), logs older than 7 days, stale runners on GitHub, leftover folders and broken services, the cached runner download, or everything. |
| **11 Health check** | Checks accounts, disk space, tools, and OS settings, and offers fixes (see [Platform notes](#platform-notes)). |
| **12 Fresh start** | Removes and sets up again every runner in your list. You can also remove runners that aren't in the list. |
| **13 Manage your list** | Add repos (from a list, typed, or an organization) or remove them. The list is what Fresh start rebuilds. |
| **14 Settings** | Default runner folder, where the runner download is kept, runner name prefix, and (Windows only) which account the services run as. |
| **A Accounts** | Switch the active account, sign in to another, give an account permission for organization runners, or sign out. |

---

## Command-line mode

Every common action works without the menu, which is handy for desktop shortcuts, scheduled tasks or SSH sessions.

**Windows** (PowerShell as Administrator):

```powershell
.\runner-manager.ps1 -Status
.\runner-manager.ps1 -Start all                 # or -Start MyRepo
.\runner-manager.ps1 -Stop all
.\runner-manager.ps1 -Restart all
.\runner-manager.ps1 -Add MyRepo -Folder D:\runners\MyRepo
.\runner-manager.ps1 -Remove MyRepo -Yes
.\runner-manager.ps1 -Log MyRepo
.\runner-manager.ps1 -Clean all                 # work folders
.\runner-manager.ps1 -Cleanup                   # full cleanup, no questions
.\runner-manager.ps1 -Health
.\runner-manager.ps1 -Status -Account otheruser # use another signed-in account for this run
```

**macOS / Linux:**

```bash
./runner-manager.sh --status
./runner-manager.sh --start all                 # or --start MyRepo
./runner-manager.sh --stop all
./runner-manager.sh --restart all
./runner-manager.sh --add MyRepo --folder ~/actions-runners/MyRepo
./runner-manager.sh --remove MyRepo --yes
./runner-manager.sh --log MyRepo
./runner-manager.sh --clean all
./runner-manager.sh --cleanup
./runner-manager.sh --health
./runner-manager.sh --status --account otheruser
```

**Naming runners:** a plain name like `MyRepo` means a repo owned by the active account. Use `owner/repo` for other owners, and `org:<name>` for an organization runner (for example `-Start org:my-company`).

In command-line mode the scripts don't ask questions. If the runner download is missing, they fetch the latest version automatically.

---

## How it works

### One runner per repo, or one per organization

- **Personal account repos** each get their own runner, because GitHub doesn't offer account-wide runners for personal accounts. The script registers them all for you, each in its own folder and service.
- **Organization runners** serve every repo in the org. If you have many repos, you can create a free GitHub organization, move the repos into it, and add **one** organization runner. Organization runners need you to be an org **owner**, and your sign-in needs the `admin:org` permission (**A → Let an account manage organization runners**).

### Accounts

The scripts use [GitHub CLI](https://cli.github.com) and its support for several signed-in accounts (version 2.40+). Each runner remembers which account set it up, and that account's token is used whenever that runner is managed. Switching accounts in the script **doesn't change** your normal `gh` login.

### The runner download

Every runner is set up from GitHub's official runner package (`actions-runner-<os>-<arch>-<version>`). If the package isn't already saved, you choose:

1. **Download the latest version automatically** from [actions/runner releases](https://github.com/actions/runner/releases).
2. **Paste a download link**, for example copied from a repo's *Settings → Actions → Runners → New self-hosted runner* page or from the releases page. Useful for pinning a version or behind restrictive networks.
3. **Use a file already on this computer**, for offline or air-gapped setups. On macOS you can drag the file into the Terminal window.

Every package is checked against its **SHA-256 checksum** before it's used. For official release files (option 1, a link to `github.com/actions/runner/releases`, or a file with its original name) the script looks up GitHub's published checksum itself. For a link to any other site, or a renamed file, you must paste the checksum. It also checks that the file really is a runner package for your OS and CPU (`win-x64`, `win-arm64`, `osx-arm64`, `osx-x64`, `linux-x64`, `linux-arm64`, `linux-arm`) before using it.

### Where things are stored

| | Windows | macOS / Linux |
|---|---|---|
| Settings file | `runners-config.json` next to the script | `runner-manager.conf` next to the script |
| Default runner folder | `C:\runners\<owner>\<repo>` | `~/actions-runners/<owner>/<repo>` |
| Organization runner folder | `C:\runners\org-<name>` | `~/actions-runners/org-<name>` |
| Runner download | `C:\actions-runner\runner.zip` | `~/actions-runners/_downloads/` |
| Runner names on GitHub | `<computer>-<repo>` (prefix configurable) | `<computer>-<repo>` (prefix configurable) |

All of these can be changed in **Settings**. The settings file holds folder paths, account names and labels only, never tokens or passwords.

The scripts find runners from the runner's own registration file and its service, not from names. Runners you set up by hand or with an older version still show up and can be managed.

---

## Using your runners in workflows

**Basic:**

```yaml
jobs:
  build:
    runs-on: self-hosted
```

**Pick a specific OS or a label you set:**

```yaml
runs-on: [self-hosted, Windows]
runs-on: [self-hosted, macOS]
runs-on: [self-hosted, Linux, ARM64]
runs-on: [self-hosted, php8]
```

Every runner automatically has `self-hosted`, its OS (`Windows` / `macOS` / `Linux`) and its CPU (`X64` / `ARM64` / `ARM`) as labels.

**Workflows written for Linux, running on a Windows runner:** add this near the top of the workflow file so `run:` steps use Git Bash instead of PowerShell:

```yaml
defaults:
  run:
    shell: bash
```

**Mac apps (Swift, Xcode):** use a Mac runner. On macOS, `run:` steps already use bash.

```yaml
jobs:
  test:
    runs-on: [self-hosted, macOS]
    steps:
      - uses: actions/checkout@v4
      - run: |
          set -o pipefail
          swift test 2>&1 | tee test.log
```

**Split work across machines:** build and test a Mac app on the Mac runner, and run lightweight jobs (linting, docs, release notes) on Windows or Linux.

---

## Platform notes

### Windows

- **Run as Administrator.** Services and system settings need it.
- **Which account the runner services use** (Settings → *Runners run as*):
  - **NETWORK SERVICE** (default): a limited account that only sees tools on the **system** PATH.
  - **Your Windows account:** sees the same tools you do. You enter your Windows password once per session (not your PIN); it's never saved.
- **What the health check finds and fixes:**

  | Problem | Symptom in Actions | Fix offered |
  |---|---|---|
  | PowerShell scripts blocked | `...ps1 cannot be loaded because running scripts is disabled on this system` | Sets the machine policy to `RemoteSigned` |
  | No Git Bash on PATH, or WSL's bash found first | `shell: bash` steps fail | Adds `C:\Program Files\Git\bin` to the start of the system PATH |
  | Tool only on your user PATH | `node is not recognized...` | Explains: add it to the system PATH or switch the service account |
  | Long paths disabled | Failures deep in `node_modules` | Enables Windows and Git long paths |
  | PC goes to sleep | Jobs wait in the queue | Turns off sleep while plugged in |
  | Low disk space | Random build failures | Points you to Cleanup |

- **Default shell:** on Windows the runner uses PowerShell 7 (`pwsh`) if installed, otherwise Windows PowerShell. There's no runner setting to make bash the default. Use `shell: bash` in the workflow (see above).

### macOS

- Runners run as **launchd agents for your user**, so they work **while you're logged in**. A locked screen is fine; logging out stops them.
- The health check offers to install **Xcode command line tools** and to **turn off sleep** while on power.
- Runners remember the PATH from when they were set up. If you install a tool later (Node, Swift, Homebrew packages), the health check offers to **refresh every runner's PATH** and restart them.
- Packages downloaded in a browser have macOS's quarantine flag removed automatically, so the runner can start.

### Linux

- Runners run as **systemd services** under your user and start automatically after a reboot. The script uses `sudo` for service operations only.
- The runner's system libraries (such as `libicu`) are installed automatically the first time.
- Without systemd (some containers, or WSL without systemd enabled), runners are started in the background, but they won't come back after a reboot. On WSL, enable systemd in `/etc/wsl.conf`.
- Works on Raspberry Pi (arm64 or arm).

---

## Troubleshooting

| What you see | Why | What to do |
|---|---|---|
| `running scripts is disabled on this system` (Windows) | PowerShell execution policy | **11) Health check** → allow scripts |
| `Set-Variable : Cannot bind parameter 'Option'... "pipefail"` (Windows) | A bash step ran in PowerShell | Add `defaults: run: shell: bash`, or run the job on a Linux/macOS runner |
| `node`/`php`/`composer` "is not recognized" (Windows) | The service account can't see your user PATH | Add the tool to the system PATH, or Settings → run as your account, then **6) Restart all** |
| A tool is "not found" (macOS/Linux) | Runner PATH saved before the tool was installed | **11) Health check** → refresh PATH |
| Runner missing from the list or shows "Not installed" | Setup failed halfway (wrong repo name, no admin rights) | **10) Cleanup → Leftovers**, then add it again. Check the repo name matches the GitHub URL. |
| Runner shows **Offline** on GitHub | Service stopped, machine asleep, or no network | **4) Start**, then **9) View log** |
| Jobs stay "Queued" | No runner matches `runs-on`, or the runner is busy | Compare `runs-on` with the runner's labels in **1) Status** |
| `swift`/`xcodebuild` fails on Windows or Linux | Mac apps need macOS | Use `runs-on: [self-hosted, macOS]` |
| Can't add an organization runner | Not an org owner, or missing `admin:org` | **A → Let an account manage organization runners** |
| "Couldn't get a sign-in token" | GitHub CLI older than 2.40, or sign-in expired | Update GitHub CLI, or **A → Sign in** again |
| "GitHub no longer accepts the sign-in for …" | The account's sign-in expired or was revoked | Answer **y** to sign in again, or use **A → Sign in to another account** with the same account |
| "Could not list repos for …" | The line below it shows GitHub CLI's reason: wrong user/org name, no network, or a sign-in problem | Fix what it says, or choose **Type a repo** instead |
| Checksum doesn't match | Wrong file, broken download, or a file that was changed | Download again from github.com/actions/runner/releases, and copy the checksum for the exact file |
| "… is a PUBLIC repo" when adding a runner | Self-hosted runners on public repos let anyone run code on your machine | Use a private repo. In the menu you can type `public` to go ahead anyway; command-line mode always refuses |
| "Other users of this PC can change files in …" (Windows) | The folder lets every user change files the script or runners run as Administrator/service | Accept the fix, or move the script to `C:\Program Files\runner-manager` |

---

## Where to run runners for free

- **A computer you already own:** an old laptop or PC, a spare Mac, or a Raspberry Pi 4/5 (Linux arm64). It costs only electricity, but it must stay on and awake.
- **Oracle Cloud Always Free:** an ARM VM (reported as 2 OCPU and 12 GB RAM in total since mid-2026), plenty for Node and PHP builds. Capacity in popular regions can be limited, and idle instances may be reclaimed.
- **Other clouds:** Google Cloud's always-free `e2-micro` (1 GB RAM) only suits tiny jobs; AWS and Azure offer trial credits rather than permanent free VMs.
- **Public repos:** GitHub-hosted runners are already free with no minute limit, so you may not need a self-hosted runner at all.

Free tiers change often, so check each provider's current terms.

---

## Security

- **Don't use self-hosted runners on public repos.** Anyone who opens a pull request from a fork could run code on your machine. Keep them for private repos, or require approval for fork workflows. The scripts warn you and ask you to type `public` before adding a runner to a public repo, and refuse in command-line mode.
- **Tokens are never written to disk.** The scripts get short-lived registration tokens through GitHub CLI and keep account tokens in memory only. Registration tokens and the Windows service password are handed to the runner in environment variables, never on the command line, so other users and process logs can't see them.
- **Windows folder permissions:** runner folders and the download folder are limited to Administrators, SYSTEM and the runner's service account, so other users of the PC can't change programs that run as a service. The health check finds and fixes folders that other users can change.
- **The Windows service password** (only if you choose to run services as your account) is asked once per session and kept in memory only.
- **The settings file** contains folders, account names and labels only. It's in `.gitignore` in case you run the script inside a clone of this repo.
- Runners are downloaded from GitHub's official `actions/runner` releases, or from a link or file you choose. Every package and the GitHub CLI download is checked against its SHA-256 checksum before it's used.

---

## Uninstalling

1. Run the script and remove each runner (**3) Remove**), or choose **12) Fresh start** with an empty list and remove the others.
2. Delete the script and its settings file (`runners-config.json` or `runner-manager.conf`).
3. Optionally sign out of GitHub CLI: `gh auth logout`.

---

## FAQ

**Can one runner serve all my personal repos?**
No. That's a GitHub limitation for personal accounts. Either let the script register one runner per repo (they're light when idle), or move your repos into a free organization and use one organization runner.

**How many runners can one machine handle?**
Idle runners use very little memory. Each runs one job at a time, so if many repos push at once, an older machine can slow down. Use Stop/Start to keep only the ones you need running.

**Can a Windows runner build my macOS/iOS app?**
No. Xcode, Apple SDKs, code signing and notarization only run on macOS, and Apple's license only allows macOS on Apple hardware. Use a Mac runner for those jobs.

**Can I change the shell on a Windows runner instead of editing workflows?**
Not with a runner setting. Use `shell: bash` in the workflow, or send those jobs to a Linux or macOS runner, where bash is the default.

**Does this work with GitHub Enterprise Server?**
The scripts target github.com. Enterprise Server isn't supported yet; contributions are welcome.

---

## Contributing

Issues and pull requests are welcome, especially testing on more Linux distros, Windows ARM, and older macOS versions.

## License

[MIT](LICENSE). Not affiliated with or endorsed by GitHub.
