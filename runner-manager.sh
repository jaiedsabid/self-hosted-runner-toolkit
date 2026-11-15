#!/usr/bin/env bash
# runner-manager.sh
# GitHub Runner Manager for macOS and Linux
# Sets up and manages GitHub Actions self-hosted runners on this machine,
# for any GitHub account, repo or organization.
#
# First run:
#   chmod +x runner-manager.sh
#   ./runner-manager.sh
# Don't use sudo. The script asks for your password only when it needs it
# (Linux background services, installing packages).
#
# It installs GitHub CLI if needed, signs you in through the browser, and walks
# you through adding runners. Several GitHub accounts can be signed in at once.
# Settings are saved in runner-manager.conf next to this script.
#
# Command-line mode (no menu), examples:
#   ./runner-manager.sh --status
#   ./runner-manager.sh --start all
#   ./runner-manager.sh --add my-repo --folder ~/actions-runners/my-repo
#   ./runner-manager.sh --remove my-repo --yes
#   ./runner-manager.sh --log my-repo
#   ./runner-manager.sh --cleanup
#   ./runner-manager.sh --status --account otheruser
# A plain repo name means a repo owned by the active account. Use owner/repo for
# other owners, and org:<name> for an organization runner.
#
# Works with the bash that ships with macOS (3.2) and any newer bash.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CONFIG="$SCRIPT_DIR/runner-manager.conf"
OS_NAME=$(uname -s)

QUIET=0
ACCOUNT_OVERRIDE=""
MACHINE_CACHE=""
FOLDER_CACHE=""
MACHINE_VALID=0
WARNED_ACCOUNTS=" "
PLAN_KEYS=()
PLAN_DIRS=()

# =====================================================================
#  Basics
# =====================================================================
is_mac()   { [ "$OS_NAME" = "Darwin" ]; }
is_linux() { [ "$OS_NAME" = "Linux" ]; }
has_systemd() { command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; }

detect_platform() {
  local os arch m
  case "$OS_NAME" in Darwin) os=osx ;; Linux) os=linux ;; *) echo "unsupported"; return ;; esac
  m=$(uname -m)
  if is_mac && [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ]; then m=arm64; fi   # also under Rosetta
  case "$m" in
    arm64|aarch64)       arch=arm64 ;;
    x86_64|amd64)        arch=x64 ;;
    armv7l|armv6l|armhf) arch=arm ;;
    *)                   arch="$m" ;;
  esac
  echo "$os-$arch"
}
PLATFORM=$(detect_platform)

# Messages go to stderr so they never mix with values returned by functions
info() { printf '\033[36m%s\033[0m\n' "$*" >&2; }
ok()   { printf '\033[32m%s\033[0m\n' "$*" >&2; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
fail() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
dim()  { printf '\033[90m%s\033[0m\n' "$*" >&2; }
say()  { printf '%s\n' "$*" >&2; }

ask() { local reply; read -r -p "$1" reply </dev/tty; printf '%s' "$reply"; }

confirm_fix() {
  [ "$QUIET" = "1" ] && return 1
  [ "$(ask "  $1 (y/n) ")" = "y" ]
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
trim()  { printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

# Parses "1,3,5", "2-4" or "all" into numbers between 1 and max
parse_numbers() {
  local answer max part a b n
  answer=$(lower "$1" | tr -d ' '); max=$2
  if [ "$answer" = "all" ]; then
    n=1; while [ "$n" -le "$max" ]; do echo "$n"; n=$((n + 1)); done
    return
  fi
  local IFS=,
  for part in $answer; do
    case "$part" in
      *-*) a=${part%-*}; b=${part#*-} ;;
      *)   a=$part; b=$part ;;
    esac
    case "$a$b" in ""|*[!0-9]*) continue ;; esac
    n=$a
    while [ "$n" -le "$b" ]; do
      if [ "$n" -ge 1 ] && [ "$n" -le "$max" ]; then echo "$n"; fi
      n=$((n + 1))
    done
  done | sort -n -u
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}

# =====================================================================
#  Saved settings (runner-manager.conf)
#  One record per line: TYPE|key|value
#    SET|ACTIVE|login   SET|ROOT|path   SET|ARCHIVE|path   SET|PREFIX|text
#    LIST|owner/repo|   RUNNER|key|folder   LABELS|key|a,b   ACCOUNT|key|login
# =====================================================================
cfg_init() { [ -f "$CONFIG" ] || : > "$CONFIG"; }

cfg_get() {
  awk -F'|' -v t="$1" -v k="$2" '
    BEGIN { k = tolower(k) }
    $1 == t && tolower($2) == k { print substr($0, length($1) + length($2) + 3); exit }' "$CONFIG"
}

cfg_del() {
  local tmp; tmp=$(mktemp)
  awk -F'|' -v t="$1" -v k="$2" 'BEGIN { k = tolower(k) } !($1 == t && tolower($2) == k)' "$CONFIG" > "$tmp" && cat "$tmp" > "$CONFIG"
  rm -f "$tmp"
}

cfg_put()  { cfg_del "$1" "$2"; printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$CONFIG"; }
cfg_keys() { awk -F'|' -v t="$1" '$1 == t { print $2 }' "$CONFIG"; }
cfg_has()  { [ -n "$(awk -F'|' -v t="$1" -v k="$2" 'BEGIN { k = tolower(k) } $1 == t && tolower($2) == k { print "y"; exit }' "$CONFIG")" ]; }

setting() { local v; v=$(cfg_get SET "$1"); if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$2"; fi; }
set_setting() { cfg_put SET "$1" "$2"; }

active_account() { if [ -n "$ACCOUNT_OVERRIDE" ]; then printf '%s' "$ACCOUNT_OVERRIDE"; else setting ACTIVE ""; fi; }
runners_root()   { setting ROOT "$HOME/actions-runners"; }
archive_path()   { setting ARCHIVE "$HOME/actions-runners/_downloads/actions-runner-$PLATFORM.tar.gz"; }
runner_prefix()  { setting PREFIX "$(lower "$(hostname -s 2>/dev/null || hostname)")-"; }

# =====================================================================
#  Runner keys: "owner/repo", or "org:<name>" for an organization
# =====================================================================
is_org()       { case "$1" in org:*) return 0 ;; esac; return 1; }
org_name()     { printf '%s' "${1#org:}"; }
api_base()     { if is_org "$1"; then printf 'orgs/%s' "$(org_name "$1")"; else printf 'repos/%s' "$1"; fi; }
target_url()   { if is_org "$1"; then printf 'https://github.com/%s' "$(org_name "$1")"; else printf 'https://github.com/%s' "$1"; fi; }
display_name() { if is_org "$1"; then printf '%s (org)' "$(org_name "$1")"; else printf '%s' "$1"; fi; }
folder_name()  { if is_org "$1"; then printf 'org-%s' "$(org_name "$1")"; else printf '%s' "$1"; fi; }
default_dir()  { printf '%s/%s' "$(runners_root)" "$(folder_name "$1")"; }

new_runner_name() {
  if is_org "$1"; then printf '%sorg-%s' "$(runner_prefix)" "$(org_name "$1")"
  else printf '%s%s' "$(runner_prefix)" "${1#*/}"; fi
}

# https://github.com/a/b -> a/b ;  https://github.com/org -> org:org
url_to_key() {
  local p="${1#*://}"
  p="${p#*/}"; p="${p%/}"
  [ -z "$p" ] && return
  local first="${p%%/*}"
  if [ "$p" = "$first" ]; then printf 'org:%s' "$first"
  else local rest="${p#*/}"; printf '%s/%s' "$first" "${rest%%/*}"; fi
}

# Accepts "repo", "owner/repo", "org:name" or a GitHub URL
full_key() {
  local t; t=$(trim "$1"); t="${t%/}"
  [ -z "$t" ] && return
  case "$t" in
    http://*|https://*) url_to_key "$t" ;;
    org:*|*/*)          printf '%s' "$t" ;;
    *)                  printf '%s/%s' "$(active_account)" "$t" ;;
  esac
}

# =====================================================================
#  GitHub CLI and accounts
# =====================================================================
gh_version_ok() {
  local v major minor
  v=$(gh --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
  major=${v%%.*}; minor=${v#*.}
  [ -n "$v" ] && { [ "$major" -gt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -ge 40 ]; }; }
}

install_gh() {
  if is_mac && command -v brew >/dev/null 2>&1; then
    info "Installing GitHub CLI with Homebrew..."
    brew install gh && return 0
  fi

  local arch pattern api url tmp
  case "$PLATFORM" in
    *-arm64) arch=arm64 ;;
    *-x64)   arch=amd64 ;;
    *-arm)   arch=armv6 ;;
    *)       fail "Can't install GitHub CLI automatically on $PLATFORM."; return 1 ;;
  esac
  if is_mac; then pattern="gh_[0-9.]+_macOS_${arch}\.zip"; else pattern="gh_[0-9.]+_linux_${arch}\.tar\.gz"; fi

  info "Downloading GitHub CLI..."
  api=$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest) || { fail "Couldn't reach GitHub."; return 1; }
  url=$(printf '%s' "$api" | grep -oE "https://[^\"]*/${pattern}" | head -1)
  [ -z "$url" ] && { fail "Couldn't find a GitHub CLI download for $PLATFORM."; return 1; }

  tmp=$(mktemp -d)
  if ! curl -fsSL -o "$tmp/gh-archive" "$url"; then fail "Download failed."; rm -rf "$tmp"; return 1; fi
  if is_mac; then unzip -q "$tmp/gh-archive" -d "$tmp" || { rm -rf "$tmp"; return 1; }
  else tar -xzf "$tmp/gh-archive" -C "$tmp" || { rm -rf "$tmp"; return 1; }; fi

  mkdir -p "$HOME/.local/bin"
  cp "$(find "$tmp" -type f -path '*/bin/gh' | head -1)" "$HOME/.local/bin/gh" && chmod +x "$HOME/.local/bin/gh"
  rm -rf "$tmp"
  export PATH="$HOME/.local/bin:$PATH"
  hash -r 2>/dev/null
  ok "Installed GitHub CLI to $HOME/.local/bin/gh"

  local rc
  case "${SHELL##*/}" in
    zsh)  rc="$HOME/.zshrc" ;;
    bash) if is_mac; then rc="$HOME/.bash_profile"; else rc="$HOME/.bashrc"; fi ;;
    *)    rc="$HOME/.profile" ;;
  esac
  if ! grep -q '.local/bin' "$rc" 2>/dev/null; then
    if [ "$(ask "Add $HOME/.local/bin to your PATH in $rc so 'gh' works in new terminals? (y/n) ")" = "y" ]; then
      printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
      ok "Added. New terminal windows will find gh."
    fi
  fi
  return 0
}

check_prerequisites() {
  if [ "$PLATFORM" = "unsupported" ]; then fail "This script supports macOS and Linux only."; return 1; fi
  if [ "$(id -u)" = "0" ]; then
    fail "Please don't run this with sudo or as root."
    fail "Run it as your normal user; it asks for your password only when needed."
    return 1
  fi
  local tool
  for tool in curl tar awk sed; do
    command -v "$tool" >/dev/null 2>&1 || { fail "'$tool' is required but not installed."; return 1; }
  done

  [ -d "$HOME/.local/bin" ] && case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac

  if ! command -v gh >/dev/null 2>&1; then
    warn "GitHub CLI (gh) is not installed. This script uses it to talk to GitHub."
    if [ "$QUIET" = "1" ] || [ "$(ask "Install it now? (y/n) ")" != "y" ]; then
      fail "Install GitHub CLI from https://cli.github.com, then run this script again."
      return 1
    fi
    install_gh || return 1
  fi

  if ! gh_version_ok; then
    warn "Your GitHub CLI is older than 2.40, which is needed for multiple accounts."
    if [ "$QUIET" = "0" ] && [ "$(ask "Install the latest version now? (y/n) ")" = "y" ]; then
      install_gh || return 1
    else
      fail "Update GitHub CLI (e.g. 'brew upgrade gh' or your package manager), then run again."
      return 1
    fi
  fi
  return 0
}

gh_accounts() {
  env -u GH_TOKEN gh auth status -h github.com 2>&1 |
    grep -oE ' (account|as) [A-Za-z0-9][A-Za-z0-9-]*' | awk '{ print $2 }' | sort -fu
}

_LAST_LOGIN=""
_LAST_TOKEN=""
account_token() {
  [ -z "$1" ] && return 1
  if [ "$1" = "$_LAST_LOGIN" ] && [ -n "$_LAST_TOKEN" ]; then printf '%s' "$_LAST_TOKEN"; return 0; fi
  env -u GH_TOKEN gh auth token -h github.com -u "$1" 2>/dev/null
}

# Makes the following gh calls run as $1 (without changing GitHub CLI's own active account)
use_account() {
  local login="${1:-$(active_account)}" t
  t=$(account_token "$login")
  if [ -z "$t" ] && [ "$login" != "$(active_account)" ]; then
    case "$WARNED_ACCOUNTS" in
      *" $login "*) ;;
      *) warn "Account $login isn't signed in here. Using $(active_account) instead."; WARNED_ACCOUNTS="$WARNED_ACCOUNTS$login " ;;
    esac
    login=$(active_account)
    t=$(account_token "$login")
  fi
  if [ -n "$t" ]; then
    export GH_TOKEN="$t"
    _LAST_LOGIN="$login"; _LAST_TOKEN="$t"
  fi
}

key_account()     { local a; a=$(cfg_get ACCOUNT "$1"); if [ -n "$a" ]; then printf '%s' "$a"; else active_account; fi; }
use_key_account() { use_account "$(key_account "$1")"; }

set_active() {
  ACCOUNT_OVERRIDE=""
  set_setting ACTIVE "$1"
  _LAST_LOGIN=""
  use_account "$1"
  ok "Active account: $1"
}

add_account() {
  say ""
  info "Sign in to GitHub. A browser window opens; enter the one-time code shown here."
  local scopes=()
  [ "$(ask "Will this account manage organization runners too? (y/n) ")" = "y" ] && scopes=(-s admin:org)
  if ! env -u GH_TOKEN gh auth login -h github.com -p https --web "${scopes[@]}"; then
    fail "Sign-in didn't complete."; return 1
  fi
  local login
  login=$(env -u GH_TOKEN gh api user --jq .login 2>/dev/null)
  [ -z "$login" ] && { fail "Signed in, but couldn't read the account name."; return 1; }
  set_active "$login"
}

# Prints the chosen account
select_account() {
  local accts a i=0 c
  accts=$(gh_accounts)
  [ -z "$accts" ] && { warn "No accounts are signed in."; return 1; }
  say ""; say "$1"
  for a in $accts; do
    i=$((i + 1))
    if [ "$a" = "$(active_account)" ]; then say "  $i) $a  (active)"; else say "  $i) $a"; fi
  done
  c=$(ask "Choose (or Enter to cancel): ")
  case "$c" in ""|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$accts" | sed -n "${c}p"
}

# GitHub CLI's own active account (read locally, no network needed)
gh_active_account() {
  env -u GH_TOKEN gh auth status -h github.com 2>&1 | awk '
    { for (i = 1; i < NF; i++) if ($i == "account") a = $(i + 1) }
    /Active account: true/ { print a; exit }'
}

grant_org_permission() {
  local login prev switched=0
  login=$(select_account "Give which account permission to manage organization runners?")
  [ -z "$login" ] && return
  # "gh auth refresh" only works on GitHub CLI's active account, so switch to
  # $login for the refresh and switch back afterwards
  prev=$(gh_active_account)
  if [ "$(lower "$prev")" != "$(lower "$login")" ]; then
    if ! env -u GH_TOKEN gh auth switch -h github.com -u "$login" >/dev/null 2>&1; then
      fail "Couldn't switch GitHub CLI to $login."; return
    fi
    switched=1
  fi
  info "A browser window opens to approve the extra permission (admin:org)."
  if env -u GH_TOKEN gh auth refresh -h github.com -s admin:org; then
    _LAST_LOGIN=""
    ok "$login can now manage organization runners."
  else
    fail "That didn't complete."
  fi
  if [ "$switched" = "1" ] && [ -n "$prev" ]; then
    env -u GH_TOKEN gh auth switch -h github.com -u "$prev" >/dev/null 2>&1 ||
      warn "GitHub CLI's active account is now $login (couldn't switch back to $prev)."
  fi
}

remove_account() {
  local login count k
  login=$(select_account "Sign out which account?")
  [ -z "$login" ] && return
  count=0
  for k in $(installed_keys); do [ "$(key_account "$k")" = "$login" ] && count=$((count + 1)); done
  if [ "$count" -gt 0 ]; then
    warn "$count runner(s) on this machine are managed by $login. They keep running,"
    warn "but you'll need to sign in as $login again to change or remove them."
  fi
  [ "$(ask "Sign out $login? (y/n) ")" = "y" ] || return
  if ! env -u GH_TOKEN gh auth logout -h github.com -u "$login"; then fail "Sign-out failed."; return; fi
  _LAST_LOGIN=""
  ok "Signed out $login."
  if [ "$(active_account)" = "$login" ]; then
    local left; left=$(gh_accounts | head -1)
    if [ -n "$left" ]; then set_active "$left"; else set_setting ACTIVE ""; fi
  fi
}

show_accounts() {
  local a choice count k login
  while true; do
    say ""
    info "----- GitHub accounts -----"
    local accts; accts=$(gh_accounts)
    [ -z "$accts" ] && say "  (none signed in)"
    for a in $accts; do
      count=0
      for k in $(installed_keys); do [ "$(key_account "$k")" = "$a" ] && count=$((count + 1)); done
      if [ "$a" = "$(active_account)" ]; then say "  - $a (active)    $count runner(s) on this machine"
      else say "  - $a    $count runner(s) on this machine"; fi
    done
    say ""
    say "  1) Switch active account"
    say "  2) Sign in to another account"
    say "  3) Let an account manage organization runners"
    say "  4) Sign out an account"
    say "  0) Back"
    choice=$(ask "Choose an option: ")
    case "$choice" in
      1) login=$(select_account "Switch to which account?"); [ -n "$login" ] && set_active "$login" ;;
      2) add_account ;;
      3) grant_org_permission ;;
      4) remove_account; [ -z "$(active_account)" ] && return ;;
      0) return ;;
      *) warn "Invalid option." ;;
    esac
  done
}

# Picks the account to use at startup (signs in if there is none)
init_account() {
  local accts cur count
  accts=$(gh_accounts)
  if [ -z "$accts" ]; then
    if [ "$QUIET" = "1" ]; then fail "No GitHub account is signed in. Run the script without options once to sign in."; return 1; fi
    info "Welcome! No GitHub account is signed in yet. Let's sign in."
    add_account || return 1
    accts=$(gh_accounts)
    [ -z "$accts" ] && return 1
  fi

  if [ -n "$ACCOUNT_OVERRIDE" ]; then
    if ! printf '%s\n' "$accts" | grep -qixF "$ACCOUNT_OVERRIDE"; then
      fail "Account '$ACCOUNT_OVERRIDE' isn't signed in. Signed in: $(printf '%s ' $accts)"
      return 1
    fi
  else
    cur=$(setting ACTIVE "")
    if [ -z "$cur" ] || ! printf '%s\n' "$accts" | grep -qixF "$cur"; then
      count=$(printf '%s\n' "$accts" | wc -l | tr -d ' ')
      if [ "$count" = "1" ] || [ "$QUIET" = "1" ]; then cur=$(printf '%s\n' "$accts" | head -1)
      else
        cur=$(select_account "Which GitHub account do you want to use?")
        [ -z "$cur" ] && cur=$(printf '%s\n' "$accts" | head -1)
      fi
      set_setting ACTIVE "$cur"
    fi
  fi

  _LAST_LOGIN=""
  unset GH_TOKEN
  use_account "$(active_account)"
  if [ -z "$GH_TOKEN" ]; then
    fail "Couldn't get a sign-in token for $(active_account). Sign in again from Accounts, or run: gh auth login"
    return 1
  fi

  # Having a saved token doesn't mean GitHub still accepts it
  if [ "$(sign_in_state)" = "expired" ]; then
    fail "GitHub no longer accepts the sign-in for $(active_account) (it expired or was revoked)."
    if [ "$QUIET" = "1" ]; then fail "Run the script without options once and sign in again."; return 1; fi
    [ "$(ask "Sign in again now? (y/n) ")" = "y" ] || return 1
    add_account || return 1
    [ "$(sign_in_state)" = "expired" ] && { fail "The sign-in still isn't accepted."; return 1; }
  fi
  return 0
}

# Asks GitHub whether the current token works: prints ok, expired, or unknown
# (unknown = couldn't tell, e.g. no network; a warning is shown and the script carries on)
sign_in_state() {
  local err
  if err=$(gh api user --jq .login 2>&1 >/dev/null); then echo ok; return; fi
  case "$err" in
    *"HTTP 401"*|*"Bad credentials"*) echo expired ;;
    *) warn "Couldn't check the GitHub sign-in: $(printf '%s' "$err" | head -1)"; echo unknown ;;
  esac
}

# Checks the repo/org exists and the managing account can manage its runners
test_access() {
  local key="$1" login admin
  use_key_account "$key"
  login=$(key_account "$key")
  if is_org "$key"; then
    if ! gh api "$(api_base "$key")/actions/runners" >/dev/null 2>&1; then
      fail "$login can't manage runners for organization '$(org_name "$key")'."
      fail "You must be an owner of the org, and the account needs organization permission"
      fail "(main menu > A > 'Let an account manage organization runners')."
      return 1
    fi
    return 0
  fi
  if ! admin=$(gh api "repos/$key" --jq .permissions.admin 2>/dev/null); then
    fail "Repo $key not found (or $login can't see it). Check the name."
    return 1
  fi
  [ "$admin" = "true" ] || { fail "$login needs admin access to $key to manage its runner."; return 1; }
  return 0
}

# =====================================================================
#  Folders
# =====================================================================
# Cleans up a typed or dragged-in path: quotes, ~, escaped spaces, trailing /
clean_path() {
  local p; p=$(trim "$1")
  p="${p#\"}"; p="${p%\"}"; p="${p#\'}"; p="${p%\'}"
  p=$(printf '%s' "$p" | sed 's/\\ / /g')
  case "$p" in
    "~")   p="$HOME" ;;
    "~/"*) p="$HOME/${p#\~/}" ;;
  esac
  [ "$p" != "/" ] && p="${p%/}"
  printf '%s' "$p"
}

check_folder() {
  local p="$1" parent
  case "$p" in
    /*) ;;
    *)  fail "Please enter a full path, like $HOME/actions-runners"; return 1 ;;
  esac
  if [ "$p" = "/" ] || [ "$p" = "$HOME" ]; then fail "Please choose a folder of its own, like $HOME/actions-runners"; return 1; fi

  parent="$p"
  while [ ! -d "$parent" ]; do parent=$(dirname "$parent"); done
  if [ ! -w "$parent" ]; then
    fail "You can't create folders in $parent. Choose a folder in your home directory, like $HOME/actions-runners"
    return 1
  fi

  local warned=0
  case "$p" in *" "*) warn "Warning: the path has spaces. Some build tools break on paths with spaces."; warned=1 ;; esac
  if [ "$warned" = "1" ] && [ "$QUIET" = "0" ]; then
    [ "$(ask "Use this folder anyway? (y/n) ")" = "y" ] || return 1
  fi
  return 0
}

# Prints the chosen folder
read_folder() {
  local answer
  answer=$(ask "$1 [Enter = $2]: ")
  [ -z "$answer" ] && answer="$2"
  answer=$(clean_path "$answer")
  check_folder "$answer" || return 1
  printf '%s' "$answer"
}

folder_empty() { [ ! -d "$1" ] || [ -z "$(ls -A "$1" 2>/dev/null)" ]; }

safe_rm() {
  case "$1" in
    ""|"/"|"$HOME"|"$HOME/") fail "Refusing to delete '$1'."; return 1 ;;
  esac
  rm -rf "$1" 2>/dev/null
  [ ! -e "$1" ]
}

# Asks where to put one or more runners. Fills PLAN_KEYS / PLAN_DIRS. Returns 1 if cancelled.
folder_plan() {
  PLAN_KEYS=(); PLAN_DIRS=()
  local key d count=$#
  if [ "$count" -eq 1 ]; then
    d=$(read_folder "Folder for the $(display_name "$1") runner" "$(default_dir "$1")") || return 1
    PLAN_KEYS=("$1"); PLAN_DIRS=("$d")
    return 0
  fi
  local use_default
  use_default=$(ask "Put all $count runners under $(runners_root)? (y = yes, n = choose a folder for each) ")
  for key in "$@"; do
    if [ "$use_default" = "y" ]; then d=$(default_dir "$key")
    else
      d=$(read_folder "Folder for the $(display_name "$key") runner" "$(default_dir "$key")") || { info "Cancelled. Nothing was changed."; return 1; }
    fi
    PLAN_KEYS+=("$key"); PLAN_DIRS+=("$d")
  done
  return 0
}

# =====================================================================
#  Finding runners on this machine
# =====================================================================
json_field() {   # file field -> value of "field": "value"
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" 2>/dev/null | head -1
}

service_files() {
  if is_mac; then ls -1 "$HOME"/Library/LaunchAgents/actions.runner.*.plist 2>/dev/null
  else ls -1 /etc/systemd/system/actions.runner.*.service 2>/dev/null; fi
}

service_dir_of() {
  local d
  if is_mac; then
    d=$(plutil -extract WorkingDirectory raw -o - "$1" 2>/dev/null)
    if [ -z "$d" ]; then
      d=$(plutil -extract ProgramArguments.0 raw -o - "$1" 2>/dev/null)
      [ -n "$d" ] && d=$(dirname "$d")
    fi
  else
    d=$(sed -n 's/^WorkingDirectory=//p' "$1" | head -1)
    [ -z "$d" ] && d=$(dirname "$(sed -n 's/^ExecStart=//p' "$1" | head -1 | awk '{print $1}')")
  fi
  printf '%s' "$d"
}

# Installed runners, one per line: key|folder|service file|runner name
machine_list() {
  local f d url key name
  for f in $(service_files); do
    d=$(service_dir_of "$f")
    [ -n "$d" ] && [ -f "$d/.runner" ] || continue
    url=$(json_field "$d/.runner" gitHubUrl)
    key=$(url_to_key "$url")
    [ -n "$key" ] || continue
    name=$(json_field "$d/.runner" agentName)
    printf '%s|%s|%s|%s\n' "$key" "$d" "$(basename "$f")" "$name"
  done
}

key_for_folder() {   # folder relative-name
  local url k
  if [ -f "$1/.runner" ]; then
    url=$(json_field "$1/.runner" gitHubUrl); k=$(url_to_key "$url")
    [ -n "$k" ] && { printf '%s' "$k"; return; }
  fi
  case "$2" in
    org-*) printf 'org:%s' "${2#org-}" ;;
    *)     full_key "$2" ;;
  esac
}

# Runner folders inside the default folder (one or two levels deep): key|folder
folder_list() {
  local root d sub
  root=$(runners_root)
  [ -d "$root" ] || return 0
  for d in "$root"/*; do
    [ -d "$d" ] || continue
    if [ -f "$d/config.sh" ]; then
      printf '%s|%s\n' "$(key_for_folder "$d" "$(basename "$d")")" "$d"
      continue
    fi
    for sub in "$d"/*; do
      [ -f "$sub/config.sh" ] || continue
      printf '%s|%s\n' "$(key_for_folder "$sub" "$(basename "$d")/$(basename "$sub")")" "$sub"
    done
  done
}

refresh_machine() { MACHINE_CACHE=$(machine_list); FOLDER_CACHE=$(folder_list); MACHINE_VALID=1; }
reset_cache()     { MACHINE_VALID=0; }

machine_get() {   # key field (2 = folder, 3 = service file, 4 = runner name)
  [ "$MACHINE_VALID" = "1" ] || refresh_machine
  printf '%s\n' "$MACHINE_CACHE" | awk -F'|' -v k="$1" -v f="$2" 'BEGIN { k = tolower(k) } tolower($1) == k { print $f; exit }'
}

is_installed() { [ -n "$(machine_get "$1" 3)" ]; }

runner_dir() {
  local d
  d=$(machine_get "$1" 2);  [ -n "$d" ] && { printf '%s' "$d"; return; }
  d=$(cfg_get RUNNER "$1"); [ -n "$d" ] && { printf '%s' "$d"; return; }
  [ "$MACHINE_VALID" = "1" ] || refresh_machine
  d=$(printf '%s\n' "$FOLDER_CACHE" | awk -F'|' -v k="$1" 'BEGIN { k = tolower(k) } tolower($1) == k { print $2; exit }')
  [ -n "$d" ] && { printf '%s' "$d"; return; }
  default_dir "$1"
}

runner_name() {
  local n; n=$(machine_get "$1" 4)
  if [ -n "$n" ]; then printf '%s' "$n"; else new_runner_name "$1"; fi
}

# Every runner we know about: your list + saved + installed + found in the default folder
all_keys() {
  [ "$MACHINE_VALID" = "1" ] || refresh_machine
  {
    cfg_keys LIST
    cfg_keys RUNNER
    printf '%s\n' "$MACHINE_CACHE" | cut -d'|' -f1
    printf '%s\n' "$FOLDER_CACHE" | cut -d'|' -f1
  } | grep -v '^$' | sort -fu
}

installed_keys() { local k; for k in $(all_keys); do is_installed "$k" && echo "$k"; done; }

service_state() {
  local svc label pid
  svc=$(machine_get "$1" 3)
  [ -z "$svc" ] && { echo "Not installed"; return; }
  if is_mac; then
    label="${svc%.plist}"
    pid=$(launchctl list 2>/dev/null | awk -v l="$label" '$3 == l { print $1; exit }')
    if [ -n "$pid" ] && [ "$pid" != "-" ]; then echo "Running"; else echo "Stopped"; fi
  else
    case "$(systemctl is-active "$svc" 2>/dev/null)" in
      active)     echo "Running" ;;
      activating) echo "Starting" ;;
      failed)     echo "Failed" ;;
      *)          echo "Stopped" ;;
    esac
  fi
}

# Runs svc.sh in the runner folder (with sudo on Linux)
svc_cmd() {   # key action [args]
  local dir; dir=$(runner_dir "$1")
  [ -f "$dir/svc.sh" ] || { fail "No svc.sh in $dir."; return 1; }
  local action="$2"; shift 2
  if is_mac; then ( cd "$dir" && ./svc.sh "$action" "$@" )
  else ( cd "$dir" && sudo ./svc.sh "$action" "$@" ); fi
}

# The runner as GitHub sees it: id|status|busy|custom labels (empty if not found)
github_runner() {   # key [name]
  local name="${2:-$(runner_name "$1")}"
  use_key_account "$1"
  gh api "$(api_base "$1")/actions/runners?per_page=100" \
    --jq ".runners[] | select(.name == \"$name\") | \"\(.id)|\(.status)|\(.busy)|\([.labels[] | select(.type == \"custom\") | .name] | join(\",\"))\"" \
    2>/dev/null | head -1
}

# Numbered list of runners; prints the chosen key(s). Pass "all" as $2 to allow choosing all.
select_runner() {
  local keys k i=0 choice arr=()
  keys=$(all_keys)
  [ -z "$keys" ] && { warn "No runners yet. Use option 2 to add one."; return 1; }
  say ""; say "$1"
  for k in $keys; do
    arr+=("$k"); i=$((i + 1))
    say "  $i) $(display_name "$k")  [$(service_state "$k")]  $(runner_dir "$k")"
  done
  [ "$2" = "all" ] && say "  A) All installed runners"
  choice=$(ask "Choose (or press Enter to cancel): ")
  [ -z "$choice" ] && return 1
  if [ "$2" = "all" ] && [ "$(lower "$choice")" = "a" ]; then installed_keys; return 0; fi
  case "$choice" in *[!0-9]*) warn "Invalid choice."; return 1 ;; esac
  if [ "$choice" -ge 1 ] && [ "$choice" -le "${#arr[@]}" ]; then echo "${arr[$((choice - 1))]}"; return 0; fi
  warn "Invalid choice."; return 1
}

# Lists repos the active account can manage; prints the picked ones
select_repos() {
  local owner repos r i=0 mark answer n arr=() err
  owner=$(ask "Whose repos? GitHub user or org name [Enter = $(active_account)]: ")
  owner=$(trim "$owner"); [ -z "$owner" ] && owner=$(active_account)
  use_account "$(active_account)"
  info "Loading repos where $(active_account) is an admin..."
  # Keep gh's error message: a failed call (expired sign-in, no network, unknown
  # owner) must not look the same as "you're not an admin of any repo"
  err=$(mktemp)
  if ! repos=$(gh repo list "$owner" --limit 300 --json nameWithOwner,viewerPermission,isArchived \
      --jq '.[] | select(.viewerPermission == "ADMIN" and (.isArchived | not)) | .nameWithOwner' 2>"$err"); then
    fail "Could not list repos for $owner."
    [ -s "$err" ] && dim "  GitHub CLI said: $(head -3 "$err")"
    rm -f "$err"; return 1
  fi
  rm -f "$err"
  repos=$(printf '%s\n' "$repos" | grep -v '^$' | sort -f)
  [ -z "$repos" ] && { warn "No repos found where $(active_account) is an admin of $owner's repos."; return 1; }

  say ""
  for r in $repos; do
    arr+=("$r"); i=$((i + 1)); mark=""
    is_installed "$r" && mark="  [already installed]"
    say "$(printf '  %3d) %s%s' "$i" "$r" "$mark")"
  done
  answer=$(ask "Choose numbers (e.g. 1,3,5 or 2-4 or all), or Enter to cancel: ")
  [ -z "$answer" ] && return 1
  for n in $(parse_numbers "$answer" "${#arr[@]}"); do echo "${arr[$((n - 1))]}"; done
}

resolve_targets() { if [ "$1" = "all" ]; then installed_keys; else full_key "$1"; fi; }

# =====================================================================
#  Runner download
# =====================================================================
verify_archive() {   # file [checksum]
  local sum
  sum=$(printf '%s' "$2" | grep -oE '[0-9a-fA-F]{64}' | head -1)
  if [ -n "$sum" ]; then
    if [ "$(lower "$sum")" != "$(sha256_of "$1")" ]; then fail "Checksum doesn't match. The file was not used."; return 1; fi
    ok "Checksum OK."
  fi
  if ! tar -tzf "$1" 2>/dev/null | grep -q '^\(\./\)\{0,1\}config\.sh$'; then
    fail "That file doesn't look like a GitHub runner package (no config.sh inside)."
    return 1
  fi
  return 0
}

download_latest_archive() {
  local path url
  path=$(archive_path)
  info "Finding the latest GitHub runner for $PLATFORM..."
  url=$(gh api repos/actions/runner/releases/latest --jq '.assets[].browser_download_url' 2>/dev/null |
        grep -E "/actions-runner-${PLATFORM}-[0-9.]+\.tar\.gz$" | head -1)
  [ -z "$url" ] && { fail "Couldn't find the $PLATFORM runner download."; return 1; }
  mkdir -p "$(dirname "$path")"
  info "Downloading $(basename "$url")..."
  if ! curl -fL --progress-bar -o "$path.part" "$url"; then fail "Download failed."; rm -f "$path.part"; return 1; fi
  verify_archive "$path.part" "" || { rm -f "$path.part"; return 1; }
  mv "$path.part" "$path"
  ok "Saved to $path"
}

download_from_link() {
  local path url sum
  path=$(archive_path)
  info "Copy the link from a repo's Settings > Actions > Runners > New self-hosted runner"
  info "(choose $PLATFORM), or from https://github.com/actions/runner/releases"
  url=$(trim "$(ask "Download link: ")")
  case "$url" in https://*) ;; *) fail "The link should start with https://"; return 1 ;; esac
  case "$url" in
    *"actions-runner-$PLATFORM-"*) ;;
    *) warn "This link doesn't look like the $PLATFORM runner (expected 'actions-runner-$PLATFORM-' in it)."
       [ "$(ask "Use it anyway? (y/n) ")" = "y" ] || return 1 ;;
  esac
  mkdir -p "$(dirname "$path")"
  info "Downloading..."
  if ! curl -fL --progress-bar -o "$path.part" "$url"; then fail "Download failed. Check the link."; rm -f "$path.part"; return 1; fi
  sum=$(ask "SHA-256 checksum to verify (optional, shown on GitHub's release page; Enter to skip): ")
  verify_archive "$path.part" "$sum" || { rm -f "$path.part"; return 1; }
  mv "$path.part" "$path"
  ok "Saved to $path"
}

use_local_archive() {
  local path src sum
  path=$(archive_path)
  src=$(clean_path "$(ask "Path to the runner .tar.gz file (you can drag it into this window): ")")
  [ -f "$src" ] || { fail "File not found: $src"; return 1; }
  sum=$(ask "SHA-256 checksum to verify (optional; Enter to skip): ")
  verify_archive "$src" "$sum" || return 1
  mkdir -p "$(dirname "$path")"
  cp "$src" "$path" && ok "Copied to $path"
}

ensure_archive() {
  [ -f "$(archive_path)" ] && return 0
  if [ "$QUIET" = "1" ]; then download_latest_archive; return $?; fi
  warn "The runner download for $PLATFORM wasn't found at:"
  warn "  $(archive_path)"
  say "  1) Download the latest version automatically"
  say "  2) Paste a download link"
  say "  3) Use a file already on this computer"
  case "$(ask "Choose (or Enter to cancel): ")" in
    1) download_latest_archive ;;
    2) download_from_link ;;
    3) use_local_archive ;;
    *) return 1 ;;
  esac
}

# =====================================================================
#  Status
# =====================================================================
show_status() {
  local key dir state gr gh_state labels color fmt
  echo
  info "Account: $(active_account)    Default folder: $(runners_root)    Platform: $PLATFORM"
  info "Checking GitHub..."
  fmt='%-30s %-14s %-13s %-8s %-16s %s\n'
  printf "$fmt" "Runner" "Account" "Service" "GitHub" "Labels" "Folder"
  printf "$fmt" "------" "-------" "-------" "------" "------" "------"
  for key in $(all_keys); do
    dir=$(runner_dir "$key")
    state=$(service_state "$key")
    gr=$(github_runner "$key")
    if [ -z "$gr" ]; then gh_state="-"
    else
      case "$gr" in
        *"|online|true|"*)  gh_state="Busy" ;;
        *"|online|"*)       gh_state="Online" ;;
        *)                  gh_state="Offline" ;;
      esac
    fi
    if [ -n "$gr" ]; then labels="${gr##*|}"; else labels=$(cfg_get LABELS "$key"); fi
    [ -z "$labels" ] && labels="-"
    case "$gh_state" in
      Online|Busy) color='\033[32m' ;;
      *) if [ "$state" = "Not installed" ]; then color='\033[90m'; else color='\033[33m'; fi ;;
    esac
    printf "$color$fmt\033[0m" "$(display_name "$key")" "$(key_account "$key")" "$state" "$gh_state" "$labels" "$dir"
  done
  echo
  dim "GitHub: Online = ready, Busy = running a job, Offline = not connected, - = not set up"
}

# =====================================================================
#  Add / remove / move
# =====================================================================
deps_ok() {
  is_mac && return 0
  { ldconfig -p 2>/dev/null || /sbin/ldconfig -p 2>/dev/null; } | grep -q libicu
}

install_service() {   # key
  local key="$1" dir; dir=$(runner_dir "$key")
  if is_mac; then
    ( cd "$dir" && ./svc.sh install && ./svc.sh start ) || return 1
  elif has_systemd; then
    ( cd "$dir" && sudo ./svc.sh install "$(id -un)" && sudo ./svc.sh start ) || return 1
  else
    warn "This Linux has no systemd, so the runner can't run as a background service."
    warn "Starting it in the background for now (it won't restart after a reboot)."
    ( cd "$dir" && nohup ./run.sh > "$dir/run.log" 2>&1 & )
  fi
  return 0
}

# Sets up a runner for key in folder dir. Returns 0 on success.
install_runner() {
  local key="$1" dir="$2" label token labels
  label=$(display_name "$key")
  if is_installed "$key"; then
    warn "$label is already installed on this machine ($(runner_dir "$key")). Remove it first to set it up again."
    return 1
  fi
  if [ -f "$dir/.runner" ]; then warn "$dir already has a configured runner. Remove it first, or choose another folder."; return 1; fi
  if ! folder_empty "$dir" && [ ! -f "$dir/config.sh" ]; then
    warn "$dir already has other files in it. Use an empty folder or a new folder name."
    return 1
  fi
  test_access "$key" || return 1
  ensure_archive || return 1

  info "Setting up $label in $dir (as $(key_account "$key")) ..."
  mkdir -p "$dir" || { fail "Couldn't create $dir."; return 1; }
  tar -xzf "$(archive_path)" -C "$dir" || { fail "Couldn't extract the runner. Delete the download in Cleanup and try again."; return 1; }
  # A package downloaded in a browser carries macOS's quarantine flag, which would block the runner from starting
  is_mac && xattr -dr com.apple.quarantine "$dir" 2>/dev/null

  if ! deps_ok; then
    info "Installing the runner's system libraries (needs your password)..."
    ( cd "$dir" && sudo ./bin/installdependencies.sh ) || warn "Couldn't install dependencies automatically. If setup fails, run: sudo $dir/bin/installdependencies.sh"
  fi

  use_key_account "$key"
  token=$(gh api -X POST "$(api_base "$key")/actions/runners/registration-token" --jq .token 2>/dev/null)
  [ -z "$token" ] && { fail "Could not get a registration token for $label."; return 1; }

  labels=$(cfg_get LABELS "$key")
  local extra=()
  [ -n "$labels" ] && extra=(--labels "$labels")

  if ! ( cd "$dir" && ./config.sh --unattended --url "$(target_url "$key")" --token "$token" \
           --name "$(new_runner_name "$key")" --replace "${extra[@]}" ); then
    fail "Setup failed for $label (see messages above)."
    reset_cache
    return 1
  fi

  cfg_put RUNNER "$key" "$dir"
  cfg_put ACCOUNT "$key" "$(key_account "$key")"
  refresh_machine

  info "Installing the background service..."
  install_service "$key" || warn "The runner is registered, but the service didn't install. Start it manually: cd \"$dir\" && ./run.sh"
  refresh_machine

  ok "Done: $label  ->  $dir"
  is_mac && dim "On macOS the runner works while you're logged in (a locked screen is fine)."
  return 0
}

remove_service_file() {   # service file name
  local svc="$1"
  [ -z "$svc" ] && return 0
  if is_mac; then
    local plist="$HOME/Library/LaunchAgents/$svc"
    [ -f "$plist" ] || return 0
    launchctl unload "$plist" >/dev/null 2>&1
    rm -f "$plist"
  else
    [ -f "/etc/systemd/system/$svc" ] || return 0
    sudo systemctl disable --now "$svc" >/dev/null 2>&1
    sudo rm -f "/etc/systemd/system/$svc"
    sudo systemctl daemon-reload
  fi
}

remove_runner() {   # key [forget]
  local key="$1" label dir name svc token gr
  label=$(display_name "$key"); dir=$(runner_dir "$key"); name=$(runner_name "$key"); svc=$(machine_get "$key" 3)
  info "Removing $label ($dir)..."
  use_key_account "$key"

  # 1. Stop and uninstall the background service
  if [ -n "$svc" ] && [ -f "$dir/svc.sh" ]; then
    if is_mac; then ( cd "$dir" && ./svc.sh stop; ./svc.sh uninstall ) >/dev/null 2>&1
    else ( cd "$dir" && sudo ./svc.sh stop; sudo ./svc.sh uninstall ) >/dev/null 2>&1; fi
  fi
  remove_service_file "$svc"

  # 2. Unregister from GitHub
  if [ -f "$dir/.runner" ]; then
    token=$(gh api -X POST "$(api_base "$key")/actions/runners/remove-token" --jq .token 2>/dev/null)
    [ -n "$token" ] && ( cd "$dir" && ./config.sh remove --token "$token" )
  fi
  gr=$(github_runner "$key" "$name")
  [ -n "$gr" ] && gh api -X DELETE "$(api_base "$key")/actions/runners/${gr%%|*}" >/dev/null 2>&1

  # 3. Delete the folder and saved details (labels are kept for a re-install)
  if [ -d "$dir" ]; then
    safe_rm "$dir" || warn "Could not fully delete $dir. Delete it manually."
  fi
  cfg_del RUNNER "$key"
  [ "$2" = "forget" ] && cfg_del ACCOUNT "$key"
  reset_cache; refresh_machine
  ok "Removed: $label"
}

add_runners() {
  local keys=() line typed i ok_keys=()
  say ""
  info "Adding runners as $(active_account)  (to use another account, press A in the main menu)"
  say "  1) Pick from a list of repos"
  say "  2) Type a repo (name, owner/name or GitHub URL)"
  say "  3) Organization runner (one runner shared by all the org's repos)"
  case "$(ask "Choose (or Enter to cancel): ")" in
    1) while IFS= read -r line; do [ -n "$line" ] && keys+=("$line"); done < <(select_repos) ;;
    2) typed=$(ask "Repo: "); [ -n "$typed" ] && keys=("$(full_key "$typed")") ;;
    3) typed=$(trim "$(ask "Organization name (as in github.com/<name>): ")"); [ -n "$typed" ] && keys=("org:$typed") ;;
    *) return ;;
  esac
  [ "${#keys[@]}" -eq 0 ] && return

  folder_plan "${keys[@]}" || return
  i=0
  while [ "$i" -lt "${#PLAN_KEYS[@]}" ]; do
    is_installed "${PLAN_KEYS[$i]}" || cfg_put ACCOUNT "${PLAN_KEYS[$i]}" "$(active_account)"
    install_runner "${PLAN_KEYS[$i]}" "${PLAN_DIRS[$i]}" && ok_keys+=("${PLAN_KEYS[$i]}")
    i=$((i + 1))
  done

  local not_listed=() k
  for k in "${ok_keys[@]}"; do cfg_has LIST "$k" || not_listed+=("$k"); done
  if [ "${#not_listed[@]}" -gt 0 ] &&
     [ "$(ask "Add ${#not_listed[@]} runner(s) to your list so 'Fresh start' includes them? (y/n) ")" = "y" ]; then
    for k in "${not_listed[@]}"; do cfg_put LIST "$k" ""; done
  fi
}

move_runner() {
  local key old new
  key=$(select_runner "Which runner do you want to move?") || return
  old=$(runner_dir "$key")
  info "Current folder: $old"
  new=$(read_folder "New folder for the $(display_name "$key") runner" "$(default_dir "$key")") || return
  [ "$new" = "$old" ] && { warn "That's the same folder."; return; }
  folder_empty "$new" || { warn "$new is not empty. Choose an empty or new folder."; return; }
  test_access "$key" || return
  info "Moving = removing the runner and setting it up again in the new folder."
  remove_runner "$key"
  install_runner "$key" "$new"
}

# =====================================================================
#  Start / stop
# =====================================================================
start_runner() {
  is_installed "$1" || { warn "$(display_name "$1") isn't installed on this machine."; return; }
  if svc_cmd "$1" start >/dev/null 2>&1; then ok "Started: $(display_name "$1")"
  else fail "Could not start $(display_name "$1"). Use 'View a runner's log' to see why."; fi
}

stop_runner() {
  is_installed "$1" || { warn "$(display_name "$1") isn't installed on this machine."; return; }
  svc_cmd "$1" stop >/dev/null 2>&1
  ok "Stopped: $(display_name "$1")"
}

restart_runner() {
  is_installed "$1" || { warn "$(display_name "$1") isn't installed on this machine."; return; }
  svc_cmd "$1" stop >/dev/null 2>&1
  svc_cmd "$1" start >/dev/null 2>&1
  ok "Restarted: $(display_name "$1")"
}

restart_all() {
  local keys k; keys=$(installed_keys)
  [ -z "$keys" ] && { warn "No runners are installed."; return; }
  for k in $keys; do restart_runner "$k"; done
}

# =====================================================================
#  Labels
# =====================================================================
set_labels() {
  local key="$1" label gr id current answer cleaned l
  label=$(display_name "$key")
  gr=$(github_runner "$key")
  if [ -n "$gr" ]; then current="${gr##*|}"; id="${gr%%|*}"; else current=$(cfg_get LABELS "$key"); fi

  say ""
  info "Built-in labels (always there): self-hosted, $(is_mac && echo macOS || echo Linux), $(echo "${PLATFORM#*-}" | tr '[:lower:]' '[:upper:]')"
  info "Your labels on $label: ${current:-(none)}"
  answer=$(ask "New labels, comma-separated, e.g. swift,xcode16 (Enter = keep, - = remove all): ")
  [ -z "$answer" ] && return

  cleaned=""
  if [ "$(trim "$answer")" != "-" ]; then
    cleaned=$(printf '%s' "$answer" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | paste -sd, -)
    case "$cleaned" in *" "*) fail "Labels can't contain spaces."; return ;; esac
  fi

  if [ -n "$cleaned" ]; then cfg_put LABELS "$key" "$cleaned"; else cfg_del LABELS "$key"; fi

  if [ -n "$id" ]; then
    use_key_account "$key"
    if [ -n "$cleaned" ]; then
      local args=(api -X PUT "$(api_base "$key")/actions/runners/$id/labels")
      local IFS_SAVE="$IFS"; IFS=,
      for l in $cleaned; do args+=(-f "labels[]=$l"); done
      IFS="$IFS_SAVE"
      gh "${args[@]}" >/dev/null 2>&1
    else
      gh api -X DELETE "$(api_base "$key")/actions/runners/$id/labels" >/dev/null 2>&1
    fi
    if [ $? -eq 0 ]; then ok "Labels updated on GitHub."; else fail "GitHub didn't accept the labels."; fi
  else
    info "Saved. They'll be applied when this runner is set up."
  fi
  [ -n "$cleaned" ] && info "Use them in a workflow:  runs-on: [self-hosted, $(printf '%s' "$cleaned" | sed 's/,/, /g')]"
}

# =====================================================================
#  Logs
# =====================================================================
show_log() {
  local key="$1" dir file svc
  dir=$(runner_dir "$key")
  file=$(ls -t "$dir"/_diag/Runner_*.log 2>/dev/null | head -1)
  if [ -n "$file" ]; then
    echo
    info "Last 40 lines of $file"
    tail -n 40 "$file" | while IFS= read -r line; do
      case "$line" in
        *" ERR "*|*Exception*|*rror*) printf '\033[31m%s\033[0m\n' "$line" ;;
        *" WARN "*)                   printf '\033[33m%s\033[0m\n' "$line" ;;
        *)                            printf '%s\n' "$line" ;;
      esac
    done
  else
    warn "No runner logs in $dir/_diag. The runner may never have started."
  fi

  svc=$(machine_get "$key" 3)
  if [ -n "$svc" ] && confirm_fix "Show the background service's log too?"; then
    if is_mac; then
      local logdir="$HOME/Library/Logs/${svc%.plist}"
      tail -n 30 "$logdir/stderr.log" "$logdir/stdout.log" 2>/dev/null || warn "No service logs in $logdir."
    else
      sudo journalctl -u "$svc" -n 40 --no-pager
    fi
  fi
  info "Tip: logs for individual jobs are on GitHub, in the repo's Actions tab."
  if [ -n "$file" ] && confirm_fix "Open the full runner log?"; then less "$file"; fi
}

# =====================================================================
#  Cleanup
# =====================================================================
folder_size_mb() { [ -d "$1" ] || { echo 0; return; }; du -sk "$1" 2>/dev/null | awk '{ printf "%.1f", $1 / 1024 }'; }

clean_work() {   # key include_tools(0/1)
  local key="$1" label work gr before after was_running item
  label=$(display_name "$key")
  work="$(runner_dir "$key")/_work"
  [ -d "$work" ] || { info "$label: nothing to clean."; return; }
  gr=$(github_runner "$key")
  case "$gr" in *"|online|true|"*) warn "$label is running a job right now. Skipped."; return ;; esac

  before=$(folder_size_mb "$work")
  was_running=0
  [ "$(service_state "$key")" = "Running" ] && was_running=1
  [ "$was_running" = "1" ] && svc_cmd "$key" stop >/dev/null 2>&1

  for item in "$work"/* "$work"/.[!.]*; do
    [ -e "$item" ] || continue
    [ "$2" != "1" ] && [ "$(basename "$item")" = "_tool" ] && continue
    rm -rf "$item"
  done

  [ "$was_running" = "1" ] && svc_cmd "$key" start >/dev/null 2>&1
  after=$(folder_size_mb "$work")
  ok "$label: freed $(awk -v a="$before" -v b="$after" 'BEGIN { printf "%.1f", a - b }') MB"
}

clean_work_menu() {
  local keys k tools
  keys=$(select_runner "Clean work folders for which runner?" all) || return
  info "Work folders hold checked-out code and build files. They're recreated on the next job."
  tools=0
  [ "$(ask "Also delete the tool cache (Node/PHP versions downloaded by setup actions)? (y/n) ")" = "y" ] && tools=1
  for k in $keys; do clean_work "$k" "$tools"; done
}

clean_old_logs() {
  local key diag count=0 kb=0 n s
  for key in $(all_keys); do
    diag="$(runner_dir "$key")/_diag"
    [ -d "$diag" ] || continue
    n=$(find "$diag" -type f -mtime +7 | wc -l | tr -d ' ')
    s=$(find "$diag" -type f -mtime +7 -exec du -k {} + 2>/dev/null | awk '{ t += $1 } END { print t + 0 }')
    find "$diag" -type f -mtime +7 -delete 2>/dev/null
    count=$((count + n)); kb=$((kb + s))
  done
  ok "Deleted $count old log file(s), freed $(awk -v k="$kb" 'BEGIN { printf "%.1f", k / 1024 }') MB."
}

# Offline runners on GitHub with this machine's name prefix that no longer exist here
clean_stale_github() {
  local key base seen=" " local_names found=0 line id name status prefix
  prefix=$(runner_prefix)
  local_names=" $(printf '%s\n' "$MACHINE_CACHE" | cut -d'|' -f4 | tr '\n' ' ') "
  for key in $(all_keys); do
    base=$(api_base "$key")
    case "$seen" in *" $base "*) continue ;; esac
    seen="$seen$base "
    use_key_account "$key"
    while IFS='|' read -r id name status; do
      [ -z "$id" ] && continue
      case "$name" in "$prefix"*) ;; *) continue ;; esac
      [ "$status" = "online" ] && continue
      case "$local_names" in *" $name "*) continue ;; esac
      found=$((found + 1))
      warn "Stale on GitHub: $name in $base (offline, not on this machine)"
      if [ "$QUIET" = "1" ] || [ "$(ask "  Delete it from GitHub? (y/n) ")" = "y" ]; then
        if gh api -X DELETE "$base/actions/runners/$id" >/dev/null 2>&1; then ok "  Deleted."; else fail "  Could not delete it."; fi
      fi
    done < <(gh api "$base/actions/runners?per_page=100" --jq '.runners[] | "\(.id)|\(.name)|\(.status)"' 2>/dev/null)
  done
  [ "$found" -eq 0 ] && ok "No stale runners on GitHub."
}

# Half-finished runner folders, and services whose runner folder is gone or broken
clean_leftovers() {
  local found=0 line key dir f
  [ "$MACHINE_VALID" = "1" ] || refresh_machine
  while IFS='|' read -r key dir; do
    [ -z "$dir" ] && continue
    [ -f "$dir/.runner" ] && continue
    is_installed "$key" && continue
    found=$((found + 1))
    warn "Leftover folder: $dir (never finished setting up)"
    if [ "$QUIET" = "1" ] || [ "$(ask "  Delete it? (y/n) ")" = "y" ]; then
      if safe_rm "$dir"; then ok "  Deleted."; else fail "  Could not delete it."; fi
      [ "$(cfg_get RUNNER "$key")" = "$dir" ] && cfg_del RUNNER "$key"
    fi
  done <<EOF
$FOLDER_CACHE
EOF

  for f in $(service_files); do
    dir=$(service_dir_of "$f")
    [ -n "$dir" ] && [ -f "$dir/.runner" ] && continue
    found=$((found + 1))
    warn "Broken service: $(basename "$f") (its runner folder is missing or not set up: $dir)"
    if [ "$QUIET" = "1" ] || [ "$(ask "  Delete this service? (y/n) ")" = "y" ]; then
      remove_service_file "$(basename "$f")" && ok "  Deleted."
    fi
  done
  reset_cache; refresh_machine
  [ "$found" -eq 0 ] && ok "No leftovers found."
}

clean_archive() {
  local path; path=$(archive_path)
  [ -f "$path" ] || { ok "No runner download to delete."; return; }
  rm -f "$path"
  ok "Deleted the runner download. The latest version is downloaded next time you add a runner."
}

full_cleanup() {
  local k
  for k in $(installed_keys); do clean_work "$k" 0; done
  clean_old_logs
  clean_stale_github
  clean_leftovers
}

cleanup_menu() {
  while true; do
    say ""
    info "----- Cleanup -----"
    say "  1) Work folders (checked-out code and build files)"
    say "  2) Old log files (older than 7 days)"
    say "  3) Stale runners on GitHub (offline, no longer on this machine)"
    say "  4) Leftovers from failed setups (folders and broken services)"
    say "  5) Runner download (forces a fresh download next time)"
    say "  6) All of the above (asks before each delete)"
    say "  0) Back"
    case "$(ask "Choose an option: ")" in
      1) clean_work_menu ;;
      2) clean_old_logs ;;
      3) clean_stale_github ;;
      4) clean_leftovers ;;
      5) clean_archive ;;
      6) full_cleanup; clean_archive ;;
      0) return ;;
      *) warn "Invalid option." ;;
    esac
  done
}

# =====================================================================
#  Health check
# =====================================================================
find_in_path() {   # tool pathstring
  local IFS=: p
  for p in $2; do
    [ -n "$p" ] && [ -x "$p/$1" ] && { printf '%s' "$p/$1"; return 0; }
  done
  return 1
}

health_check() {
  local a key dir tools tool k missing path_file runner_path need_refresh=0 mounts m free_kb
  echo
  info "===== Health check ====="

  echo; echo "GitHub CLI: $(gh --version | head -1)"
  echo "GitHub accounts:"
  for a in $(gh_accounts); do
    if [ -n "$(account_token "$a")" ]; then ok "  $a  signed in"; else warn "  $a  sign-in problem (sign in again from Accounts)"; fi
  done

  show_status

  # Disk space
  echo "Disk space:"
  mounts=""
  for key in $(all_keys) _root_; do
    if [ "$key" = "_root_" ]; then dir=$(runners_root); else dir=$(runner_dir "$key"); fi
    while [ ! -d "$dir" ]; do dir=$(dirname "$dir"); done
    m=$(df -Pk "$dir" 2>/dev/null | awk 'NR == 2 { print $6 }')
    case " $mounts " in *" $m "*) continue ;; esac
    mounts="$mounts $m"
    free_kb=$(df -Pk "$dir" 2>/dev/null | awk 'NR == 2 { print $4 }')
    if [ "${free_kb:-0}" -lt 10485760 ]; then warn "  $m  $(awk -v k="$free_kb" 'BEGIN { printf "%.1f", k / 1048576 }') GB free  (low - use Cleanup)"
    else ok "  $m  $(awk -v k="$free_kb" 'BEGIN { printf "%.1f", k / 1048576 }') GB free"; fi
  done

  # Tools: the runner service uses the PATH saved in each runner's .path file at setup time
  echo
  echo "Tools (as the runners see them):"
  tools="git node npm php composer docker swift"
  is_mac && tools="$tools xcodebuild"
  for tool in $tools; do
    missing=""
    for k in $(installed_keys); do
      path_file="$(runner_dir "$k")/.path"
      runner_path=$(cat "$path_file" 2>/dev/null)
      [ -n "$runner_path" ] || continue
      find_in_path "$tool" "$runner_path" >/dev/null || missing="$missing $(display_name "$k")"
    done
    if command -v "$tool" >/dev/null 2>&1; then
      if [ -n "$missing" ]; then
        warn "$(printf '  %-10s' "$tool")Installed, but these runners can't see it:$missing"
        need_refresh=1
      else
        ok "$(printf '  %-10s' "$tool")OK  $(command -v "$tool")"
      fi
    else
      dim "$(printf '  %-10s' "$tool")Not installed"
    fi
  done
  if [ "$need_refresh" = "1" ]; then
    dim "  Runners remember the PATH from when they were set up. Refreshing updates it."
    if confirm_fix "Refresh every runner's PATH and restart them?"; then
      for k in $(installed_keys); do ( cd "$(runner_dir "$k")" && ./env.sh >/dev/null 2>&1 ); restart_runner "$k"; done
    fi
  fi

  # System
  echo
  echo "System:"
  if is_mac; then
    if xcode-select -p >/dev/null 2>&1; then ok "  Xcode tools: $(xcode-select -p)"
    else
      warn "  Xcode command line tools: not installed (needed for git, swift, builds)"
      confirm_fix "Install them now?" && xcode-select --install
    fi
    local sleep_min; sleep_min=$(pmset -g 2>/dev/null | awk '$1 == "sleep" { print $2; exit }')
    if [ "$sleep_min" = "0" ]; then ok "  Sleep: never"
    elif [ -n "$sleep_min" ]; then
      warn "  Sleep: after $sleep_min min (runners stop working while the Mac sleeps)"
      confirm_fix "Turn off sleep while on power (needs your password)?" && sudo pmset -c sleep 0 && ok "  Done."
    fi
    dim "  On macOS, runners work while you're logged in. A locked screen is fine; logging out stops them."
  else
    if has_systemd; then ok "  systemd: available (runners restart after a reboot)"
    else warn "  systemd: not available. Runners won't start automatically after a reboot."; fi
    if deps_ok; then ok "  Runner libraries (libicu): installed"
    else warn "  Runner libraries (libicu): missing. Adding a runner installs them, or run the runner's bin/installdependencies.sh"; fi
  fi
  echo
}

# =====================================================================
#  Fresh start & your list
# =====================================================================
fresh_start() {
  local list others k remove_others=0 i
  list=$(cfg_keys LIST)
  [ -z "$list" ] && { warn "Your list is empty. Add repos with 'Manage your list' first."; return; }

  warn "This removes and sets up again every runner in your list:"
  for k in $list; do say "  - $(display_name "$k")  (account: $(key_account "$k"))"; done

  others=""
  for k in $(installed_keys); do cfg_has LIST "$k" || others="$others $k"; done
  if [ -n "$others" ]; then
    say ""; say "These runners on this machine are NOT in your list:"
    for k in $others; do say "  - $(display_name "$k")"; done
    [ "$(ask "Remove them too? (y/n) ")" = "y" ] && remove_others=1
  fi
  [ "$(ask "Type YES to continue: ")" = "YES" ] || { info "Cancelled."; return; }

  # Decide all folders first, so nothing is removed if you cancel halfway
  # shellcheck disable=SC2086
  folder_plan $list || return

  for k in $list; do
    if is_installed "$k" || [ -d "$(runner_dir "$k")" ]; then remove_runner "$k"; fi
  done
  if [ "$remove_others" = "1" ]; then for k in $others; do remove_runner "$k" forget; done; fi
  i=0
  while [ "$i" -lt "${#PLAN_KEYS[@]}" ]; do install_runner "${PLAN_KEYS[$i]}" "${PLAN_DIRS[$i]}"; i=$((i + 1)); done
  show_status
}

add_to_list() {
  local key="$1"
  [ -z "$key" ] && return
  cfg_has LIST "$key" && { warn "$(display_name "$key") is already in the list."; return; }
  local had_account=1
  cfg_has ACCOUNT "$key" || { had_account=0; cfg_put ACCOUNT "$key" "$(active_account)"; }
  if ! test_access "$key"; then [ "$had_account" = "0" ] && cfg_del ACCOUNT "$key"; return; fi
  cfg_put LIST "$key" ""
  ok "Added $(display_name "$key")."
}

edit_list() {
  local list k i typed nums n arr=() line
  while true; do
    say ""
    info "----- Your list (used by 'Fresh start') -----"
    list=$(cfg_keys LIST); arr=(); i=0
    [ -z "$list" ] && say "  (empty)"
    for k in $list; do arr+=("$k"); i=$((i + 1)); say "  $i) $(display_name "$k")   (account: $(key_account "$k"))"; done
    say ""
    say "  p) Pick repos from a list"
    say "  a) Type a repo"
    say "  o) Add an organization"
    say "  r) Remove from the list"
    say "  0) Back"
    case "$(lower "$(ask "Choose: ")")" in
      p) while IFS= read -r line; do [ -n "$line" ] && add_to_list "$line"; done < <(select_repos) ;;
      a) typed=$(ask "Repo (name, owner/name or GitHub URL): "); [ -n "$typed" ] && add_to_list "$(full_key "$typed")" ;;
      o) typed=$(trim "$(ask "Organization name: ")"); [ -n "$typed" ] && add_to_list "org:$typed" ;;
      r)
        nums=$(parse_numbers "$(ask "Number(s) to remove (e.g. 2 or 1,3): ")" "${#arr[@]}")
        [ -z "$nums" ] && { warn "Invalid number."; continue; }
        for n in $nums; do
          k="${arr[$((n - 1))]}"
          cfg_del LIST "$k"
          ok "Removed $(display_name "$k") from the list."
          if is_installed "$k" && [ "$(ask "  Also remove its runner from this machine? (y/n) ")" = "y" ]; then remove_runner "$k" forget; fi
        done
        ;;
      0) return ;;
      *) warn "Invalid option." ;;
    esac
  done
}

# =====================================================================
#  Settings
# =====================================================================
settings_menu() {
  local new p
  while true; do
    say ""
    info "----- Settings -----"
    say "  1) Default folder for new runners : $(runners_root)"
    say "  2) Runner download location       : $(archive_path)"
    say "  3) Runner name prefix             : $(runner_prefix)   (e.g. $(runner_prefix)myrepo)"
    say "  0) Back"
    case "$(ask "Choose an option: ")" in
      1)
        new=$(read_folder "New default folder for runners" "$(runners_root)") || continue
        mkdir -p "$new" && set_setting ROOT "$new"
        reset_cache
        ok "Saved. New runners will go in $new"
        info "Existing runners stay where they are. Use 'Move a runner' to move one."
        ;;
      2)
        new=$(read_folder "Folder to keep the runner download in" "$(dirname "$(archive_path)")") || continue
        mkdir -p "$new"
        p="$new/actions-runner-$PLATFORM.tar.gz"
        if [ -f "$(archive_path)" ] && [ ! -f "$p" ]; then mv "$(archive_path)" "$p"; fi
        set_setting ARCHIVE "$p"
        ok "Saved. Runner download location: $p"
        ;;
      3)
        p=$(ask "New prefix (letters, numbers, - or _) [Enter = $(runner_prefix)]: ")
        [ -z "$p" ] && continue
        case "$p" in *[!A-Za-z0-9_-]*) fail "Use only letters, numbers, - or _." ;;
          *) set_setting PREFIX "$p"; ok "Saved. New runners will be named like ${p}myrepo. Existing runners keep their names." ;;
        esac
        ;;
      0) return ;;
      *) warn "Invalid option." ;;
    esac
  done
}

# =====================================================================
#  Command-line mode
# =====================================================================
show_usage() {
  cat <<'EOF'
Usage (as your normal user, not sudo):
  ./runner-manager.sh                          Open the menu
  ./runner-manager.sh --status                 Show all runners
  ./runner-manager.sh --start <name|all>       Start runner(s)
  ./runner-manager.sh --stop <name|all>        Stop runner(s)
  ./runner-manager.sh --restart <name|all>     Restart runner(s)
  ./runner-manager.sh --add <name> [--folder PATH]
  ./runner-manager.sh --remove <name> --yes
  ./runner-manager.sh --log <name>             Show the latest log
  ./runner-manager.sh --clean <name|all>       Clean work folders
  ./runner-manager.sh --cleanup                Full cleanup (work folders, old logs, stale runners, leftovers)
  ./runner-manager.sh --health                 Run the health check
  Add --account <login> to use a different signed-in GitHub account for that run.

  <name> is a repo name (owned by the active account), owner/repo, or org:<name>.
EOF
}

DO_STATUS=0; DO_START=""; DO_STOP=""; DO_RESTART=""; DO_ADD=""; DO_REMOVE=""; DO_LOG=""
DO_CLEAN=""; DO_CLEANUP=0; DO_HEALTH=0; OPT_FOLDER=""; OPT_YES=0
ARG_COUNT=$#

while [ $# -gt 0 ]; do
  case "$1" in
    --status)  DO_STATUS=1 ;;
    --start)   DO_START="$2"; shift ;;
    --stop)    DO_STOP="$2"; shift ;;
    --restart) DO_RESTART="$2"; shift ;;
    --add)     DO_ADD="$2"; shift ;;
    --remove)  DO_REMOVE="$2"; shift ;;
    --log)     DO_LOG="$2"; shift ;;
    --clean)   DO_CLEAN="$2"; shift ;;
    --cleanup) DO_CLEANUP=1 ;;
    --health)  DO_HEALTH=1 ;;
    --folder)  OPT_FOLDER="$2"; shift ;;
    --account) ACCOUNT_OVERRIDE="$2"; shift ;;
    --yes|-y)  OPT_YES=1 ;;
    -h|--help) show_usage; exit 0 ;;
    *) fail "Unknown option: $1"; show_usage; exit 1 ;;
  esac
  shift
done

# =====================================================================
#  Start
# =====================================================================
[ "$ARG_COUNT" -gt 0 ] && QUIET=1
cfg_init
check_prerequisites || { [ "$QUIET" = "0" ] && ask "Press Enter to exit " >/dev/null; exit 1; }
init_account        || { [ "$QUIET" = "0" ] && ask "Press Enter to exit " >/dev/null; exit 1; }
refresh_machine

if [ "$QUIET" = "1" ]; then
  did=0
  [ "$DO_STATUS" = "1" ] && { show_status; did=1; }
  if [ -n "$DO_START" ];   then for k in $(resolve_targets "$DO_START");   do start_runner "$k";   done; did=1; fi
  if [ -n "$DO_STOP" ];    then for k in $(resolve_targets "$DO_STOP");    do stop_runner "$k";    done; did=1; fi
  if [ -n "$DO_RESTART" ]; then for k in $(resolve_targets "$DO_RESTART"); do restart_runner "$k"; done; did=1; fi
  if [ -n "$DO_ADD" ]; then
    k=$(full_key "$DO_ADD")
    if [ -n "$OPT_FOLDER" ]; then target=$(clean_path "$OPT_FOLDER"); else target=$(default_dir "$k"); fi
    is_installed "$k" || cfg_put ACCOUNT "$k" "$(active_account)"
    check_folder "$target" && install_runner "$k" "$target"
    did=1
  fi
  if [ -n "$DO_REMOVE" ]; then
    k=$(full_key "$DO_REMOVE")
    if [ "$OPT_YES" = "1" ]; then remove_runner "$k" forget; else fail "Add --yes to confirm removing $(display_name "$k")."; fi
    did=1
  fi
  [ -n "$DO_LOG" ] && { show_log "$(full_key "$DO_LOG")"; did=1; }
  if [ -n "$DO_CLEAN" ]; then for k in $(resolve_targets "$DO_CLEAN"); do clean_work "$k" 0; done; did=1; fi
  [ "$DO_CLEANUP" = "1" ] && { full_cleanup; did=1; }
  [ "$DO_HEALTH" = "1" ]  && { health_check; did=1; }
  [ "$did" = "0" ] && show_usage
  exit 0
fi

# =====================================================================
#  Menu
# =====================================================================
while true; do
  if [ -z "$(active_account)" ] || [ -z "$(account_token "$(active_account)")" ]; then
    set_setting ACTIVE ""
    init_account || exit 1
  fi
  refresh_machine

  say ""
  info "===== GitHub Runner Manager ($PLATFORM) ====="
  ok   " Account: $(active_account)"
  say  " Runners"
  say  "   1) Show status"
  say  "   2) Add runner(s) (pick repos, type a repo, or an organization)"
  say  "   3) Remove a runner"
  say  "   4) Start a runner"
  say  "   5) Stop a runner"
  say  "   6) Restart all runners"
  say  "   7) Move a runner to another folder"
  say  "   8) Change a runner's labels"
  say  " Maintenance"
  say  "   9) View a runner's log"
  say  "  10) Cleanup (work folders, old logs, stale runners, leftovers)"
  say  "  11) Health check"
  say  " Setup"
  say  "  12) Fresh start (remove and set up again everything in your list)"
  say  "  13) Manage your list"
  say  "  14) Settings (folders, runner download, runner names)"
  say  "   A) Accounts (switch, sign in, sign out)"
  say  "   0) Exit"
  choice=$(ask "Choose an option: ")

  case "$(lower "$choice")" in
    1)  show_status ;;
    2)  add_runners ;;
    3)  r=$(select_runner "Which runner do you want to REMOVE?") &&
          [ "$(ask "Remove $(display_name "$r")? (y/n) ")" = "y" ] && remove_runner "$r" forget ;;
    4)  for r in $(select_runner "Which runner do you want to start?" all); do start_runner "$r"; done ;;
    5)  for r in $(select_runner "Which runner do you want to stop?" all); do stop_runner "$r"; done ;;
    6)  restart_all ;;
    7)  move_runner ;;
    8)  r=$(select_runner "Change labels for which runner?") && set_labels "$r" ;;
    9)  r=$(select_runner "View the log for which runner?") && show_log "$r" ;;
    10) cleanup_menu ;;
    11) health_check ;;
    12) fresh_start ;;
    13) edit_list ;;
    14) settings_menu ;;
    a)  show_accounts ;;
    0)  exit 0 ;;
    *)  warn "Invalid option." ;;
  esac
done
