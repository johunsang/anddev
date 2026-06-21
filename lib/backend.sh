#!/usr/bin/env bash
# =============================================================================
# anddev — 실행 백엔드 추상화 (proot ↔ chroot)
#
#   setup.sh / start.sh 가 공통으로 source 한다.
#   - 루트(su) 가 있으면 chroot  : 더 빠르고 커널기능(Docker 등) 가능
#   - 없으면 proot               : 루팅 불필요 (기본)
#   두 백엔드 모두 같은 Ubuntu 루트파일시스템을 공유한다.
#
#   강제 proot:  ANDDEV_FORCE_PROOT=1
# =============================================================================

DISTRO="${DISTRO:-ubuntu}"
ROOTFS="${PREFIX}/var/lib/proot-distro/installed-rootfs/${DISTRO}"

# --- D1: 루트 사용 가능 여부 (계약적 사고 — su 가 실제로 uid 0 을 주는지 검증) -
anddev_is_rooted() {
  [ "${ANDDEV_FORCE_PROOT:-0}" = "1" ] && return 1
  command -v su >/dev/null 2>&1 || return 1
  # su -c 'id -u' 가 진짜 0 을 돌려줄 때만 신뢰
  [ "$(su -c 'id -u' 2>/dev/null | tr -dc '0-9' | head -c1)" = "0" ] 2>/dev/null
}

anddev_backend() { anddev_is_rooted && echo "chroot" || echo "proot"; }

# --- chroot 준비: 가상 파일시스템 바인드 마운트 (멱등) ----------------------
chroot_prepare() {
  su -c "
    set -e
    mkdir -p '$ROOTFS/proc' '$ROOTFS/sys' '$ROOTFS/dev' '$ROOTFS/dev/pts'
    mountpoint -q '$ROOTFS/proc'    || mount -t proc  proc  '$ROOTFS/proc'
    mountpoint -q '$ROOTFS/sys'     || mount -t sysfs sys   '$ROOTFS/sys'
    mountpoint -q '$ROOTFS/dev'     || mount -o bind  /dev  '$ROOTFS/dev'
    mountpoint -q '$ROOTFS/dev/pts' || mount -o bind  /dev/pts '$ROOTFS/dev/pts'
    cp /etc/resolv.conf '$ROOTFS/etc/resolv.conf' 2>/dev/null || true
  "
}

# --- chroot 정리: 마운트 해제 (종료 시) ------------------------------------
chroot_teardown() {
  su -c "
    umount '$ROOTFS/dev/pts' 2>/dev/null || true
    umount '$ROOTFS/dev'     2>/dev/null || true
    umount '$ROOTFS/sys'     2>/dev/null || true
    umount '$ROOTFS/proc'    2>/dev/null || true
  " 2>/dev/null || true
}

# --- distro 안에서 명령 실행 (포그라운드) ----------------------------------
#   인자: bash -lc 로 넘길 명령 문자열 1개
distro_exec() {
  local cmd="$1"
  if anddev_is_rooted; then
    chroot_prepare
    su -c "chroot '$ROOTFS' /usr/bin/env -i \
      HOME=/root TERM=\${TERM:-xterm} \
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      /bin/bash -lc \"$cmd\""
  else
    proot-distro login "$DISTRO" -- /bin/bash -lc "$cmd"
  fi
}

# --- sshd 데몬 기동 (백그라운드, PID 를 전역 SSHD_PID 에) -------------------
distro_start_sshd() {
  if anddev_is_rooted; then
    chroot_prepare
    su -c "chroot '$ROOTFS' /usr/sbin/sshd -D" &
  else
    proot-distro login "$DISTRO" -- /usr/sbin/sshd -D &
  fi
  SSHD_PID=$!
}
