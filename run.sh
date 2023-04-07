docker build -t bootloader_zig .devcontainer
docker run \
  --rm \
  -it \
  -v $(PWD):/workspaces/bootloader_zig \
  bootloader_zig