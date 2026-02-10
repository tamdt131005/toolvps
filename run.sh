#!/usr/bin/env bash
set -e

### CONFIG ###
ISO_URL="https://go.microsoft.com/fwlink/p/?LinkID=2195443"
ISO_FILE="win11-gamer.iso"

DISK_FILE="/var/win11.qcow2"
DISK_SIZE="64G"

RAM="8G"
CORES="4"

VNC_DISPLAY=":0"
RDP_PORT="3389"

FLAG_FILE="installed.flag"
WORKDIR="$HOME/windows-idx"

### BORE ###
BORE_DIR="$HOME/.bore"
BORE_BIN="$BORE_DIR/bore"
BORE_VNC_LOG="$BORE_DIR/bore_vnc.log"
BORE_RDP_LOG="$BORE_DIR/bore_rdp.log"
BORE_SERVER="bore.pub"

### CHECK ###
[ -e /dev/kvm ] || { echo "❌ No /dev/kvm"; exit 1; }
command -v qemu-system-x86_64 >/dev/null || { echo "❌ No qemu"; exit 1; }

### PREP ###
mkdir -p "$WORKDIR"
cd "$WORKDIR"

[ -f "$DISK_FILE" ] || qemu-img create -f qcow2 "$DISK_FILE" "$DISK_SIZE"

if [ ! -f "$FLAG_FILE" ]; then
  [ -f "$ISO_FILE" ] || wget --no-check-certificate \
    -O "$ISO_FILE" "$ISO_URL"
fi


############################
# BACKGROUND FILE CREATOR #
############################
(
  while true; do
    echo "Lộc Nguyễn đẹp troai" > locnguyen.txt
    echo "[$(date '+%H:%M:%S')] Đã tạo locnguyen.txt"
    sleep 300
  done
) &
FILE_PID=$!

################
# BORE START  #
################
mkdir -p "$BORE_DIR"

# Cài bore nếu chưa có
if [ ! -f "$BORE_BIN" ]; then
  echo "⏳ Đang tải bore..."
  BORE_VERSION="0.5.2"
  curl -sL "https://github.com/ekzhang/bore/releases/download/v${BORE_VERSION}/bore-v${BORE_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
    | tar -xz -C "$BORE_DIR"
  chmod +x "$BORE_BIN"
  echo "✅ Đã cài bore"
fi

# Dọn process bore cũ nếu có
pkill -f "$BORE_BIN" 2>/dev/null || true
sleep 1

# Khởi chạy bore tunnel cho VNC (port 5900)
"$BORE_BIN" local 5900 --to "$BORE_SERVER" > "$BORE_VNC_LOG" 2>&1 &
BORE_VNC_PID=$!

# Khởi chạy bore tunnel cho RDP (port 3389)
"$BORE_BIN" local 3389 --to "$BORE_SERVER" > "$BORE_RDP_LOG" 2>&1 &
BORE_RDP_PID=$!

# Đợi bore tạo tunnel (tối đa 30 giây)
echo "⏳ Đang chờ bore tạo tunnel..."
VNC_ADDR=""
RDP_ADDR=""
for i in $(seq 1 30); do
  # bore output: "listening at bore.pub:XXXXX"
  if [ -z "$VNC_ADDR" ]; then
    VNC_ADDR=$(grep -oP 'bore\.pub:\d+' "$BORE_VNC_LOG" 2>/dev/null | head -1)
  fi
  if [ -z "$RDP_ADDR" ]; then
    RDP_ADDR=$(grep -oP 'bore\.pub:\d+' "$BORE_RDP_LOG" 2>/dev/null | head -1)
  fi
  # Nếu cả 2 đều có thì thoát loop
  if [ -n "$VNC_ADDR" ] && [ -n "$RDP_ADDR" ]; then
    break
  fi
  sleep 1
done

# Kiểm tra nếu bore fail
if [ -z "$VNC_ADDR" ] && [ -z "$RDP_ADDR" ]; then
  echo "❌ Bore không tạo được tunnel sau 30 giây!"
  echo "📋 Log VNC:"
  cat "$BORE_VNC_LOG" 2>/dev/null
  echo "📋 Log RDP:"
  cat "$BORE_RDP_LOG" 2>/dev/null
  exit 1
fi

echo ""
echo "========================================="
echo "🌍 VNC PUBLIC : ${VNC_ADDR:-❌ Không lấy được}"
echo "🌍 RDP PUBLIC : ${RDP_ADDR:-❌ Không lấy được}"
echo "========================================="
echo ""

#################
# RUN QEMU     #
#################
if [ ! -f "$FLAG_FILE" ]; then
  echo "⚠️  CHẾ ĐỘ CÀI ĐẶT WINDOWS"
  echo "👉 Cài xong quay lại nhập: xong"

  qemu-system-x86_64 \
    -enable-kvm \
    -cpu host \
    -smp "$CORES" \
    -m "$RAM" \
    -machine q35 \
    -device ahci,id=ahci0 \
    -drive file="$DISK_FILE",id=disk0,format=qcow2,if=none \
    -device ide-hd,drive=disk0,bus=ahci0.0 \
    -cdrom "$ISO_FILE" \
    -boot order=d \
    -netdev user,id=net0,hostfwd=tcp::3389-:3389 \
    -device e1000,netdev=net0 \
    -vnc "$VNC_DISPLAY" \
    -usb -device usb-tablet &

  QEMU_PID=$!

  while true; do
    read -rp "👉 Nhập 'xong': " DONE
    if [ "$DONE" = "xong" ]; then
      touch "$FLAG_FILE"
      kill "$QEMU_PID"
      kill "$FILE_PID"
      pkill -f "$BORE_BIN"
      rm -f "$ISO_FILE"
      echo "✅ Hoàn tất – lần sau boot thẳng qcow2"
      exit 0
    fi
  done

else
  echo "✅ Windows đã cài – boot thường"

  qemu-system-x86_64 \
    -enable-kvm \
    -cpu host \
    -smp "$CORES" \
    -m "$RAM" \
    -machine q35 \
    -device ahci,id=ahci0 \
    -drive file="$DISK_FILE",id=disk0,format=qcow2,if=none \
    -device ide-hd,drive=disk0,bus=ahci0.0 \
    -boot order=c \
    -netdev user,id=net0,hostfwd=tcp::3389-:3389 \
    -device e1000,netdev=net0 \
    -vnc "$VNC_DISPLAY" \
    -usb -device usb-tablet
fi
