#!/usr/bin/env bash
set -Eeuo pipefail

# HOKADIW Dev Pack
# Ubuntu 24.04 / 26.04 (Desktop or Server)
# Installs: core dev tools, Python, Node.js, Java, Docker, Android/APK tools,
# databases clients, network/debug utilities, VS Code and browsers when GUI exists.

LOG_FILE="/var/log/hokadiw-dev-pack.log"
exec > >(tee -a "$LOG_FILE") 2>&1

if [[ "${EUID}" -ne 0 ]]; then
  echo "กรุณารันด้วย sudo:"
  echo "  sudo bash $0"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

REAL_USER="${SUDO_USER:-root}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
ARCH="$(dpkg --print-architecture)"
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"

echo "=================================================="
echo " HOKADIW DEV PACK"
echo " User      : $REAL_USER"
echo " Ubuntu    : $(. /etc/os-release && echo "$PRETTY_NAME")"
echo " Codename  : $CODENAME"
echo " Arch      : $ARCH"
echo " Log       : $LOG_FILE"
echo "=================================================="

retry() {
  local attempts=3
  local delay=5
  local n=1
  until "$@"; do
    if (( n >= attempts )); then
      echo "[ERROR] คำสั่งล้มเหลวหลังลอง $attempts ครั้ง: $*"
      return 1
    fi
    echo "[WARN] ลองใหม่ครั้งที่ $((n+1))..."
    sleep "$delay"
    ((n++))
  done
}

install_available() {
  local available=()
  local missing=()
  local pkg
  for pkg in "$@"; do
    if apt-cache show "$pkg" >/dev/null 2>&1; then
      available+=("$pkg")
    else
      missing+=("$pkg")
    fi
  done

  if ((${#available[@]})); then
    retry apt-get install -y "${available[@]}"
  fi

  if ((${#missing[@]})); then
    echo "[SKIP] ไม่มีแพ็กเกจใน Ubuntu รุ่นนี้: ${missing[*]}"
  fi
}

echo "[1/10] เตรียมระบบ..."
retry apt-get update
install_available software-properties-common ca-certificates apt-transport-https gnupg lsb-release
add-apt-repository -y universe || true
retry apt-get update

echo "[2/10] เครื่องมือพื้นฐานและ Build..."
install_available \
  git git-lfs curl wget aria2 unzip zip p7zip-full tar xz-utils rsync \
  build-essential gcc g++ make cmake ninja-build pkg-config autoconf automake \
  jq yq tree htop btop tmux screen nano vim neovim ripgrep fd-find fzf \
  shellcheck shfmt direnv dos2unix uuid-runtime parallel

echo "[3/10] ภาษาโปรแกรมและ Runtime..."
install_available \
  python3 python3-pip python3-venv python3-dev pipx \
  nodejs npm \
  openjdk-17-jdk \
  ruby-full golang-go rustc cargo \
  php-cli php-curl php-mbstring php-xml composer

if command -v pipx >/dev/null 2>&1 && [[ "$REAL_USER" != "root" ]]; then
  sudo -u "$REAL_USER" pipx ensurepath || true
fi

echo "[4/10] Network, SSH และ Debug..."
install_available \
  openssh-client openssh-server net-tools iproute2 iputils-ping dnsutils \
  traceroute whois nmap tcpdump tshark socat netcat-openbsd mtr-tiny \
  lsof strace ltrace gdb valgrind iotop iftop sysstat \
  httpie openssl sqlite3

systemctl enable --now ssh 2>/dev/null || true

echo "[5/10] Database clients..."
install_available \
  postgresql-client mariadb-client redis-tools sqlitebrowser

echo "[6/10] Android และ APK Reverse Engineering..."
install_available \
  adb fastboot apktool jadx dex2jar smali baksmali aapt \
  android-sdk-platform-tools-common

# Android SDK command-line tools (official Google package)
ANDROID_SDK_ROOT="/opt/android-sdk"
ANDROID_BUILD_TOOLS_VERSION="35.0.0"
CMDLINE_ZIP="/tmp/android-cmdline-tools.zip"
CMDLINE_URL="https://dl.google.com/android/repository/commandlinetools-linux-15859902_latest.zip"

if [[ "$ARCH" == "amd64" ]]; then
  mkdir -p "$ANDROID_SDK_ROOT/cmdline-tools"
  if curl -fL --retry 3 "$CMDLINE_URL" -o "$CMDLINE_ZIP"; then
    rm -rf /tmp/android-cmdline-extract "$ANDROID_SDK_ROOT/cmdline-tools/latest"
    mkdir -p /tmp/android-cmdline-extract "$ANDROID_SDK_ROOT/cmdline-tools/latest"
    unzip -q "$CMDLINE_ZIP" -d /tmp/android-cmdline-extract
    cp -a /tmp/android-cmdline-extract/cmdline-tools/. \
      "$ANDROID_SDK_ROOT/cmdline-tools/latest/"
    chown -R root:root "$ANDROID_SDK_ROOT"
    chmod -R a+rX "$ANDROID_SDK_ROOT"

    cat >/etc/profile.d/android-sdk.sh <<EOF
export ANDROID_HOME=$ANDROID_SDK_ROOT
export ANDROID_SDK_ROOT=$ANDROID_SDK_ROOT
export PATH=\$PATH:\$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:\$ANDROID_SDK_ROOT/platform-tools:\$ANDROID_SDK_ROOT/build-tools/$ANDROID_BUILD_TOOLS_VERSION
EOF

    export ANDROID_HOME="$ANDROID_SDK_ROOT"
    export ANDROID_SDK_ROOT="$ANDROID_SDK_ROOT"
    export PATH="$PATH:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/build-tools/$ANDROID_BUILD_TOOLS_VERSION"

    yes | sdkmanager --licenses >/dev/null 2>&1 || true
    sdkmanager \
      "platform-tools" \
      "cmdline-tools;latest" \
      "build-tools;$ANDROID_BUILD_TOOLS_VERSION" || true

    if [[ -x "$ANDROID_SDK_ROOT/build-tools/$ANDROID_BUILD_TOOLS_VERSION/aapt2" ]]; then
      ln -sf "$ANDROID_SDK_ROOT/build-tools/$ANDROID_BUILD_TOOLS_VERSION/aapt2" /usr/local/bin/aapt2
    fi
  else
    echo "[WARN] ดาวน์โหลด Android Command-line Tools ไม่สำเร็จ"
  fi
else
  echo "[SKIP] Google Android Command-line Tools รองรับ Linux x86_64 เป็นหลัก; เครื่องนี้คือ $ARCH"
fi

echo "[7/10] Docker Engine และ Compose..."
# ใช้แพ็กเกจ Ubuntu เพื่อรองรับ Ubuntu รุ่นใหม่โดยไม่ผูก codename กับ repo ภายนอก
install_available docker.io docker-compose-v2 docker-buildx

systemctl enable --now docker 2>/dev/null || true
if [[ "$REAL_USER" != "root" ]]; then
  usermod -aG docker "$REAL_USER" || true
fi

echo "[8/10] VS Code และ Browser (เฉพาะเครื่อง amd64)..."
if [[ "$ARCH" == "amd64" ]]; then
  # Microsoft VS Code repository
  # ลบรายการเดิมทั้งหมดเพื่อป้องกัน Signed-By ชนกัน
  rm -f \
    /etc/apt/sources.list.d/vscode.list \
    /etc/apt/sources.list.d/vscode.sources \
    /etc/apt/keyrings/packages.microsoft.gpg

  grep -RIl "packages.microsoft.com/repos/code" \
    /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null |
  while IFS= read -r source_file; do
    sed -i '\|packages.microsoft.com/repos/code|d' "$source_file"
  done

  install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc |
    gpg --dearmor --yes -o /usr/share/keyrings/microsoft.gpg
  chmod 0644 /usr/share/keyrings/microsoft.gpg

  cat >/etc/apt/sources.list.d/vscode.sources <<'EOF'
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64 arm64 armhf
Signed-By: /usr/share/keyrings/microsoft.gpg
EOF

  # Google Chrome repository
  curl -fsSL https://dl.google.com/linux/linux_signing_key.pub |
    gpg --dearmor --yes -o /etc/apt/keyrings/google-chrome.gpg
  chmod a+r /etc/apt/keyrings/google-chrome.gpg
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" \
    >/etc/apt/sources.list.d/google-chrome.list

  retry apt-get update
  install_available code google-chrome-stable firefox
else
  echo "[SKIP] Chrome Stable ไม่มีแพ็กเกจ Linux สำหรับสถาปัตยกรรม $ARCH"
  install_available code firefox
fi

echo "[9/10] ตั้งค่า Git และโฟลเดอร์ทำงาน..."
if [[ "$REAL_USER" != "root" ]]; then
  sudo -u "$REAL_USER" mkdir -p \
    "$REAL_HOME/Projects" \
    "$REAL_HOME/Android" \
    "$REAL_HOME/Tools"

  sudo -u "$REAL_USER" git config --global init.defaultBranch main || true
  sudo -u "$REAL_USER" git config --global core.autocrlf input || true
  sudo -u "$REAL_USER" git config --global pull.rebase false || true
fi

echo "[10/10] ทำความสะอาดและตรวจสอบ..."
apt-get autoremove -y
apt-get clean

echo
echo "================= ผลการติดตั้ง ================="
for cmd in git python3 pip3 node npm java javac docker adb fastboot apktool jadx aapt aapt2 code; do
  if command -v "$cmd" >/dev/null 2>&1; then
    printf "  [OK]   %-12s %s\n" "$cmd" "$(command -v "$cmd")"
  else
    printf "  [MISS] %-12s\n" "$cmd"
  fi
done

echo
echo "เวอร์ชันหลัก:"
git --version 2>/dev/null || true
python3 --version 2>/dev/null || true
node --version 2>/dev/null || true
java -version 2>&1 | head -n 1 || true
docker --version 2>/dev/null || true
docker compose version 2>/dev/null || true
adb version 2>/dev/null | head -n 1 || true
apktool --version 2>/dev/null || true
jadx --version 2>/dev/null || true
aapt2 version 2>/dev/null || true

echo
echo "=================================================="
echo "ติดตั้งเสร็จแล้ว ✅"
echo "Log: $LOG_FILE"
echo
echo "สำคัญ:"
echo "1. ออกจากระบบแล้วเข้าใหม่ หรือ reboot เพื่อให้ Docker group และ PATH ทำงาน"
echo "2. ทดสอบ Docker: docker run --rm hello-world"
echo "3. โหลด Android environment ทันที: source /etc/profile.d/android-sdk.sh"
echo "=================================================="
