qemu-img create -f raw usb.img 200M
mkfs.fat -n 'BOOT ZIG' -s 2 -f 2 -R 32 -F 32 usb.img
mkdir -p mnt
mount -o loop usb.img mnt
mkdir -p mnt/efi/boot
cp fs/kernel.elf mnt/kernel.elf
cp fs/efi/boot/bootx64.efi mnt/efi/boot/bootx64.efi
umount mnt
