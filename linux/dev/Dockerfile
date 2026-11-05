# Arch Linux with Quickshell and a headless Wayland session, for linux/dev/headless.sh.
FROM archlinux:latest
RUN pacman -Syu --noconfirm --needed quickshell qt6-wayland qt6-svg qt6-declarative sway grim jq inotify-tools \
      ttf-jetbrains-mono-nerd noto-fonts libsecret gnome-keyring python bash git which procps-ng wtype \
    && pacman -Scc --noconfirm
# sway carries cap_sys_nice, which a container may not grant; it runs fine without it.
RUN setcap -r /usr/bin/sway || true
RUN useradd -m -u 1000 dev
USER dev
WORKDIR /home/dev
