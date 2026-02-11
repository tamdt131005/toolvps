{ pkgs, ... }:

{
  # Danh sách package cài sẵn
  packages = with pkgs; [
    # QEMU đầy đủ (có qemu-system-x86_64)
    qemu_full

    wget
    curl

    # Tunnel (bore thay ngrok)
    bore-cli
  ];

  idx.workspace.onStart = {
    run-vm = ''
      # Copy run.sh vào workspace và chạy
      cp /home/user/windows-idx-maintest/run.sh /tmp/run.sh
      chmod +x /tmp/run.sh
      bash /tmp/run.sh
    '';
  };

  # Biến môi trường
  env = {
    QEMU_AUDIO_DRV = "none";
  };
}
