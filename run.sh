#!/usr/bin/env bash
set -e

### CONFIG ###
ISO_URL="https://go.microsoft.com/fwlink/p/?LinkID=2195443"
ISO_FILE="win11-gamer.iso"

DISK_SIZE="50G"

RAM="16G"
CORES="8"

VNC_DISPLAY=":0"
RDP_PORT="3389"

FLAG_FILE="installed.flag"

# Disk VM lưu ở /home/user (có nhiều dung lượng hơn workspace ~10GB)
# Workspace IDX chỉ chứa script, không chứa file lớn
WORKDIR="/home/user/windows-vm"
DISK_FILE="$WORKDIR/win11.qcow2"

### BORE CONFIG ###
# bore được cài qua nix (bore-cli), dùng lệnh 'bore' trực tiếp
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
    # Ghi file keep-alive vào /tmp (không chiếm dung lượng workspace)
    echo "keepalive $(date '+%H:%M:%S')" > /tmp/idx_keepalive.txt
    # Mỗi 60s ghi 1 lần để IDX không nghĩ VM idle
    sleep 60
  done
) &
FILE_PID=$!

#################
# BORE CHECK   #
#################
# bore được cài sẵn qua nix (bore-cli trong dev.nix)
command -v bore >/dev/null || { echo "❌ bore chưa được cài, kiểm tra dev.nix"; exit 1; }

#################
# BORE START   #
#################
# Dừng bore cũ nếu có
pkill -f bore 2>/dev/null || true
sleep 1

# Tunnel VNC (port 5900)
echo "🔌 Đang mở tunnel VNC (port 5900)..."
bore local 5900 --to "$BORE_SERVER" > /tmp/bore_vnc.log 2>&1 &
BORE_VNC_PID=$!

# Tunnel RDP (port 3389)
echo "🔌 Đang mở tunnel RDP (port 3389)..."
bore local 3389 --to "$BORE_SERVER" > /tmp/bore_rdp.log 2>&1 &
BORE_RDP_PID=$!

# Chờ bore khởi động và lấy địa chỉ
sleep 5

VNC_PORT=$(grep -oE 'remote_port=[0-9]+' /tmp/bore_vnc.log | head -1 | cut -d= -f2)
RDP_PORT_PUBLIC=$(grep -oE 'remote_port=[0-9]+' /tmp/bore_rdp.log | head -1 | cut -d= -f2)

if [ -n "$VNC_PORT" ]; then
  echo "🌍 VNC PUBLIC : $BORE_SERVER:$VNC_PORT"
else
  echo "⚠️  VNC tunnel chưa sẵn sàng, kiểm tra /tmp/bore_vnc.log"
  cat /tmp/bore_vnc.log
fi

if [ -n "$RDP_PORT_PUBLIC" ]; then
  echo "🌍 RDP PUBLIC : $BORE_SERVER:$RDP_PORT_PUBLIC"
else
  echo "⚠️  RDP tunnel chưa sẵn sàng, kiểm tra /tmp/bore_rdp.log"
  cat /tmp/bore_rdp.log
fi

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
    -drive file="$DISK_FILE",if=ide,format=qcow2 \
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
      kill "$QEMU_PID" 2>/dev/null || true
      kill "$FILE_PID" 2>/dev/null || true
      kill "$BORE_VNC_PID" 2>/dev/null || true
      kill "$BORE_RDP_PID" 2>/dev/null || true
      pkill -f bore 2>/dev/null || true
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
    -drive file="$DISK_FILE",if=ide,format=qcow2 \
    -boot order=c \
    -netdev user,id=net0,hostfwd=tcp::3389-:3389 \
    -device e1000,netdev=net0 \
    -vnc "$VNC_DISPLAY" \
    -usb -device usb-tablet
fi