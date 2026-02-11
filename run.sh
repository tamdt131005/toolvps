#!/usr/bin/env bash
set -euo pipefail

### CONFIG ###
ISO_URL="https://go.microsoft.com/fwlink/p/?LinkID=2195167"
ISO_FILE="win11-gamer.iso"

DISK_FILE="/var/win11.qcow2"
DISK_SIZE="64G"

RAM="8G"
CORES="4"

VNC_DISPLAY=":0"
RDP_PORT="3389"

FLAG_FILE="installed.flag"
WORKDIR="$HOME/windows-idx"

### BORE CONFIG ###
BORE_DIR="$HOME/.bore"
BORE_BIN="$BORE_DIR/bore"
BORE_VNC_LOG="$BORE_DIR/bore_vnc.log"
BORE_RDP_LOG="$BORE_DIR/bore_rdp.log"
BORE_SERVER="bore.pub"

### PID TRACKING ###
PIDS=()

# Hàm cleanup - tự dọn tất cả process con khi script tắt
cleanup() {
  echo ""
  echo "🧹 Đang dọn dẹp..."
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null && wait "$pid" 2>/dev/null || true
  done
  # Dọn bore còn sót
  pkill -x bore 2>/dev/null || true
  echo "✅ Đã dọn sạch."
}
trap cleanup EXIT INT TERM

### CHECK ###
[ -e /dev/kvm ] || { echo "❌ Không tìm thấy /dev/kvm - cần bật KVM"; exit 1; }
command -v qemu-system-x86_64 >/dev/null || { echo "❌ Chưa cài qemu-system-x86_64"; exit 1; }

### CHUẨN BỊ ###
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# Tạo disk nếu chưa có
if [ ! -f "$DISK_FILE" ]; then
  echo "📦 Đang tạo disk ảo ${DISK_SIZE}..."
  qemu-img create -f qcow2 "$DISK_FILE" "$DISK_SIZE"
fi

# Tải ISO nếu chưa cài & chưa có ISO
if [ ! -f "$FLAG_FILE" ] && [ ! -f "$ISO_FILE" ]; then
  echo "📥 Đang tải ISO Windows..."
  wget --no-check-certificate -O "$ISO_FILE" "$ISO_URL"
fi

################
# BORE TUNNEL  #
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

# Dọn process bore cũ (dùng -x để match chính xác tên)
pkill -x bore 2>/dev/null || true
sleep 1

# Xóa log cũ
: > "$BORE_VNC_LOG"
: > "$BORE_RDP_LOG"

# Khởi chạy bore tunnel cho VNC (port 5900)
"$BORE_BIN" local 5900 --to "$BORE_SERVER" > "$BORE_VNC_LOG" 2>&1 &
PIDS+=($!)

# Khởi chạy bore tunnel cho RDP (port 3389)
"$BORE_BIN" local 3389 --to "$BORE_SERVER" > "$BORE_RDP_LOG" 2>&1 &
PIDS+=($!)

# Đợi bore tạo tunnel (tối đa 30 giây)
echo "⏳ Đang chờ bore tạo tunnel..."
VNC_ADDR=""
RDP_ADDR=""
for _ in $(seq 1 30); do
  if [ -z "$VNC_ADDR" ]; then
    VNC_ADDR=$(grep -oP 'bore\.pub:\d+' "$BORE_VNC_LOG" 2>/dev/null | head -1) || true
  fi
  if [ -z "$RDP_ADDR" ]; then
    RDP_ADDR=$(grep -oP 'bore\.pub:\d+' "$BORE_RDP_LOG" 2>/dev/null | head -1) || true
  fi
  if [ -n "$VNC_ADDR" ] && [ -n "$RDP_ADDR" ]; then
    break
  fi
  sleep 1
done

# Thông báo kết quả tunnel
echo ""
echo "========================================="
if [ -n "$VNC_ADDR" ]; then
  echo "🌍 VNC PUBLIC : $VNC_ADDR"
else
  echo "❌ VNC TUNNEL : Thất bại"
  echo "   Log: $(cat "$BORE_VNC_LOG" 2>/dev/null || echo 'trống')"
fi
if [ -n "$RDP_ADDR" ]; then
  echo "🌍 RDP PUBLIC : $RDP_ADDR"
else
  echo "❌ RDP TUNNEL : Thất bại"
  echo "   Log: $(cat "$BORE_RDP_LOG" 2>/dev/null || echo 'trống')"
fi
echo "========================================="
echo ""

# Dừng nếu cả 2 tunnel đều fail
if [ -z "$VNC_ADDR" ] && [ -z "$RDP_ADDR" ]; then
  echo "❌ Cả 2 tunnel đều thất bại! Không thể tiếp tục."
  exit 1
fi

#################
# CHẠY QEMU    #
#################

# Đếm số lần retry (tránh loop vô hạn)
RETRY_FILE="$WORKDIR/.boot_retry_count"
MAX_RETRIES=3
BOOT_CHECK_TIME=30  # Nếu QEMU tắt trong 30s = boot lỗi

# Tham số QEMU chung
QEMU_COMMON=(
  -enable-kvm
  -cpu host
  -smp "$CORES"
  -m "$RAM"
  -machine q35
  -device virtio-blk-pci,drive=disk0      # VirtIO nhanh hơn AHCI
  -drive "file=$DISK_FILE,id=disk0,format=qcow2,if=none,cache=writeback"
  -netdev "user,id=net0,hostfwd=tcp::${RDP_PORT}-:3389"
  -device virtio-net-pci,netdev=net0       # VirtIO nhanh hơn E1000
  -vnc "$VNC_DISPLAY"
  -usb -device usb-tablet
)

# Hàm reset về chế độ cài đặt
reset_to_install() {
  local retry_count
  retry_count=$(cat "$RETRY_FILE" 2>/dev/null || echo "0")
  retry_count=$((retry_count + 1))

  if [ "$retry_count" -gt "$MAX_RETRIES" ]; then
    echo "❌ Đã thử $MAX_RETRIES lần mà vẫn lỗi! Dừng lại."
    echo "   Hãy kiểm tra thủ công hoặc xóa $RETRY_FILE để thử lại."
    exit 1
  fi

  echo "$retry_count" > "$RETRY_FILE"
  echo ""
  echo "🔄 Boot lỗi! Đang reset... (lần $retry_count/$MAX_RETRIES)"
  echo "   → Xóa disk hỏng..."
  rm -f "$DISK_FILE"
  echo "   → Xóa flag cài đặt..."
  rm -f "$FLAG_FILE"
  echo "   → Xóa ISO cũ (nếu có)..."
  rm -f "$ISO_FILE"
  echo "   → Tạo disk mới..."
  qemu-img create -f qcow2 "$DISK_FILE" "$DISK_SIZE"
  echo "   → Tải lại ISO Windows..."
  wget --no-check-certificate -O "$ISO_FILE" "$ISO_URL"
  echo "✅ Reset xong! Đang restart script..."
  echo ""

  # Dọn process hiện tại rồi restart script
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  pkill -x bore 2>/dev/null || true

  # Restart chính script này
  exec "$0" "$@"
}

if [ ! -f "$FLAG_FILE" ]; then
  echo "⚠️  CHẾ ĐỘ CÀI ĐẶT WINDOWS"
  echo "👉 Cài xong hãy nhập: xong"
  echo ""

  qemu-system-x86_64 \
    "${QEMU_COMMON[@]}" \
    -cdrom "$ISO_FILE" \
    -boot order=d &
  QEMU_PID=$!
  PIDS+=($QEMU_PID)

  while true; do
    read -rp "👉 Nhập 'xong' khi cài xong: " DONE
    if [ "$DONE" = "xong" ]; then
      touch "$FLAG_FILE"
      rm -f "$ISO_FILE"
      rm -f "$RETRY_FILE"  # Reset retry counter khi cài thành công
      echo "✅ Hoàn tất – lần sau boot thẳng từ disk"
      exit 0
    fi
  done

else
  echo "✅ Windows đã cài – boot thường"
  echo "   Nhấn Ctrl+C để tắt."
  echo ""

  BOOT_START=$(date +%s)

  qemu-system-x86_64 \
    "${QEMU_COMMON[@]}" \
    -boot order=c &
  QEMU_PID=$!
  PIDS+=($QEMU_PID)

  # Đợi QEMU kết thúc
  wait "$QEMU_PID" 2>/dev/null
  QEMU_EXIT=$?
  BOOT_END=$(date +%s)
  BOOT_DURATION=$((BOOT_END - BOOT_START))

  # Kiểm tra: nếu QEMU tắt quá nhanh (< 30s) hoặc exit code lỗi → boot fail
  if [ "$BOOT_DURATION" -lt "$BOOT_CHECK_TIME" ] && [ "$QEMU_EXIT" -ne 0 ]; then
    echo ""
    echo "❌ QEMU tắt sau ${BOOT_DURATION}s với exit code ${QEMU_EXIT}"
    echo "   → Phát hiện boot lỗi!"
    reset_to_install
  elif [ "$BOOT_DURATION" -lt "$BOOT_CHECK_TIME" ] && [ "$QEMU_EXIT" -eq 0 ]; then
    echo ""
    echo "⚠️  QEMU tắt sau ${BOOT_DURATION}s (exit code 0)"
    echo "   Có thể disk trống hoặc Windows bị hỏng."
    echo -n "   Bạn muốn tải lại Windows? (y/N): "
    read -r ANSWER
    if [ "$ANSWER" = "y" ] || [ "$ANSWER" = "Y" ]; then
      reset_to_install
    fi
  else
    # Boot bình thường, xóa retry counter
    rm -f "$RETRY_FILE"
    echo "👋 QEMU đã tắt bình thường."
  fi
fi
