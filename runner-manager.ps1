# runner-manager.ps1
# GitHub Runner Manager for Windows
# Sets up and manages GitHub Actions self-hosted runners on this machine,
# for any GitHub account, repo or organization.
#
# First run: just start it. It installs GitHub CLI if needed (via winget),
# signs you in through the browser, and walks you through adding runners.
# Several GitHub accounts can be signed in at once; switch with "A" in the menu.
#
# Run from PowerShell as Administrator:
#   powershell -ExecutionPolicy Bypass -File .\runner-manager.ps1
#
# Settings are saved in runners-config.json next to this script.
#
# Command-line mode (no menu), examples:
#   .\runner-manager.ps1 -Status
#   .\runner-manager.ps1 -Start all
#   .\runner-manager.ps1 -Start someuser/somerepo
#   .\runner-manager.ps1 -Add my-repo -Folder D:\runners\my-repo
#   .\runner-manager.ps1 -Remove my-repo -Yes
#   .\runner-manager.ps1 -Log my-repo
#   .\runner-manager.ps1 -Cleanup
#   .\runner-manager.ps1 -Status -Account otheruser
# A plain repo name means a repo owned by the active account. Use owner/repo for
# other owners, and org:<name> for an organization runner.

param(
  [switch]$Status,
  [string]$Start,
  [string]$Stop,
  [string]$Restart,
  [string]$Add,
  [string]$Remove,
  [string]$Log,
  [string]$Clean,
  [switch]$Cleanup,
  [switch]$Health,
  [string]$Folder,
  [string]$Account,
  [switch]$Yes,
  [switch]$Help
)

# Defaults for a brand-new setup (all of these can be changed from Settings)
$DefaultRunnersRoot = "C:\runners"
$DefaultZipPath     = "C:\actions-runner\runner.zip"
$DefaultPrefix      = "$($env:COMPUTERNAME.ToLower())-"

$ProgressPreference = 'SilentlyContinue'   # makes downloads/unzips much faster
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$RunnerPlatform = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "win-arm64" } else { "win-x64" }
$ScriptDir  = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$ConfigPath = Join-Path $ScriptDir "runners-config.json"

$script:Quiet           = $false   # true in command-line mode (no questions asked)
$script:ServicePassword = $null    # kept in memory only, never saved
$script:Tokens          = @{}      # GitHub tokens per account, in memory only
$script:WarnedAccounts  = @{}
$script:MachineCache    = $null
$script:FolderCache     = $null
$script:GhExe           = "gh"

# =====================================================================
#  Messages
# =====================================================================
function Info($msg) { Write-Host $msg -ForegroundColor Cyan }
function Ok($msg)   { Write-Host $msg -ForegroundColor Green }
function Warn($msg) { Write-Host $msg -ForegroundColor Yellow }
function Fail($msg) { Write-Host $msg -ForegroundColor Red }

function Confirm-Fix($question) {
  if ($script:Quiet) { return $false }
  return (Read-Host "  $question (y/n)") -eq "y"
}

# Parses "1,3,5", "2-4" or "all" into list positions (1-based)
function Read-NumberList($answer, $max) {
  if ($answer -eq "all") { return @(1..$max) }
  $nums = @()
  foreach ($part in ($answer -split ',')) {
    $part = $part.Trim()
    if ($part -match '^(\d+)-(\d+)$') { $nums += [int]$Matches[1]..[int]$Matches[2] }
    elseif ($part -match '^\d+$')      { $nums += [int]$part }
  }
  return @($nums | Where-Object { $_ -ge 1 -and $_ -le $max } | Sort-Object -Unique)
}

# =====================================================================
#  Saved settings (runners-config.json)
# =====================================================================
function Read-Config {
  $cfg = @{
    ActiveAccount  = ""
    RunnersRoot    = $DefaultRunnersRoot
    ZipPath        = $DefaultZipPath
    ServiceAccount = ""
    RunnerPrefix   = $DefaultPrefix
    Repos          = @()   # your list, used by "Fresh start"
    Runners        = @{}   # runner -> folder
    Labels         = @{}   # runner -> "label1,label2"
    RunnerAccounts = @{}   # runner -> GitHub account that manages it
  }
  if (Test-Path $ConfigPath) {
    try {
      $j = Get-Content $ConfigPath -Raw | ConvertFrom-Json
      $props = @($j.PSObject.Properties.Name)
      foreach ($name in "ActiveAccount", "RunnersRoot", "ZipPath", "ServiceAccount", "RunnerPrefix") {
        if ($j.$name) { $cfg[$name] = $j.$name }
      }
      if ($props -contains "Repos") { $cfg.Repos = @($j.Repos | Where-Object { $_ }) }
      foreach ($section in "Runners", "Labels", "RunnerAccounts") {
        if ($j.$section) {
          foreach ($p in $j.$section.PSObject.Properties) { $cfg[$section][$p.Name] = $p.Value }
        }
      }
    } catch {
      Warn "Could not read $ConfigPath. Using default settings."
    }
  }
  return $cfg
}

function Save-Config {
  # With -Account, that account is used for this run only; keep the saved one
  $savedActive = if ($Account) { $script:PersistedActive } else { $Config.ActiveAccount }
  $out = [ordered]@{
    ActiveAccount  = $savedActive
    RunnersRoot    = $Config.RunnersRoot
    ZipPath        = $Config.ZipPath
    ServiceAccount = $Config.ServiceAccount
    RunnerPrefix   = $Config.RunnerPrefix
    Repos          = [string[]]@($Config.Repos)
    Runners        = $Config.Runners
    Labels         = $Config.Labels
    RunnerAccounts = $Config.RunnerAccounts
  }
  $out | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigPath -Encoding UTF8
}

$Config = Read-Config
$script:PersistedActive = $Config.ActiveAccount

# =====================================================================
#  Runner keys
#  A runner is identified by "owner/repo", or "org:<name>" for an organization.
# =====================================================================
function Test-IsOrg($key)      { return $key -like "org:*" }
function Get-OrgName($key)     { return $key.Substring(4) }
function Get-ApiBase($key)     { if (Test-IsOrg $key) { "orgs/$(Get-OrgName $key)" } else { "repos/$key" } }
function Get-TargetUrl($key)   { if (Test-IsOrg $key) { "https://github.com/$(Get-OrgName $key)" } else { "https://github.com/$key" } }
function Get-DisplayName($key) { if (Test-IsOrg $key) { "$(Get-OrgName $key) (org)" } else { $key } }
function Get-FolderName($key)  { if (Test-IsOrg $key) { "org-$(Get-OrgName $key)" } else { $key -replace '/', '\' } }
function Get-DefaultDir($key)  { Join-Path $Config.RunnersRoot (Get-FolderName $key) }

# Name for a new runner, e.g. "mypc-my-repo" or "mypc-org-myorg"
function Get-NewRunnerName($key) {
  if (Test-IsOrg $key) { return "$($Config.RunnerPrefix)org-$(Get-OrgName $key)" }
  return "$($Config.RunnerPrefix)$(($key -split '/')[1])"
}

# Turns a GitHub URL into a key: https://github.com/a/b -> a/b, https://github.com/org -> org:org
function ConvertFrom-GitHubUrl($url) {
  if (-not $url) { return $null }
  try { $path = ([uri]$url).AbsolutePath.Trim('/') } catch { return $null }
  $parts = @($path -split '/' | Where-Object { $_ })
  if ($parts.Count -ge 2) { return "$($parts[0])/$($parts[1])" }
  if ($parts.Count -eq 1) { return "org:$($parts[0])" }
  return $null
}

# Accepts "repo", "owner/repo", "org:name" or a GitHub URL
function ConvertTo-FullKey($text) {
  $text = "$text".Trim().TrimEnd('/')
  if (-not $text) { return $null }
  if ($text -match '^https?://') { return ConvertFrom-GitHubUrl $text }
  if ($text -like "org:*" -or $text -like "*/*") { return $text }
  return "$($Config.ActiveAccount)/$text"
}

# =====================================================================
#  GitHub CLI and accounts
# =====================================================================
function Test-Prerequisites {
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isAdmin) { Fail "Please run PowerShell as Administrator."; return $false }

  if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Warn "GitHub CLI (gh) is not installed. This script uses it to talk to GitHub."
    if (-not $script:Quiet -and (Get-Command winget -ErrorAction SilentlyContinue) -and
        (Read-Host "Install it now with winget? (y/n)") -eq "y") {
      Start-Process winget -ArgumentList @("install", "--id", "GitHub.cli", "-e",
        "--accept-source-agreements", "--accept-package-agreements") -NoNewWindow -Wait
      $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                  [Environment]::GetEnvironmentVariable("Path", "User")
    }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
      Fail "Install GitHub CLI from https://cli.github.com, then run this script again."
      return $false
    }
  }
  $script:GhExe = (Get-Command gh).Source
  return $true
}

# Runs an interactive gh command (login, refresh...) directly in this window
function Invoke-GhInteractive($ghArgs) {
  $saved = $env:GH_TOKEN
  Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
  $p = Start-Process -FilePath $script:GhExe -ArgumentList $ghArgs -NoNewWindow -Wait -PassThru
  if ($saved) { $env:GH_TOKEN = $saved }
  return $p.ExitCode
}

# GitHub accounts signed in to GitHub CLI on this computer
function Get-GhAccounts {
  $saved = $env:GH_TOKEN
  Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
  $raw = (gh auth status -h github.com 2>&1 | ForEach-Object { "$_" }) -join "`n"
  if ($saved) { $env:GH_TOKEN = $saved }
  $found = [regex]::Matches($raw, '\b(?:account|as)\s+([A-Za-z0-9][A-Za-z0-9-]*)')
  return @($found | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
}

function Get-AccountToken($login) {
  if (-not $login) { return $null }
  if ($script:Tokens.ContainsKey($login)) { return $script:Tokens[$login] }
  $saved = $env:GH_TOKEN
  Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
  $t = gh auth token -h github.com -u $login 2>$null
  $code = $LASTEXITCODE
  if ($saved) { $env:GH_TOKEN = $saved }
  if ($code -ne 0 -or -not $t) { return $null }
  $script:Tokens[$login] = "$t".Trim()
  return $script:Tokens[$login]
}

# Makes the following gh calls run as $login (without changing GitHub CLI's own active account)
function Use-Account($login) {
  if (-not $login) { $login = $Config.ActiveAccount }
  $t = Get-AccountToken $login
  if (-not $t -and $login -ne $Config.ActiveAccount) {
    if (-not $script:WarnedAccounts.ContainsKey($login)) {
      Warn "Account $login isn't signed in here. Using $($Config.ActiveAccount) instead."
      $script:WarnedAccounts[$login] = $true
    }
    $t = Get-AccountToken $Config.ActiveAccount
  }
  if ($t) { $env:GH_TOKEN = $t }
}

function Get-KeyAccount($key) {
  if ($Config.RunnerAccounts.ContainsKey($key) -and $Config.RunnerAccounts[$key]) { return $Config.RunnerAccounts[$key] }
  return $Config.ActiveAccount
}
function Use-KeyAccount($key) { Use-Account (Get-KeyAccount $key) }

function Set-ActiveAccount($login) {
  $Config.ActiveAccount = $login
  Save-Config
  Use-Account $login
  Ok "Active account: $login"
}

function Add-Account {
  Write-Host ""
  Info "Sign in to GitHub. A browser window will open; copy the one-time code shown here into it."
  $org = (Read-Host "Will this account manage organization runners too? (y/n)") -eq "y"
  $ghArgs = @("auth", "login", "-h", "github.com", "-p", "https", "--web")
  if ($org) { $ghArgs += @("-s", "admin:org") }
  if ((Invoke-GhInteractive $ghArgs) -ne 0) { Fail "Sign-in didn't complete."; return }

  # gh makes the newly signed-in account its active one
  $saved = $env:GH_TOKEN
  Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
  $login = gh api user --jq .login 2>$null
  if ($saved) { $env:GH_TOKEN = $saved }
  if (-not $login) { Fail "Signed in, but couldn't read the account name."; return }

  $login = "$login".Trim()
  $script:Tokens.Remove($login)
  Set-ActiveAccount $login
}

function Select-Account($title) {
  $accts = @(Get-GhAccounts)
  if ($accts.Count -eq 0) { Warn "No accounts are signed in."; return $null }
  Write-Host ""
  Write-Host $title
  for ($i = 0; $i -lt $accts.Count; $i++) {
    $mark = if ($accts[$i] -eq $Config.ActiveAccount) { "  (active)" } else { "" }
    Write-Host ("  {0}) {1}{2}" -f ($i + 1), $accts[$i], $mark)
  }
  $c = Read-Host "Choose (or Enter to cancel)"
  $n = 0
  if ([int]::TryParse($c, [ref]$n) -and $n -ge 1 -and $n -le $accts.Count) { return $accts[$n - 1] }
  return $null
}

function Grant-OrgPermission {
  $login = Select-Account "Give which account permission to manage organization runners?"
  if (-not $login) { return }
  # "gh auth refresh" only works on GitHub CLI's active account, so switch to
  # $login for the refresh and switch back afterwards
  $prev = Get-GhActiveAccount
  $switched = $false
  if ($prev -ne $login) {
    if ((Invoke-GhInteractive @("auth", "switch", "-h", "github.com", "-u", $login)) -ne 0) {
      Fail "Couldn't switch GitHub CLI to $login."; return
    }
    $switched = $true
  }
  Info "A browser window will open to approve the extra permission (admin:org)."
  if ((Invoke-GhInteractive @("auth", "refresh", "-h", "github.com", "-s", "admin:org")) -eq 0) {
    $script:Tokens.Remove($login)
    Ok "$login can now manage organization runners."
  } else {
    Fail "That didn't complete."
  }
  if ($switched -and $prev) {
    if ((Invoke-GhInteractive @("auth", "switch", "-h", "github.com", "-u", $prev)) -ne 0) {
      Warn "GitHub CLI's active account is now $login (couldn't switch back to $prev)."
    }
  }
}

# GitHub CLI's own active account (read locally, no network needed)
function Get-GhActiveAccount {
  $saved = $env:GH_TOKEN
  Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
  $lines = @(gh auth status -h github.com 2>&1 | ForEach-Object { "$_" })
  if ($saved) { $env:GH_TOKEN = $saved }
  $last = $null
  foreach ($l in $lines) {
    if ($l -match '\baccount\s+([A-Za-z0-9][A-Za-z0-9-]*)') { $last = $Matches[1] }
    if ($l -match 'Active account:\s*true') { return $last }
  }
  return $null
}

function Remove-Account {
  $login = Select-Account "Sign out which account?"
  if (-not $login) { return }
  $managed = @(Get-InstalledRunners | Where-Object { (Get-KeyAccount $_) -eq $login })
  if ($managed.Count) {
    Warn "$($managed.Count) runner(s) on this machine are managed by $login. They keep running,"
    Warn "but you'll need to sign in as $login again to change or remove them."
  }
  if ((Read-Host "Sign out $login? (y/n)") -ne "y") { return }
  if ((Invoke-GhInteractive @("auth", "logout", "-h", "github.com", "-u", $login)) -ne 0) { Fail "Sign-out failed."; return }
  $script:Tokens.Remove($login)
  Ok "Signed out $login."

  if ($Config.ActiveAccount -eq $login) {
    $left = @(Get-GhAccounts)
    if ($left.Count) { Set-ActiveAccount $left[0] }
    else { $Config.ActiveAccount = ""; Save-Config }
  }
}

function Show-Accounts {
  while ($true) {
    $accts = @(Get-GhAccounts)
    Write-Host ""
    Write-Host "----- GitHub accounts -----" -ForegroundColor Cyan
    if ($accts.Count -eq 0) { Write-Host "  (none signed in)" }
    foreach ($a in $accts) {
      $count = @(Get-InstalledRunners | Where-Object { (Get-KeyAccount $_) -eq $a }).Count
      $mark  = if ($a -eq $Config.ActiveAccount) { " (active)" } else { "" }
      Write-Host ("  - {0}{1}    {2} runner(s) on this machine" -f $a, $mark, $count)
    }
    Write-Host ""
    Write-Host "  1) Switch active account"
    Write-Host "  2) Sign in to another account"
    Write-Host "  3) Let an account manage organization runners"
    Write-Host "  4) Sign out an account"
    Write-Host "  0) Back"

    switch (Read-Host "Choose an option") {
      "1" { $login = Select-Account "Switch to which account?"; if ($login) { Set-ActiveAccount $login } }
      "2" { Add-Account }
      "3" { Grant-OrgPermission }
      "4" { Remove-Account; if (-not $Config.ActiveAccount) { return } }
      "0" { return }
      default { Warn "Invalid option." }
    }
  }
}

# Picks the account to use at startup (signs in if there is none)
function Initialize-Account {
  $accts = @(Get-GhAccounts)
  if ($accts.Count -eq 0) {
    if ($script:Quiet) { Fail "No GitHub account is signed in. Run the script without options once to sign in."; return $false }
    Info "Welcome! No GitHub account is signed in yet. Let's sign in."
    Add-Account
    $accts = @(Get-GhAccounts)
    if ($accts.Count -eq 0) { return $false }
  }

  if ($Account) {
    if ($accts -notcontains $Account) { Fail "Account '$Account' isn't signed in. Signed in: $($accts -join ', ')"; return $false }
    $Config.ActiveAccount = $Account    # this run only; not saved
  } elseif (-not ($Config.ActiveAccount -and ($accts -contains $Config.ActiveAccount))) {
    if ($accts.Count -eq 1 -or $script:Quiet) { $Config.ActiveAccount = $accts[0] }
    else {
      $login = Select-Account "Which GitHub account do you want to use?"
      $Config.ActiveAccount = if ($login) { $login } else { $accts[0] }
    }
    Save-Config
  }

  Use-Account $Config.ActiveAccount
  if (-not $env:GH_TOKEN) {
    Fail "Couldn't get a sign-in token for $($Config.ActiveAccount)."
    Fail "Update GitHub CLI (winget upgrade --id GitHub.cli) or sign in again (gh auth login)."
    return $false
  }

  # Having a saved token doesn't mean GitHub still accepts it
  if ((Get-SignInState) -eq "expired") {
    Fail "GitHub no longer accepts the sign-in for $($Config.ActiveAccount) (it expired or was revoked)."
    if ($script:Quiet) { Fail "Run the script without options once and sign in again."; return $false }
    if ((Read-Host "Sign in again now? (y/n)") -ne "y") { return $false }
    Add-Account
    if ((Get-SignInState) -eq "expired") { Fail "The sign-in still isn't accepted."; return $false }
  }
  return $true
}

# Asks GitHub whether the current token works: "ok", "expired", or "unknown"
# (unknown = couldn't tell, e.g. no network; a warning is shown and the script carries on)
function Get-SignInState {
  $out = @(gh api user --jq .login 2>&1 | ForEach-Object { "$_" })
  if ($LASTEXITCODE -eq 0) { return "ok" }
  $msg = $out -join " "
  if ($msg -match 'HTTP 401|Bad credentials') { return "expired" }
  Warn "Couldn't check the GitHub sign-in: $(@($out)[0])"
  return "unknown"
}

# Older versions stored bare repo names (e.g. "my-repo"). Convert them to owner/repo.
function Update-OldKeys {
  $Config.Repos = @($Config.Repos | ForEach-Object { ConvertTo-FullKey $_ } | Where-Object { $_ })
  foreach ($section in "Runners", "Labels", "RunnerAccounts") {
    $fixed = @{}
    foreach ($k in @($Config[$section].Keys)) { $fixed[(ConvertTo-FullKey $k)] = $Config[$section][$k] }
    $Config[$section] = $fixed
  }
  Save-Config
}

# Checks the repo/org exists and the managing account can manage its runners
function Test-Access($key) {
  Use-KeyAccount $key
  $login = Get-KeyAccount $key
  if (Test-IsOrg $key) {
    gh api "$(Get-ApiBase $key)/actions/runners" *> $null
    if ($LASTEXITCODE -ne 0) {
      Fail "$login can't manage runners for organization '$(Get-OrgName $key)'."
      Fail "You must be an owner of the org, and the account needs organization permission"
      Fail "(main menu > A > 'Let an account manage organization runners')."
      return $false
    }
    return $true
  }
  # Never put double quotes in a jq filter here: Windows PowerShell 5.1 drops them when it
  # passes arguments to programs, which breaks the filter. This one prints two lines.
  $info = @(gh api "repos/$key" --jq '.permissions.admin, .private' 2>$null)
  if ($LASTEXITCODE -ne 0 -or $info.Count -lt 2) { Fail "Repo $key not found (or $login can't see it). Check the name."; return $false }
  $admin = "$($info[0])".Trim(); $private = "$($info[1])".Trim()
  if ($admin -ne "true") { Fail "$login needs admin access to $key to manage its runner."; return $false }
  if ($private -ne "true" -and -not (Confirm-PublicRepo $key)) { return $false }
  return $true
}

# A runner on a public repo lets anyone who opens a pull request from a fork run code on this machine
function Confirm-PublicRepo($key) {
  Warn "WARNING: $key is a PUBLIC repo."
  Warn "Anyone can fork it and open a pull request whose workflow runs on this machine,"
  Warn "with access to its files and network. GitHub advises against self-hosted runners on public repos."
  if ($script:Quiet) {
    Fail "Not adding a runner to a public repo in command-line mode. Run the script without options to confirm."
    return $false
  }
  return ((Read-Host "Type 'public' to add the runner anyway, or press Enter to cancel") -eq "public")
}

# =====================================================================
#  Folders
# =====================================================================
function Test-FolderChoice($path) {
  if ($path -match '^[A-Za-z]:$') { Fail "Please choose a folder, not a whole drive (e.g. D:\runners)."; return $false }
  if ($path -notmatch '^[A-Za-z]:\\') { Fail "Please enter a full path with a drive letter, like D:\runners"; return $false }

  $drive = $path.Substring(0, 3)
  if (-not (Test-Path $drive)) { Fail "Drive $drive does not exist on this computer."; return $false }

  $warnings = @()
  if ($path -match '\s')   { $warnings += "The path has spaces. Some build tools break on paths with spaces." }
  if ($path.Length -gt 60) { $warnings += "The path is long. Deep node_modules folders may hit Windows' path length limit." }

  foreach ($w in $warnings) { Warn "Warning: $w" }
  if ($warnings.Count -gt 0 -and -not $script:Quiet) {
    if ((Read-Host "Use this folder anyway? (y/n)") -ne "y") { return $false }
  }
  return $true
}

function Read-Folder($prompt, $default) {
  $answer = Read-Host "$prompt [Enter = $default]"
  if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $default }
  $answer = $answer.Trim().Trim('"').TrimEnd('\')   # handles "Copy as path" quotes from Explorer
  if (Test-FolderChoice $answer) { return $answer }
  return $null
}

function Test-FolderEmpty($dir) {
  if (-not (Test-Path $dir)) { return $true }
  return -not (Get-ChildItem $dir -Force | Select-Object -First 1)
}

function Get-FolderSizeMB($path) {
  if (-not (Test-Path $path)) { return 0 }
  $sum = (Get-ChildItem $path -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
  return [math]::Round(($sum / 1MB), 1)
}

# Deletes a runner folder. Refuses system and profile folders (see Get-ProtectedReason)
# and anything that doesn't look like a runner folder (no config.cmd or .runner inside).
function Remove-FolderFully($dir) {
  if (-not (Test-Path -LiteralPath $dir)) { return $true }
  $why = Get-ProtectedReason $dir
  if ($why) { Fail "Refusing to delete $dir ($why)."; return $false }
  if (-not (Test-Path -LiteralPath (Join-Path $dir "config.cmd")) -and -not (Test-Path -LiteralPath (Join-Path $dir ".runner"))) {
    Fail "Refusing to delete ${dir}: it doesn't look like a runner folder."; return $false
  }
  Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
  if (Test-Path $dir) { cmd /c rd /s /q "\\?\$dir" 2>$null }   # handles very long paths
  return -not (Test-Path $dir)
}

# Asks where to put one or more runners. Returns key -> folder, or $null if cancelled.
function Get-FolderPlan($keys) {
  $keys = @($keys)
  $plan = [ordered]@{}
  if ($keys.Count -eq 1) {
    $d = Read-Folder "Folder for the $(Get-DisplayName $keys[0]) runner" (Get-DefaultDir $keys[0])
    if (-not $d) { return $null }
    $plan[$keys[0]] = $d
    return $plan
  }
  $useDefault = Read-Host "Put all $($keys.Count) runners under $($Config.RunnersRoot)? (y = yes, n = choose a folder for each)"
  foreach ($key in $keys) {
    if ($useDefault -eq "y") { $plan[$key] = Get-DefaultDir $key }
    else {
      $d = Read-Folder "Folder for the $(Get-DisplayName $key) runner" (Get-DefaultDir $key)
      if (-not $d) { Info "Cancelled. Nothing was changed."; return $null }
      $plan[$key] = $d
    }
  }
  return $plan
}

# =====================================================================
#  Finding runners on this machine
# =====================================================================
function Reset-MachineCache { $script:MachineCache = $null; $script:FolderCache = $null }

function Read-RunnerFile($dir) {
  $f = Join-Path $dir ".runner"
  if (-not (Test-Path $f)) { return $null }
  try { return (Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Get-ServiceFolderFromCim($cim) {
  if (-not $cim.PathName) { return $null }
  $exe = if ($cim.PathName -match '^"([^"]+)"') { $Matches[1] } else { ($cim.PathName -split ' ')[0] }
  return Split-Path (Split-Path $exe -Parent) -Parent    # ...\<runner>\bin\RunnerService.exe -> ...\<runner>
}

function Get-RunnerServicesCim {
  @(Get-CimInstance Win32_Service -Filter "Name LIKE 'actions.runner.%'" -ErrorAction SilentlyContinue)
}

# Installed runners (have a Windows service): key -> Folder, ServiceName, Name
function Get-MachineRunners {
  if ($script:MachineCache) { return $script:MachineCache }
  $map = @{}
  foreach ($cim in Get-RunnerServicesCim) {
    $dir = Get-ServiceFolderFromCim $cim
    if (-not $dir) { continue }
    $info = Read-RunnerFile $dir
    if (-not $info) { continue }
    $key = ConvertFrom-GitHubUrl $info.gitHubUrl
    if (-not $key) { continue }
    $map[$key] = [pscustomobject]@{ Key = $key; ServiceName = $cim.Name; Folder = $dir; Name = $info.agentName }
  }
  $script:MachineCache = $map
  return $map
}

function Get-KeyForFolder($dir, $relName) {
  $info = Read-RunnerFile $dir
  if ($info) { $k = ConvertFrom-GitHubUrl $info.gitHubUrl; if ($k) { return $k } }
  if ($relName -like "org-*") { return "org:" + $relName.Substring(4) }
  return ConvertTo-FullKey $relName
}

# Runner folders inside the default folder (one or two levels deep), installed or not
function Get-FolderRunners {
  if ($null -ne $script:FolderCache) { return $script:FolderCache }
  $result = @()
  if (Test-Path $Config.RunnersRoot) {
    foreach ($d in Get-ChildItem $Config.RunnersRoot -Directory -ErrorAction SilentlyContinue) {
      if (Test-Path (Join-Path $d.FullName "config.cmd")) {
        $result += [pscustomobject]@{ Key = (Get-KeyForFolder $d.FullName $d.Name); Folder = $d.FullName }
        continue
      }
      foreach ($sub in Get-ChildItem $d.FullName -Directory -ErrorAction SilentlyContinue) {
        if (Test-Path (Join-Path $sub.FullName "config.cmd")) {
          $result += [pscustomobject]@{ Key = (Get-KeyForFolder $sub.FullName "$($d.Name)/$($sub.Name)"); Folder = $sub.FullName }
        }
      }
    }
  }
  $script:FolderCache = $result
  return $result
}

function Get-RunnerService($key) {
  $m = (Get-MachineRunners)[$key]
  if (-not $m) { return $null }
  return Get-Service -Name $m.ServiceName -ErrorAction SilentlyContinue
}

# Where a runner lives: installed location > saved location > found folder > default folder
function Get-RunnerDir($key) {
  $m = (Get-MachineRunners)[$key]
  if ($m) { return $m.Folder }
  if ($Config.Runners.ContainsKey($key)) { return $Config.Runners[$key] }
  $f = @(Get-FolderRunners | Where-Object { $_.Key -eq $key }) | Select-Object -First 1
  if ($f) { return $f.Folder }
  return Get-DefaultDir $key
}

function Get-RunnerName($key) {
  $m = (Get-MachineRunners)[$key]
  if ($m -and $m.Name) { return $m.Name }
  return Get-NewRunnerName $key
}

# Every runner we know about: your list + saved + installed + found in the default folder
function Get-AllRunnerNames {
  $names = @($Config.Repos) + @($Config.Runners.Keys) + @((Get-MachineRunners).Keys) +
           @(Get-FolderRunners | ForEach-Object { $_.Key })
  $names | Where-Object { $_ } | Sort-Object -Unique
}

function Get-InstalledRunners { @(Get-AllRunnerNames | Where-Object { Get-RunnerService $_ }) }

# The runner as GitHub sees it (status, busy, labels, id), or $null
function Get-GitHubRunner($key, $name) {
  if (-not $name) { $name = Get-RunnerName $key }
  Use-KeyAccount $key
  $json = (gh api "$(Get-ApiBase $key)/actions/runners?per_page=100" 2>$null) -join "`n"
  if ($LASTEXITCODE -ne 0 -or -not $json) { return $null }
  return ($json | ConvertFrom-Json).runners | Where-Object { $_.name -eq $name } | Select-Object -First 1
}

function Get-SavedLabels($key) {
  if ($Config.Labels.ContainsKey($key) -and $Config.Labels[$key]) {
    return @($Config.Labels[$key] -split ',' | Where-Object { $_ })
  }
  return @()
}

# Numbered list of runners. Returns the chosen key(s). -AllowAll adds an "All" choice.
function Select-Runner($title, [switch]$AllowAll) {
  $names = @(Get-AllRunnerNames)
  if ($names.Count -eq 0) { Warn "No runners yet. Use option 2 to add one."; return @() }

  Write-Host ""
  Write-Host $title
  for ($i = 0; $i -lt $names.Count; $i++) {
    $svc   = Get-RunnerService $names[$i]
    $state = if ($svc) { $svc.Status } else { "Not installed" }
    Write-Host ("  {0}) {1}  [{2}]  {3}" -f ($i + 1), (Get-DisplayName $names[$i]), $state, (Get-RunnerDir $names[$i]))
  }
  if ($AllowAll) { Write-Host "  A) All installed runners" }

  $choice = Read-Host "Choose (or press Enter to cancel)"
  if ([string]::IsNullOrWhiteSpace($choice)) { return @() }
  if ($AllowAll -and $choice -eq "a") { return Get-InstalledRunners }
  $n = 0
  if ([int]::TryParse($choice, [ref]$n) -and $n -ge 1 -and $n -le $names.Count) { return @($names[$n - 1]) }
  Warn "Invalid choice."
  return @()
}

# Lists repos the active account can manage and lets you pick several
function Select-Repos {
  $owner = Read-Host "Whose repos? GitHub user or org name [Enter = $($Config.ActiveAccount)]"
  if ([string]::IsNullOrWhiteSpace($owner)) { $owner = $Config.ActiveAccount }
  Use-Account $Config.ActiveAccount
  Info "Loading repos where $($Config.ActiveAccount) is an admin..."
  # Keep gh's error message so a failed call (expired sign-in, no network,
  # unknown owner) says why instead of just failing
  $out = @(gh repo list $owner.Trim() --limit 300 --json "nameWithOwner,viewerPermission,isArchived" 2>&1)
  $code = $LASTEXITCODE
  $errType = [System.Management.Automation.ErrorRecord]
  $json = @($out | Where-Object { $_ -isnot $errType } | ForEach-Object { "$_" }) -join "`n"
  if ($code -ne 0 -or -not $json) {
    Fail "Could not list repos for $owner."
    $why = @($out | Where-Object { $_ -is $errType } | ForEach-Object { "$_" } | Select-Object -First 3) -join " "
    if ($why) { Write-Host "  GitHub CLI said: $why" -ForegroundColor DarkGray }
    return @()
  }

  # Parentheses matter: Windows PowerShell 5.1 passes the parsed JSON array down the
  # pipeline as ONE object, so without them the filter below sees the whole list at once.
  $repos = @(($json | ConvertFrom-Json) |
    Where-Object { $_.viewerPermission -eq "ADMIN" -and -not $_.isArchived } |
    ForEach-Object { $_.nameWithOwner } | Sort-Object)
  if ($repos.Count -eq 0) { Warn "No repos found where $($Config.ActiveAccount) is an admin."; return @() }

  Write-Host ""
  for ($i = 0; $i -lt $repos.Count; $i++) {
    $mark = if (Get-RunnerService $repos[$i]) { "  [already installed]" } else { "" }
    Write-Host ("  {0,3}) {1}{2}" -f ($i + 1), $repos[$i], $mark)
  }
  $answer = Read-Host "Choose numbers (e.g. 1,3,5 or 2-4 or all), or Enter to cancel"
  if ([string]::IsNullOrWhiteSpace($answer)) { return @() }
  $picked = @(Read-NumberList $answer.Trim().ToLower() $repos.Count | ForEach-Object { $repos[$_ - 1] })
  if ($picked.Count -eq 0) { Warn "Nothing selected." }
  return $picked
}

# For command-line mode: "all" or one runner
function Resolve-Targets($name) {
  if ($name -eq "all") { return Get-InstalledRunners }
  return @(ConvertTo-FullKey $name)
}

# =====================================================================
#  Folder permissions
#  Folders created under C:\ let every signed-in user change files in them. This script
#  runs as Administrator and runner services run its runner folders' programs, so those
#  folders must only be writable by Administrators, SYSTEM and the runner's service account.
# =====================================================================
# Everyone, Authenticated Users, Users, INTERACTIVE
$script:BroadSids = @("S-1-1-0", "S-1-5-11", "S-1-5-32-545", "S-1-5-4")

# The account runner services run as, in a form icacls accepts
function Get-ServiceIdentity {
  if (-not $Config.ServiceAccount) { return "*S-1-5-20" }   # NETWORK SERVICE
  if ($Config.ServiceAccount -like ".\*") { return "$env:COMPUTERNAME\$($Config.ServiceAccount.Substring(2))" }
  return $Config.ServiceAccount
}

# True if any ordinary user of this PC can change files in $path
function Test-WritableByOthers($path) {
  if (-not (Test-Path -LiteralPath $path)) { return $false }
  try { $acl = Get-Acl -LiteralPath $path } catch { return $false }
  $write = [Security.AccessControl.FileSystemRights]"WriteData, AppendData, WriteAttributes, WriteExtendedAttributes, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership"
  foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
    if ($rule.AccessControlType -ne "Allow") { continue }
    if ($script:BroadSids -notcontains $rule.IdentityReference.Value) { continue }
    if (($rule.FileSystemRights -band $write) -ne 0) { return $true }
  }
  return $false
}

# Why $path must never be deleted or have its permissions replaced (or $null if it's fine):
# drive roots, Windows, Program Files, ProgramData, the Users folder and user profiles
function Get-ProtectedReason($path) {
  if (-not $path) { return "the path is empty" }
  try { $full = [IO.Path]::GetFullPath($path).TrimEnd('\') } catch { return "the path isn't valid" }
  if ($full -match '^[A-Za-z]:$' -or $full -like '\\*') { return "it's a whole drive or a network path" }
  $exact = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:PUBLIC,
             (Split-Path $env:USERPROFILE -Parent)) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
  if ($exact -contains $full) { return "it's a Windows system folder" }
  if ($env:SystemRoot -and ($full -eq $env:SystemRoot.TrimEnd('\') -or $full -like "$($env:SystemRoot.TrimEnd('\'))\*")) { return "it's inside the Windows folder" }
  # A user profile folder itself (C:\Users\name), or anything that contains this user's profile
  $usersRoot = (Split-Path $env:USERPROFILE -Parent).TrimEnd('\')
  if ((Split-Path $full -Parent) -eq $usersRoot) { return "it's a user profile folder" }
  if ("$($env:USERPROFILE.TrimEnd('\'))\" -like "$full\*") { return "it contains your user profile" }
  return $null
}

# True if $path holds nothing but files matching $names, so changing its permissions affects nothing else
function Test-OnlyOurFiles($path, $names) {
  foreach ($i in Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue) {
    if (-not ($names | Where-Object { $i.Name -like $_ })) { return $false }
  }
  return $true
}

# Limits $path to Administrators and SYSTEM (full control), plus $writers (modify).
# Files inside get the same permissions. Returns $true on success.
function Protect-Folder($path, $writers = @()) {
  $why = Get-ProtectedReason $path
  if ($why) { Warn "Not changing permissions of $path ($why)."; return $false }
  New-Item -ItemType Directory -Force -Path $path | Out-Null
  $icaclsArgs = @($path, "/inheritance:r", "/grant:r", "*S-1-5-32-544:(OI)(CI)F", "*S-1-5-18:(OI)(CI)F")
  foreach ($w in $writers) { $icaclsArgs += "$($w):(OI)(CI)M" }
  & icacls @icaclsArgs /Q | Out-Null
  if ($LASTEXITCODE -ne 0) { Warn "Couldn't limit who can change files in $path."; return $false }
  # Make everything already inside follow the folder's new permissions
  if (Get-ChildItem -LiteralPath $path -Force | Select-Object -First 1) {
    & icacls (Join-Path $path "*") /reset /T /C /Q | Out-Null
  }
  return $true
}

# The folders that matter: this script's own folder, the runner download folder and each runner folder.
# Returns a list of @{ Path; Writers; What }
# Names = what a folder may hold for us to safely lock it down ($null = anything; runner folders)
$script:ScriptFolderFiles = @("runner-manager.ps1", "runner-manager.sh", "runners-config.json", "runner-manager.conf",
                              "README.md", "LICENSE", ".git", ".gitattributes", ".gitignore")
$script:ZipFolderFiles    = @("*.zip", "*.zip.part")

function Get-SensitiveFolders {
  $list = @(
    @{ Path = $ScriptDir; Writers = @(); Names = $script:ScriptFolderFiles; What = "this script and its settings" },
    @{ Path = (Split-Path $Config.ZipPath -Parent); Writers = @(); Names = $script:ZipFolderFiles; What = "the runner download" }
  )
  foreach ($key in Get-AllRunnerNames) {
    $dir = Get-RunnerDir $key
    if (Test-Path -LiteralPath $dir) { $list += @{ Path = $dir; Writers = @(Get-RunnerServiceIdentity $key); Names = $null; What = "runner $(Get-DisplayName $key)" } }
  }
  return $list
}

# The account an installed runner's service really runs as (it may predate a change in Settings)
function Get-RunnerServiceIdentity($key) {
  $m = (Get-MachineRunners)[$key]
  if (-not $m) { return (Get-ServiceIdentity) }
  $cim = Get-CimInstance Win32_Service -Filter "Name='$($m.ServiceName)'" -ErrorAction SilentlyContinue
  $who = "$($cim.StartName)"
  if (-not $who -or $who -match 'NETWORK ?SERVICE') { return "*S-1-5-20" }
  if ($who -eq "LocalSystem") { return "*S-1-5-18" }
  if ($who -like ".\*") { return "$env:COMPUTERNAME\$($who.Substring(2))" }
  return $who
}

# Locks down one folder after asking. A folder that also holds other things isn't changed;
# you're asked to move our files to a folder of their own instead.
function Repair-OneFolder($f) {
  Warn "  Other users of this PC can change files in $($f.Path) ($($f.What))."
  if ($f.Names -and -not (Test-OnlyOurFiles $f.Path $f.Names)) {
    Warn "  That folder holds other files too, so its permissions weren't changed. Move $($f.What) to a"
    Warn "  folder of its own that only Administrators can change, e.g. $env:ProgramFiles\runner-manager."
    return
  }
  if (Confirm-Fix "Allow only Administrators$(if ($f.Writers.Count) { ' and the runner service' }) to change it?") {
    if (Protect-Folder $f.Path $f.Writers) { Ok "  Done." }
  }
}

# Reports folders other users can change, and offers to lock them down
function Repair-FolderPermissions {
  $found = 0
  foreach ($f in Get-SensitiveFolders) {
    if (-not (Test-WritableByOthers $f.Path)) { continue }
    $found++
    Repair-OneFolder $f
  }
  if ($found -eq 0) { Ok "  Folder permissions: only Administrators can change the script, download and runner folders" }
}

# Creates the runner download folder locked down, and won't trust a saved download in a folder others can change
function Initialize-ZipFolder {
  $dir = Split-Path $Config.ZipPath -Parent
  if (-not (Test-Path -LiteralPath $dir)) { Protect-Folder $dir | Out-Null; return }
  if (-not (Test-WritableByOthers $dir)) { return }
  if (Test-OnlyOurFiles $dir $script:ZipFolderFiles) { Protect-Folder $dir | Out-Null }
  else { Warn "Other users of this PC can change files in $dir. Choose a folder of its own for the runner download (Settings)." }
}

# =====================================================================
#  Runner download
# =====================================================================
# Every runner zip is checked against a SHA-256 checksum before it's used. The checksum comes
# from GitHub's release data when the file is an official release, otherwise you paste it.
function Test-RunnerArchive($file, $sum) {
  if ("$sum" -notmatch '([0-9a-fA-F]{64})') { Fail "No checksum to check the file against. The file was not used."; return $false }
  $expected = $Matches[1]
  $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
  if ($actual -ne $expected) { Fail "Checksum doesn't match. The file was not used."; return $false }
  Ok "Checksum OK."
  try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($file)
    $hasConfig = @($zip.Entries | Where-Object { $_.FullName -eq "config.cmd" }).Count -gt 0
    $zip.Dispose()
  } catch {
    Fail "That file isn't a valid zip archive."; return $false
  }
  if (-not $hasConfig) { Fail "That zip doesn't look like a GitHub runner (no config.cmd inside)."; return $false }
  return $true
}

# GitHub's published SHA-256 for an official runner file name, e.g.
# actions-runner-win-x64-2.330.0.zip ($null if it isn't an official file)
function Get-OfficialDigest($name) {
  if ($name -notmatch '^actions-runner-[a-z0-9]+-[a-z0-9]+-(\d+\.\d+\.\d+)\.zip$') { return $null }
  $json = (gh api "repos/actions/runner/releases/tags/v$($Matches[1])" 2>$null) -join "`n"
  if ($LASTEXITCODE -ne 0 -or -not $json) { return $null }
  $asset = ($json | ConvertFrom-Json).assets | Where-Object { $_.name -eq $name } | Select-Object -First 1
  if (-not $asset -or -not $asset.digest) { return $null }
  return ($asset.digest -replace '^sha256:', '')
}

# The checksum for a file you supplied: GitHub's own if it's an official release, else you paste one
function Get-ChecksumFor($name) {
  $sum = Get-OfficialDigest $name
  if ($sum) { Info "Using GitHub's published checksum for $name."; return $sum }
  Warn "$name isn't a file name from GitHub's runner releases, so its checksum can't be looked up."
  return (Read-Host "SHA-256 checksum to verify (required; from the release page or whoever gave you the file)")
}

function Get-LatestRunnerZip {
  Info "Finding the latest GitHub runner ($RunnerPlatform)..."
  $json = (gh api repos/actions/runner/releases/latest 2>$null) -join "`n"
  if ($LASTEXITCODE -ne 0) { Fail "Could not check the latest runner version."; return $false }

  $asset = ($json | ConvertFrom-Json).assets |
    Where-Object { $_.name -match "^actions-runner-$RunnerPlatform-[\d.]+\.zip$" } | Select-Object -First 1
  if (-not $asset) { Fail "Could not find the $RunnerPlatform runner download."; return $false }
  if (-not $asset.digest) { Fail "GitHub didn't publish a checksum for $($asset.name), so it can't be verified."; return $false }

  Initialize-ZipFolder
  $part = "$($Config.ZipPath).part"
  Info "Downloading $($asset.name)..."
  try { Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $part -UseBasicParsing }
  catch { Fail "Download failed: $($_.Exception.Message)"; Remove-Item $part -Force -ErrorAction SilentlyContinue; return $false }
  if (-not (Test-RunnerArchive $part $asset.digest)) { Remove-Item $part -Force -ErrorAction SilentlyContinue; return $false }
  Move-Item $part $Config.ZipPath -Force
  Ok "Saved to $($Config.ZipPath)"
  return $true
}

function Get-RunnerZipFromLink {
  Info "Copy the link from a repo's Settings > Actions > Runners > New self-hosted runner"
  Info "(choose Windows, $($RunnerPlatform.Substring(4))), or from https://github.com/actions/runner/releases"
  $url = "$(Read-Host 'Download link')".Trim().Trim('"')
  if ($url -notmatch '^https://') { Fail "The link should start with https://"; return $false }
  $official = $url -like "https://github.com/actions/runner/releases/download/*"
  if (-not $official) { Warn "This link isn't from github.com/actions/runner/releases. You'll need the file's SHA-256 checksum." }
  if ($url -notmatch "actions-runner-$RunnerPlatform-") {
    Warn "This link doesn't look like the $RunnerPlatform runner (expected 'actions-runner-$RunnerPlatform-' in it)."
    if ((Read-Host "Use it anyway? (y/n)") -ne "y") { return $false }
  }
  # Only trust GitHub's published checksum when the file really comes from GitHub's releases
  $sum = if ($official) { Get-ChecksumFor (Split-Path ($url -replace '\?.*$', '') -Leaf) }
         else           { Read-Host "SHA-256 checksum to verify (required)" }
  if ([string]::IsNullOrWhiteSpace($sum)) { Fail "A checksum is needed to use this file."; return $false }

  Initialize-ZipFolder
  $part = "$($Config.ZipPath).part"
  Info "Downloading..."
  try { Invoke-WebRequest -Uri $url -OutFile $part -UseBasicParsing }
  catch { Fail "Download failed. Check the link. ($($_.Exception.Message))"; Remove-Item $part -Force -ErrorAction SilentlyContinue; return $false }

  if (-not (Test-RunnerArchive $part $sum)) { Remove-Item $part -Force -ErrorAction SilentlyContinue; return $false }
  Move-Item $part $Config.ZipPath -Force
  Ok "Saved to $($Config.ZipPath)"
  return $true
}

function Get-RunnerZipFromFile {
  $src = "$(Read-Host 'Path to the runner .zip file')".Trim().Trim('"')
  if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { Fail "File not found: $src"; return $false }
  $sum = Get-ChecksumFor (Split-Path $src -Leaf)
  if ([string]::IsNullOrWhiteSpace($sum)) { Fail "A checksum is needed to use this file."; return $false }
  if (-not (Test-RunnerArchive $src $sum)) { return $false }
  Initialize-ZipFolder
  Copy-Item -LiteralPath $src $Config.ZipPath -Force
  Unblock-File $Config.ZipPath -ErrorAction SilentlyContinue   # files downloaded in a browser are marked as "from the internet"
  Ok "Copied to $($Config.ZipPath)"
  return $true
}

# Makes sure the runner zip is there: download it, use a link you paste, or a file you have
function Get-RunnerZip {
  if (Test-Path $Config.ZipPath) {
    # A saved download in a folder other users can change may have been swapped; get a fresh one
    if (-not (Test-WritableByOthers (Split-Path $Config.ZipPath -Parent))) { return $true }
    Warn "Other users of this PC could have changed the saved runner download. Getting a fresh, verified copy."
    Remove-Item -LiteralPath $Config.ZipPath -Force -ErrorAction SilentlyContinue
  }
  if ($script:Quiet) { return (Get-LatestRunnerZip) }

  Warn "The runner download ($RunnerPlatform) wasn't found at:"
  Warn "  $($Config.ZipPath)"
  Write-Host "  1) Download the latest version automatically"
  Write-Host "  2) Paste a download link"
  Write-Host "  3) Use a file already on this computer"
  switch (Read-Host "Choose (or Enter to cancel)") {
    "1" { return (Get-LatestRunnerZip) }
    "2" { return (Get-RunnerZipFromLink) }
    "3" { return (Get-RunnerZipFromFile) }
    default { return $false }
  }
}

# =====================================================================
#  Windows service account
# =====================================================================
function Get-ServicePassword {
  if (-not $script:ServicePassword) {
    Info "Enter the Windows password for $($Config.ServiceAccount) (your account password, not your PIN)."
    $sec  = Read-Host "Password" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try     { $script:ServicePassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
  }
  return $script:ServicePassword
}

function Get-AccountLabel { if ($Config.ServiceAccount) { $Config.ServiceAccount } else { "NETWORK SERVICE (default)" } }

# =====================================================================
#  Status
# =====================================================================
function Show-Status {
  Write-Host ""
  Info "Active account: $($Config.ActiveAccount)    Default folder: $($Config.RunnersRoot)    Runs as: $(Get-AccountLabel)"
  Info "Checking GitHub..."
  $fmt = "{0,-28} {1,-14} {2,-13} {3,-8} {4,-16} {5}"
  Write-Host ($fmt -f "Runner", "Account", "Service", "GitHub", "Labels", "Folder")
  Write-Host ($fmt -f "------", "-------", "-------", "------", "------", "------")
  foreach ($key in Get-AllRunnerNames) {
    $dir   = Get-RunnerDir $key
    $svc   = Get-RunnerService $key
    $state = if ($svc) { $svc.Status.ToString() } else { "Not installed" }
    $gr    = Get-GitHubRunner $key
    $ghState = if (-not $gr) { "-" } elseif ($gr.status -ne "online") { "Offline" } elseif ($gr.busy) { "Busy" } else { "Online" }
    $labels  = if ($gr) { @($gr.labels | Where-Object { $_.type -eq "custom" } | ForEach-Object { $_.name }) -join "," }
               else     { (Get-SavedLabels $key) -join "," }
    if (-not $labels) { $labels = "-" }
    $color = if ($ghState -eq "Online" -or $ghState -eq "Busy") { "Green" } elseif ($svc) { "Yellow" } else { "DarkGray" }
    Write-Host ($fmt -f (Get-DisplayName $key), (Get-KeyAccount $key), $state, $ghState, $labels, $dir) -ForegroundColor $color
  }
  Write-Host ""
  Write-Host "GitHub: Online = ready, Busy = running a job, Offline = not connected, - = not set up" -ForegroundColor DarkGray
}

# =====================================================================
#  Add / remove / move
# =====================================================================
# Sets up a runner in folder $dir. Returns $true on success.
function Install-Runner($key, $dir) {
  $label = Get-DisplayName $key
  if (Get-RunnerService $key) {
    Warn "$label is already installed on this machine ($(Get-RunnerDir $key)). Remove it first to set it up again."
    return $false
  }
  if (Test-Path (Join-Path $dir ".runner")) {
    Warn "$dir already has a configured runner. Remove it first, or choose another folder."
    return $false
  }
  if (-not (Test-FolderEmpty $dir) -and -not (Test-Path (Join-Path $dir "config.cmd"))) {
    Warn "$dir already has other files in it. Use an empty folder or a new folder name."
    return $false
  }
  if (-not (Test-Access $key)) { return $false }
  if (-not (Get-RunnerZip)) { return $false }

  $extra = @()
  $labels = @(Get-SavedLabels $key)
  if ($labels.Count) { $extra += @("--labels", ($labels -join ",")) }
  $pw = $null
  if ($Config.ServiceAccount) {
    $pw = Get-ServicePassword
    if (-not $pw) { Fail "No password entered."; return $false }
    $extra += @("--windowslogonaccount", $Config.ServiceAccount)
  }

  Info "Setting up $label in $dir (as $(Get-KeyAccount $key)) ..."
  Use-KeyAccount $key
  $token = gh api -X POST "$(Get-ApiBase $key)/actions/runners/registration-token" --jq .token 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $token) { Fail "Could not get a registration token for $label."; return $false }

  # Only Administrators, SYSTEM and the runner service may change the runner's files
  if (-not (Protect-Folder $dir @(Get-ServiceIdentity))) { Fail "Setup stopped: couldn't secure $dir."; return $false }
  Expand-Archive $Config.ZipPath -DestinationPath $dir -Force

  # The token and password go in the environment, not on the command line, where Windows
  # process logging and security tools would record them. The runner reads
  # ACTIONS_RUNNER_INPUT_<option> and removes it from its environment.
  $env:ACTIONS_RUNNER_INPUT_TOKEN = $token
  if ($pw) { $env:ACTIONS_RUNNER_INPUT_WINDOWSLOGONPASSWORD = $pw }
  Push-Location $dir
  try {
    & .\config.cmd --unattended --url (Get-TargetUrl $key) `
      --name (Get-NewRunnerName $key) --runasservice --replace @extra | Out-Host
    $code = $LASTEXITCODE
  } finally {
    Pop-Location
    Remove-Item Env:ACTIONS_RUNNER_INPUT_TOKEN, Env:ACTIONS_RUNNER_INPUT_WINDOWSLOGONPASSWORD -ErrorAction SilentlyContinue
  }
  Reset-MachineCache

  if ($code -ne 0) {
    Fail "Setup failed for $label (see messages above)."
    if ($Config.ServiceAccount) {
      $script:ServicePassword = $null
      Warn "If the error mentions logon or password, the password may be wrong. You'll be asked again next time."
    }
    return $false
  }

  $Config.Runners[$key] = $dir
  $Config.RunnerAccounts[$key] = Get-KeyAccount $key
  Save-Config
  Ok "Done: $label  ->  $dir"
  return $true
}

# -Forget also drops which account manages it (use when removing for good)
function Remove-Runner($key, [switch]$Forget) {
  $label = Get-DisplayName $key
  $dir   = Get-RunnerDir $key
  $name  = Get-RunnerName $key
  Info "Removing $label ($dir)..."
  Use-KeyAccount $key

  # 1. Normal way: unregister from GitHub and uninstall the service
  if (Test-Path (Join-Path $dir ".runner")) {
    $token = gh api -X POST "$(Get-ApiBase $key)/actions/runners/remove-token" --jq .token 2>$null
    if ($LASTEXITCODE -eq 0 -and $token) {
      $env:ACTIONS_RUNNER_INPUT_TOKEN = $token   # not on the command line (see Install-Runner)
      Push-Location $dir
      try { & .\config.cmd remove | Out-Host }
      finally { Pop-Location; Remove-Item Env:ACTIONS_RUNNER_INPUT_TOKEN -ErrorAction SilentlyContinue }
    }
  }

  # 2. Clean up anything left behind: the Windows service...
  $svc = Get-RunnerService $key
  if ($svc) {
    Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
    sc.exe delete $svc.Name | Out-Null
  }

  # ...the runner entry on GitHub...
  $gr = Get-GitHubRunner $key $name
  if ($gr) { gh api -X DELETE "$(Get-ApiBase $key)/actions/runners/$($gr.id)" *> $null }

  # ...the folder...
  if (Test-Path $dir) {
    Start-Sleep -Seconds 2
    if (-not (Remove-FolderFully $dir)) { Warn "Could not fully delete $dir. Close any open files there and delete it manually." }
  }

  # ...and the saved details (labels are kept, so a re-install gets them back)
  if ($Config.Runners.ContainsKey($key)) { $Config.Runners.Remove($key) }
  if ($Forget -and $Config.RunnerAccounts.ContainsKey($key)) { $Config.RunnerAccounts.Remove($key) }
  Save-Config
  Reset-MachineCache
  Ok "Removed: $label"
}

function Add-Runners {
  Write-Host ""
  Info "Adding runners as $($Config.ActiveAccount)  (to use another account, press A in the main menu)"
  Write-Host "  1) Pick from a list of repos"
  Write-Host "  2) Type a repo (name, owner/name or GitHub URL)"
  Write-Host "  3) Organization runner (one runner shared by all the org's repos)"
  $keys = @()
  switch (Read-Host "Choose (or Enter to cancel)") {
    "1" { $keys = @(Select-Repos) }
    "2" {
      $typed = Read-Host "Repo"
      if ($typed) { $keys = @(ConvertTo-FullKey $typed) }
    }
    "3" {
      $typed = Read-Host "Organization name (as in github.com/<name>)"
      if ($typed) { $keys = @("org:" + $typed.Trim()) }
    }
    default { return }
  }
  $keys = @($keys | Where-Object { $_ })
  if ($keys.Count -eq 0) { return }

  $plan = Get-FolderPlan $keys
  if (-not $plan) { return }
  if ($Config.ServiceAccount -and -not (Get-ServicePassword)) { return }

  $added = @()
  foreach ($key in @($plan.Keys)) {
    if (-not (Get-RunnerService $key)) { $Config.RunnerAccounts[$key] = $Config.ActiveAccount }
    if (Install-Runner $key $plan[$key]) { $added += $key }
  }

  $notListed = @($added | Where-Object { $Config.Repos -notcontains $_ })
  if ($notListed.Count -and (Read-Host "Add $($notListed.Count) runner(s) to your list so 'Fresh start' includes them? (y/n)") -eq "y") {
    $Config.Repos = @($Config.Repos) + $notListed
    Save-Config
  }
}

function Move-Runner {
  $key = Select-Runner "Which runner do you want to move?"
  if (-not $key) { return }

  $oldDir = Get-RunnerDir $key
  Info "Current folder: $oldDir"
  $newDir = Read-Folder "New folder for the $(Get-DisplayName $key) runner" (Get-DefaultDir $key)
  if (-not $newDir) { return }
  if ($newDir -eq $oldDir) { Warn "That's the same folder."; return }
  if (-not (Test-FolderEmpty $newDir)) { Warn "$newDir is not empty. Choose an empty or new folder."; return }
  if (-not (Test-Access $key)) { return }
  if ($Config.ServiceAccount -and -not (Get-ServicePassword)) { return }

  Info "Moving = removing the runner and setting it up again in the new folder."
  Remove-Runner $key
  Install-Runner $key $newDir | Out-Null
}

# =====================================================================
#  Start / stop
# =====================================================================
function Start-Runner($key) {
  $svc = Get-RunnerService $key
  if (-not $svc) { Warn "$(Get-DisplayName $key) isn't installed on this machine."; return }
  try {
    Start-Service -Name $svc.Name -ErrorAction Stop
    Ok "Started: $(Get-DisplayName $key)"
  } catch {
    Fail "Could not start $(Get-DisplayName $key). Use 'View a runner's log' to see why."
  }
}

function Stop-Runner($key) {
  $svc = Get-RunnerService $key
  if (-not $svc) { Warn "$(Get-DisplayName $key) isn't installed on this machine."; return }
  Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
  Ok "Stopped: $(Get-DisplayName $key)"
}

function Restart-OneRunner($key) {
  $svc = Get-RunnerService $key
  if (-not $svc) { Warn "$(Get-DisplayName $key) isn't installed on this machine."; return }
  Restart-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
  Ok "Restarted: $(Get-DisplayName $key)"
}

function Restart-AllRunners {
  $keys = Get-InstalledRunners
  if ($keys.Count -eq 0) { Warn "No runners are installed."; return }
  foreach ($k in $keys) { Restart-OneRunner $k }
}

# =====================================================================
#  Labels
# =====================================================================
function Set-RunnerLabels($key) {
  $label = Get-DisplayName $key
  $gr = Get-GitHubRunner $key
  $current = if ($gr) { @($gr.labels | Where-Object { $_.type -eq "custom" } | ForEach-Object { $_.name }) }
             else     { @(Get-SavedLabels $key) }

  Write-Host ""
  Info "Built-in labels (always there): self-hosted, Windows, X64"
  Info "Your labels on ${label}: $(if ($current.Count) { $current -join ', ' } else { '(none)' })"
  $answer = Read-Host "New labels, comma-separated, e.g. php8,node20 (Enter = keep, - = remove all)"
  if ([string]::IsNullOrWhiteSpace($answer)) { return }

  $labels = @()
  if ($answer.Trim() -ne "-") {
    $labels = @($answer -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $bad = @($labels | Where-Object { $_ -match '\s' })
    if ($bad.Count) { Fail "Labels can't contain spaces: $($bad -join ', ')"; return }
  }

  if ($labels.Count) { $Config.Labels[$key] = ($labels -join ",") } else { $Config.Labels.Remove($key) }
  Save-Config

  if ($gr) {
    Use-KeyAccount $key
    if ($labels.Count) {
      $ghArgs = @("api", "-X", "PUT", "$(Get-ApiBase $key)/actions/runners/$($gr.id)/labels")
      foreach ($l in $labels) { $ghArgs += @("-f", "labels[]=$l") }
      & gh @ghArgs *> $null
    } else {
      gh api -X DELETE "$(Get-ApiBase $key)/actions/runners/$($gr.id)/labels" *> $null
    }
    if ($LASTEXITCODE -eq 0) { Ok "Labels updated on GitHub." } else { Fail "GitHub didn't accept the labels." }
  } else {
    Info "Saved. They'll be applied when this runner is set up."
  }
  if ($labels.Count) { Info "Use them in a workflow:  runs-on: [self-hosted, $($labels -join ', ')]" }
}

# =====================================================================
#  Logs
# =====================================================================
function Show-RunnerLog($key) {
  $diag = Join-Path (Get-RunnerDir $key) "_diag"
  $file = Get-ChildItem $diag -Filter "Runner_*.log" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $file) { Warn "No logs found in $diag. The runner may never have started."; return }

  Write-Host ""
  Info "Last 40 lines of $($file.FullName)  (written $($file.LastWriteTime))"
  foreach ($line in Get-Content $file.FullName -Tail 40) {
    if ($line -match '\bERR\b|Exception|error') { Write-Host $line -ForegroundColor Red }
    elseif ($line -match '\bWARN\b')           { Write-Host $line -ForegroundColor Yellow }
    else                                       { Write-Host $line }
  }
  Info "Tip: logs for individual jobs are on GitHub, in the repo's Actions tab."
  if (Confirm-Fix "Open the full log in Notepad?") { Start-Process notepad.exe $file.FullName }
}

# =====================================================================
#  Cleanup
# =====================================================================
function Clear-RunnerWork($key, $includeTools) {
  $label = Get-DisplayName $key
  $work  = Join-Path (Get-RunnerDir $key) "_work"
  if (-not (Test-Path $work)) { Info "${label}: nothing to clean."; return }

  $gr = Get-GitHubRunner $key
  if ($gr -and $gr.busy) { Warn "$label is running a job right now. Skipped."; return }

  $items = @(Get-ChildItem $work -Force | Where-Object { $includeTools -or $_.Name -ne "_tool" })
  if ($items.Count -eq 0) { Info "${label}: nothing to clean."; return }

  $before = Get-FolderSizeMB $work
  $svc = Get-RunnerService $key
  $wasRunning = $svc -and $svc.Status -eq "Running"
  if ($wasRunning) { Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue }

  foreach ($i in $items) { Remove-FolderFully $i.FullName | Out-Null }

  if ($wasRunning) { Start-Service -Name $svc.Name -ErrorAction SilentlyContinue }
  $after = Get-FolderSizeMB $work
  Ok "${label}: freed $([math]::Round($before - $after, 1)) MB"
}

function Invoke-CleanWorkMenu {
  $keys = @(Select-Runner "Clean work folders for which runner?" -AllowAll)
  if ($keys.Count -eq 0) { return }
  Info "Work folders hold checked-out code and build files. They're recreated on the next job."
  $tools = (Read-Host "Also delete the tool cache (Node/PHP versions downloaded by setup actions)? (y/n)") -eq "y"
  foreach ($k in $keys) { Clear-RunnerWork $k $tools }
}

function Clear-OldLogs($days) {
  $cutoff = (Get-Date).AddDays(-$days)
  $count = 0; $bytes = 0
  foreach ($key in Get-AllRunnerNames) {
    $diag = Join-Path (Get-RunnerDir $key) "_diag"
    foreach ($f in Get-ChildItem $diag -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cutoff }) {
      $bytes += $f.Length
      Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
      $count++
    }
  }
  Ok "Deleted $count old log file(s), freed $([math]::Round($bytes / 1MB, 1)) MB."
}

# Offline runners on GitHub with this machine's name prefix that no longer exist here
function Clear-StaleGitHubRunners {
  $localNames = @((Get-MachineRunners).Values | ForEach-Object { $_.Name })
  $seen = @{}
  $found = 0
  foreach ($key in Get-AllRunnerNames) {
    $base = Get-ApiBase $key
    if ($seen.ContainsKey($base)) { continue }
    $seen[$base] = $true

    Use-KeyAccount $key
    $json = (gh api "$base/actions/runners?per_page=100" 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0 -or -not $json) { continue }
    foreach ($r in ($json | ConvertFrom-Json).runners) {
      if (-not $r.name.StartsWith($Config.RunnerPrefix)) { continue }
      if ($r.status -eq "online" -or $localNames -contains $r.name) { continue }
      $found++
      Warn "Stale on GitHub: $($r.name) in $base (offline, not on this machine)"
      if ($script:Quiet -or (Read-Host "  Delete it from GitHub? (y/n)") -eq "y") {
        gh api -X DELETE "$base/actions/runners/$($r.id)" *> $null
        if ($LASTEXITCODE -eq 0) { Ok "  Deleted." } else { Fail "  Could not delete it." }
      }
    }
  }
  if ($found -eq 0) { Ok "No stale runners on GitHub." }
}

# Half-finished runner folders, and services whose runner folder is gone or broken
function Clear-Leftovers {
  $found = 0
  foreach ($f in Get-FolderRunners) {
    if ((Test-Path (Join-Path $f.Folder ".runner")) -or (Get-RunnerService $f.Key)) { continue }
    $found++
    Warn "Leftover folder: $($f.Folder) (never finished setting up)"
    if ($script:Quiet -or (Read-Host "  Delete it? (y/n)") -eq "y") {
      if (Remove-FolderFully $f.Folder) { Ok "  Deleted." } else { Fail "  Could not delete it." }
      if ($Config.Runners.ContainsKey($f.Key) -and $Config.Runners[$f.Key] -eq $f.Folder) { $Config.Runners.Remove($f.Key); Save-Config }
    }
  }

  foreach ($cim in Get-RunnerServicesCim) {
    $dir = Get-ServiceFolderFromCim $cim
    if ($dir -and (Test-Path (Join-Path $dir ".runner"))) { continue }
    $found++
    Warn "Broken service: $($cim.Name) (its runner folder is missing or not set up: $dir)"
    if ($script:Quiet -or (Read-Host "  Delete this service? (y/n)") -eq "y") {
      Stop-Service -Name $cim.Name -Force -ErrorAction SilentlyContinue
      sc.exe delete $cim.Name | Out-Null
      Ok "  Deleted."
    }
  }
  Reset-MachineCache
  if ($found -eq 0) { Ok "No leftovers found." }
}

function Clear-RunnerZip {
  if (-not (Test-Path $Config.ZipPath)) { Ok "No runner download to delete."; return }
  $mb = [math]::Round((Get-Item $Config.ZipPath).Length / 1MB, 1)
  Remove-Item $Config.ZipPath -Force
  Ok "Deleted the runner download ($mb MB). The latest version is downloaded next time you add a runner."
}

function Invoke-FullCleanup {
  foreach ($k in Get-InstalledRunners) { Clear-RunnerWork $k $false }
  Clear-OldLogs 7
  Clear-StaleGitHubRunners
  Clear-Leftovers
}

function Invoke-CleanupMenu {
  while ($true) {
    Write-Host ""
    Write-Host "----- Cleanup -----" -ForegroundColor Cyan
    Write-Host "  1) Work folders (checked-out code and build files)"
    Write-Host "  2) Old log files (older than 7 days)"
    Write-Host "  3) Stale runners on GitHub (offline, no longer on this machine)"
    Write-Host "  4) Leftovers from failed setups (folders and broken services)"
    Write-Host "  5) Runner download zip (forces the latest version next time)"
    Write-Host "  6) All of the above (asks before each delete)"
    Write-Host "  0) Back"

    switch (Read-Host "Choose an option") {
      "1" { Invoke-CleanWorkMenu }
      "2" { Clear-OldLogs 7 }
      "3" { Clear-StaleGitHubRunners }
      "4" { Clear-Leftovers }
      "5" { Clear-RunnerZip }
      "6" { Invoke-FullCleanup; Clear-RunnerZip }
      "0" { return }
      default { Warn "Invalid option." }
    }
  }
}

# =====================================================================
#  Health check
# =====================================================================
function Find-InPath($tool, $pathString) {
  foreach ($p in ($pathString -split ';')) {
    if (-not $p) { continue }
    try {
      $p = [Environment]::ExpandEnvironmentVariables($p)
      foreach ($ext in ".exe", ".cmd", ".bat") {
        $f = [IO.Path]::Combine($p, "$tool$ext")
        if (Test-Path $f) { return $f }
      }
    } catch { }
  }
  return $null
}

function Invoke-HealthCheck {
  Write-Host ""
  Write-Host "===== Health check =====" -ForegroundColor Cyan

  # Accounts
  Write-Host ""
  Write-Host "GitHub accounts:"
  foreach ($a in Get-GhAccounts) {
    if (Get-AccountToken $a) { Ok "  $a  signed in" } else { Warn "  $a  sign-in problem (sign in again from Accounts)" }
  }

  # Runners
  Show-Status

  # Disk space
  Write-Host ""
  Write-Host "Disk space:"
  $drives = @($Config.RunnersRoot.Substring(0, 2))
  foreach ($key in Get-AllRunnerNames) { $drives += (Get-RunnerDir $key).Substring(0, 2) }
  foreach ($d in ($drives | Sort-Object -Unique)) {
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$d'" -ErrorAction SilentlyContinue
    if (-not $disk) { continue }
    $free = [math]::Round($disk.FreeSpace / 1GB, 1)
    if ($free -lt 10) { Warn "  $d  $free GB free  (low - use Cleanup)" }
    else              { Ok   "  $d  $free GB free" }
  }

  # Tools, as the runner service sees them
  Write-Host ""
  Write-Host "Tools (as the runners see them, running as $(Get-AccountLabel)):"
  $runnerPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
  if ($Config.ServiceAccount) { $runnerPath += ";" + [Environment]::GetEnvironmentVariable("Path", "User") }
  foreach ($tool in "git", "node", "npm", "php", "composer", "docker") {
    $forRunner = Find-InPath $tool $runnerPath
    $anywhere  = Get-Command $tool -ErrorAction SilentlyContinue
    if ($forRunner)    { Ok   ("  {0,-9} OK  {1}" -f $tool, $forRunner) }
    elseif ($anywhere) { Warn ("  {0,-9} Installed, but runners can't see it (only on your user PATH): {1}" -f $tool, $anywhere.Source) }
    else               { Write-Host ("  {0,-9} Not installed" -f $tool) -ForegroundColor DarkGray }
  }
  Write-Host "  Fix 'runners can't see it': add the tool's folder to the SYSTEM Path, or run runners as your account (Settings)." -ForegroundColor DarkGray

  # bash: needed for workflow steps with 'shell: bash'. Must be Git Bash, not WSL's bash.
  $needRestart = $false
  $bash = Find-InPath "bash" $runnerPath
  if ($bash -and $bash -match '\\Git\\') { Ok ("  {0,-9} OK  {1}" -f "bash", $bash) }
  else {
    if ($bash) { Warn "  bash      Found $bash (WSL's bash, not Git Bash). 'shell: bash' steps may fail." }
    else       { Warn "  bash      Not found. Workflow steps with 'shell: bash' will fail." }
    $gitBash = @("$env:ProgramFiles\Git\bin", "${env:ProgramFiles(x86)}\Git\bin") |
      Where-Object { Test-Path (Join-Path $_ "bash.exe") } | Select-Object -First 1
    if ($gitBash) {
      if (Confirm-Fix "Add Git Bash ($gitBash) to the start of the SYSTEM Path?") {
        $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
        [Environment]::SetEnvironmentVariable("Path", "$gitBash;$machinePath", "Machine")
        Ok "  Added."
        $needRestart = $true
      }
    } else {
      Warn "  Install Git for Windows first: https://git-scm.com/download/win"
    }
  }

  # Windows settings
  Write-Host ""
  Write-Host "Windows settings:"

  $gpPolicy = Get-ExecutionPolicy -Scope MachinePolicy
  $ep = Get-ExecutionPolicy -Scope LocalMachine
  if ($gpPolicy -ne "Undefined") {
    Warn "  PowerShell scripts: set by Group Policy to '$gpPolicy'. Can't change it from here."
  } elseif ($ep -in "RemoteSigned", "Unrestricted", "Bypass") {
    Ok "  PowerShell scripts: allowed ($ep)"
  } else {
    Warn "  PowerShell scripts: blocked (policy: $ep). Workflow steps that use PowerShell will fail."
    if (Confirm-Fix "Allow local scripts (set policy to RemoteSigned for this machine)?") {
      Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
      Ok "  Done."
    }
  }

  Repair-FolderPermissions

  $fsKey = "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"
  $lp = (Get-ItemProperty $fsKey -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled
  if ($lp -eq 1) { Ok "  Long paths: enabled" }
  else {
    Warn "  Long paths: disabled (deep node_modules folders can fail)"
    if (Confirm-Fix "Enable long paths now?") {
      New-ItemProperty $fsKey -Name LongPathsEnabled -Value 1 -PropertyType DWord -Force | Out-Null
      Ok "  Enabled."
    }
  }

  if (Get-Command git -ErrorAction SilentlyContinue) {
    $gl = git config --system --get core.longpaths 2>$null
    if ("$gl" -eq "true") { Ok "  Git long paths: enabled" }
    else {
      Warn "  Git long paths: disabled"
      if (Confirm-Fix "Enable Git long paths now?") { git config --system core.longpaths true; Ok "  Enabled." }
    }
  }

  $pc  = (powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE) -join "`n"
  $hex = [regex]::Matches($pc, '0x([0-9a-fA-F]{8})')
  if ($hex.Count -ge 2) {
    $ac = [Convert]::ToInt64($hex[$hex.Count - 2].Groups[1].Value, 16)
    if ($ac -eq 0) { Ok "  Sleep when plugged in: never" }
    else {
      Warn "  Sleep when plugged in: after $([math]::Round($ac / 60)) min (runners stop working while asleep)"
      if (Confirm-Fix "Turn off sleep when plugged in?") { powercfg /change standby-timeout-ac 0; Ok "  Done." }
    }
  }

  if ($needRestart) {
    if (Confirm-Fix "Restart all runners now so they pick up the new PATH?") { Restart-AllRunners }
    else { Warn "  Remember to restart the runners (option 6) so they see the change." }
  } else {
    Write-Host "  After installing tools or changing PATH, use 'Restart all runners'." -ForegroundColor DarkGray
  }
  Write-Host ""
}

# =====================================================================
#  Fresh start & your list
# =====================================================================
function Invoke-FreshStart {
  $list = @($Config.Repos)
  if ($list.Count -eq 0) { Warn "Your list is empty. Add repos with 'Manage your list' first."; return }

  Warn "This removes and sets up again every runner in your list:"
  foreach ($k in $list) { Write-Host "  - $(Get-DisplayName $k)  (account: $(Get-KeyAccount $k))" }

  $others = @(Get-InstalledRunners | Where-Object { $list -notcontains $_ })
  $removeOthers = $false
  if ($others.Count) {
    Write-Host ""
    Write-Host "These runners on this machine are NOT in your list:"
    foreach ($k in $others) { Write-Host "  - $(Get-DisplayName $k)" }
    $removeOthers = (Read-Host "Remove them too? (y/n)") -eq "y"
  }
  if ((Read-Host "Type YES to continue") -ne "YES") { Info "Cancelled."; return }

  # Decide all folders first, so nothing is removed if you cancel halfway
  $plan = Get-FolderPlan $list
  if (-not $plan) { return }
  if ($Config.ServiceAccount -and -not (Get-ServicePassword)) { return }

  foreach ($key in $list) {
    if ((Get-RunnerService $key) -or (Test-Path (Get-RunnerDir $key))) { Remove-Runner $key }
  }
  if ($removeOthers) { foreach ($key in $others) { Remove-Runner $key -Forget } }
  foreach ($key in @($plan.Keys)) { Install-Runner $key $plan[$key] | Out-Null }
  Show-Status
}

function Add-ToList($key) {
  if (-not $key) { return }
  if ($Config.Repos -contains $key) { Warn "$(Get-DisplayName $key) is already in the list."; return }
  if (-not $Config.RunnerAccounts.ContainsKey($key)) { $Config.RunnerAccounts[$key] = $Config.ActiveAccount }
  if (-not (Test-Access $key)) { $Config.RunnerAccounts.Remove($key); return }
  $Config.Repos = @($Config.Repos) + $key
  Save-Config
  Ok "Added $(Get-DisplayName $key)."
}

function Edit-RepoList {
  while ($true) {
    Write-Host ""
    Write-Host "----- Your list (used by 'Fresh start') -----" -ForegroundColor Cyan
    if ($Config.Repos.Count -eq 0) { Write-Host "  (empty)" }
    for ($i = 0; $i -lt $Config.Repos.Count; $i++) {
      $k = $Config.Repos[$i]
      Write-Host ("  {0}) {1}   (account: {2})" -f ($i + 1), (Get-DisplayName $k), (Get-KeyAccount $k))
    }
    Write-Host ""
    Write-Host "  p) Pick repos from a list"
    Write-Host "  a) Type a repo"
    Write-Host "  o) Add an organization"
    Write-Host "  r) Remove from the list"
    Write-Host "  0) Back"

    switch (Read-Host "Choose") {
      "p" { foreach ($k in @(Select-Repos)) { Add-ToList $k } }
      "a" {
        $typed = Read-Host "Repo (name, owner/name or GitHub URL)"
        if ($typed) { Add-ToList (ConvertTo-FullKey $typed) }
      }
      "o" {
        $typed = Read-Host "Organization name"
        if ($typed) { Add-ToList ("org:" + $typed.Trim()) }
      }
      "r" {
        $pick = Read-Host "Number(s) to remove (e.g. 2 or 1,3)"
        $nums = @(Read-NumberList $pick $Config.Repos.Count)
        if ($nums.Count -eq 0) { Warn "Invalid number."; continue }
        $toRemove = @($nums | ForEach-Object { $Config.Repos[$_ - 1] })
        $Config.Repos = @($Config.Repos | Where-Object { $toRemove -notcontains $_ })
        Save-Config
        foreach ($key in $toRemove) {
          Ok "Removed $(Get-DisplayName $key) from the list."
          if ((Get-RunnerService $key) -and (Read-Host "  Also remove its runner from this machine? (y/n)") -eq "y") { Remove-Runner $key -Forget }
        }
      }
      "0" { return }
      default { Warn "Invalid option." }
    }
  }
}

# =====================================================================
#  Settings
# =====================================================================
function Set-ServiceAccount {
  Write-Host ""
  Info "Runners currently run as: $(Get-AccountLabel)"
  Write-Host "  1) NETWORK SERVICE (default; limited account, only sees the SYSTEM Path)"
  Write-Host "  2) My Windows account ($env:USERDOMAIN\$env:USERNAME; sees the same tools you do)"
  Write-Host "  3) Another Windows account"
  $c = Read-Host "Choose (or Enter to cancel)"
  if ($c -eq "1")     { $newAcct = "" }
  elseif ($c -eq "2") { $newAcct = "$env:USERDOMAIN\$env:USERNAME" }
  elseif ($c -eq "3") {
    $newAcct = (Read-Host "Account, e.g. .\builduser or DOMAIN\user").Trim()
    if (-not $newAcct) { return }
  } else { return }

  if ($newAcct -eq "$($Config.ServiceAccount)") { Info "No change."; return }
  $Config.ServiceAccount = $newAcct
  $script:ServicePassword = $null
  Save-Config
  Ok "Saved. New runners will run as: $(Get-AccountLabel)"

  $installed = Get-InstalledRunners
  if ($installed.Count -eq 0) { return }
  if ((Read-Host "Re-install the $($installed.Count) existing runner(s) now so they use it too? (y/n)") -ne "y") {
    Info "Existing runners keep their current account until they're re-installed or moved."
    return
  }
  if ($Config.ServiceAccount -and -not (Get-ServicePassword)) { return }
  foreach ($key in $installed) {
    $dir = Get-RunnerDir $key
    Remove-Runner $key
    if (-not (Install-Runner $key $dir)) {
      Fail "Stopped. Fix the problem above, then add $(Get-DisplayName $key) again (folder: $dir)."
      return
    }
  }
}

function Show-Settings {
  while ($true) {
    Write-Host ""
    Write-Host "----- Settings -----" -ForegroundColor Cyan
    Write-Host "  1) Default folder for new runners : $($Config.RunnersRoot)"
    Write-Host "  2) Runner download (zip) location : $($Config.ZipPath)"
    Write-Host "  3) Runners run as                 : $(Get-AccountLabel)"
    Write-Host "  4) Runner name prefix             : $($Config.RunnerPrefix)   (e.g. $($Config.RunnerPrefix)myrepo)"
    Write-Host "  0) Back"

    switch (Read-Host "Choose an option") {
      "1" {
        $new = Read-Folder "New default folder for runners" $Config.RunnersRoot
        if ($new) {
          New-Item -ItemType Directory -Force -Path $new | Out-Null
          $Config.RunnersRoot = $new
          Save-Config
          Reset-MachineCache
          Ok "Saved. New runners will go in $new"
          Info "Existing runners stay where they are. Use 'Move a runner' to move one."
        }
      }
      "2" {
        $zipFolder = Read-Folder "Folder to keep the runner download in" (Split-Path $Config.ZipPath -Parent)
        if ($zipFolder) {
          $newZip = Join-Path $zipFolder "runner.zip"
          # The old download isn't carried over: the next one is downloaded fresh and verified
          if ((Test-Path $Config.ZipPath) -and $newZip -ne $Config.ZipPath) { Remove-Item -LiteralPath $Config.ZipPath -Force -ErrorAction SilentlyContinue }
          $Config.ZipPath = $newZip
          Save-Config
          Initialize-ZipFolder
          Ok "Saved. Runner download location: $newZip"
        }
      }
      "3" { Set-ServiceAccount }
      "4" {
        $p = Read-Host "New prefix (letters, numbers, - or _) [Enter = $($Config.RunnerPrefix)]"
        if ($p) {
          if ($p -notmatch '^[A-Za-z0-9_-]+$') { Fail "Use only letters, numbers, - or _." }
          else {
            $Config.RunnerPrefix = $p
            Save-Config
            Ok "Saved. New runners will be named like $($p)myrepo. Existing runners keep their names."
          }
        }
      }
      "0" { return }
      default { Warn "Invalid option." }
    }
  }
}

# =====================================================================
#  Command-line mode
# =====================================================================
function Show-Usage {
  Write-Host @"
Usage (run as Administrator):
  .\runner-manager.ps1                          Open the menu
  .\runner-manager.ps1 -Status                  Show all runners
  .\runner-manager.ps1 -Start <name|all>        Start runner(s)
  .\runner-manager.ps1 -Stop <name|all>         Stop runner(s)
  .\runner-manager.ps1 -Restart <name|all>      Restart runner(s)
  .\runner-manager.ps1 -Add <name> [-Folder D:\path]
  .\runner-manager.ps1 -Remove <name> [-Yes]
  .\runner-manager.ps1 -Log <name>              Show the latest log
  .\runner-manager.ps1 -Clean <name|all>        Clean work folders
  .\runner-manager.ps1 -Cleanup                 Full cleanup (work folders, old logs, stale runners, leftovers)
  .\runner-manager.ps1 -Health                  Run the health check
  Add -Account <login> to any of these to use a different signed-in GitHub account.

  <name> is a repo name (owned by the active account), owner/repo, or org:<name>.
"@
}

# =====================================================================
#  Start
# =====================================================================
$cli = $PSBoundParameters.Count -gt 0
if ($cli) { $script:Quiet = $true }

if ($Help) { Show-Usage; exit 0 }
if (-not (Test-Prerequisites)) { if (-not $cli) { Read-Host "Press Enter to exit" }; exit 1 }
# This script runs as Administrator, so other users must not be able to change it or its settings
if (Test-WritableByOthers $ScriptDir) {
  Repair-OneFolder @{ Path = $ScriptDir; Writers = @(); Names = $script:ScriptFolderFiles; What = "this script and its settings" }
}
if (-not (Initialize-Account)) { if (-not $cli) { Read-Host "Press Enter to exit" }; exit 1 }
Update-OldKeys

if ($cli) {
  $did = $false
  if ($Status)  { Show-Status; $did = $true }
  if ($Start)   { foreach ($k in Resolve-Targets $Start)   { Start-Runner $k };      $did = $true }
  if ($Stop)    { foreach ($k in Resolve-Targets $Stop)    { Stop-Runner $k };       $did = $true }
  if ($Restart) { foreach ($k in Resolve-Targets $Restart) { Restart-OneRunner $k }; $did = $true }
  if ($Add) {
    $k = ConvertTo-FullKey $Add
    $target = if ($Folder) { $Folder.Trim().Trim('"').TrimEnd('\') } else { Get-DefaultDir $k }
    if (-not (Get-RunnerService $k)) { $Config.RunnerAccounts[$k] = $Config.ActiveAccount }
    if (Test-FolderChoice $target) { Install-Runner $k $target | Out-Null }
    $did = $true
  }
  if ($Remove) {
    $k = ConvertTo-FullKey $Remove
    if ($Yes) { Remove-Runner $k -Forget } else { Fail "Add -Yes to confirm removing $(Get-DisplayName $k)." }
    $did = $true
  }
  if ($Log)     { Show-RunnerLog (ConvertTo-FullKey $Log); $did = $true }
  if ($Clean)   { foreach ($k in Resolve-Targets $Clean) { Clear-RunnerWork $k $false }; $did = $true }
  if ($Cleanup) { Invoke-FullCleanup; $did = $true }
  if ($Health)  { Invoke-HealthCheck; $did = $true }
  if (-not $did) { Show-Usage }
  exit 0
}

# =====================================================================
#  Menu
# =====================================================================
while ($true) {
  if (-not $Config.ActiveAccount -or -not (Get-AccountToken $Config.ActiveAccount)) {
    $Config.ActiveAccount = ""
    if (-not (Initialize-Account)) { Read-Host "Press Enter to exit"; exit 1 }
  }

  Write-Host ""
  Write-Host "===== GitHub Runner Manager =====" -ForegroundColor Cyan
  Write-Host " Account: $($Config.ActiveAccount)" -ForegroundColor Green
  Write-Host " Runners"
  Write-Host "   1) Show status"
  Write-Host "   2) Add runner(s) (pick repos, type a repo, or an organization)"
  Write-Host "   3) Remove a runner"
  Write-Host "   4) Start a runner"
  Write-Host "   5) Stop a runner"
  Write-Host "   6) Restart all runners"
  Write-Host "   7) Move a runner to another folder"
  Write-Host "   8) Change a runner's labels"
  Write-Host " Maintenance"
  Write-Host "   9) View a runner's log"
  Write-Host "  10) Cleanup (work folders, old logs, stale runners, leftovers)"
  Write-Host "  11) Health check"
  Write-Host " Setup"
  Write-Host "  12) Fresh start (remove and set up again everything in your list)"
  Write-Host "  13) Manage your list"
  Write-Host "  14) Settings (folders, service account, runner names)"
  Write-Host "   A) Accounts (switch, sign in, sign out)"
  Write-Host "   0) Exit"
  $choice = Read-Host "Choose an option"

  switch ($choice) {
    "1"  { Show-Status }
    "2"  { Add-Runners }
    "3"  {
      $r = Select-Runner "Which runner do you want to REMOVE?"
      if ($r -and (Read-Host "Remove $(Get-DisplayName $r)? (y/n)") -eq "y") { Remove-Runner $r -Forget }
    }
    "4"  { foreach ($r in @(Select-Runner "Which runner do you want to start?" -AllowAll)) { Start-Runner $r } }
    "5"  { foreach ($r in @(Select-Runner "Which runner do you want to stop?"  -AllowAll)) { Stop-Runner $r } }
    "6"  { Restart-AllRunners }
    "7"  { Move-Runner }
    "8"  { $r = Select-Runner "Change labels for which runner?"; if ($r) { Set-RunnerLabels $r } }
    "9"  { $r = Select-Runner "View the log for which runner?";  if ($r) { Show-RunnerLog $r } }
    "10" { Invoke-CleanupMenu }
    "11" { Invoke-HealthCheck }
    "12" { Invoke-FreshStart }
    "13" { Edit-RepoList }
    "14" { Show-Settings }
    "a"  { Show-Accounts }
    "0"  { exit 0 }
    default { Warn "Invalid option." }
  }
}
