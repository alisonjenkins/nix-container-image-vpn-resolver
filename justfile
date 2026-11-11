# Build the image and load it into podman
build:
    nix build -o container '.#packages.x86_64-linux.container'
    podman load < container

# Run the namespace leak test (needs root). WG_USERSPACE=0 uses the kernel module.
test userspace="1":
    nix build -o netns-test '.#packages.x86_64-linux.netns-test'
    sudo env WG_USERSPACE={{userspace}} ./netns-test/bin/netns-test

# Inspect the image
dive:
    dive podman://localhost/vpn-resolver:latest

alias b := build
alias t := test
alias d := dive
