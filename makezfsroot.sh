#!/bin/sh

set -e

. /etc/os-release

APT_CMD="env DEBIAN_FRONTEND=noninteractive apt"
APT_UPDATE="${APT_CMD} update -y"
APT_UPGRADE="${APT_CMD} upgrade -y"
APT_INSTALL="${APT_CMD} install -y"
APT_CLEAN="${APT_CMD} clean"

${APT_UPDATE}
${APT_INSTALL} apt-cacher-ng

systemctl enable apt-cacher-ng
systemctl start apt-cacher-ng
if ! grep -q "^PassThroughPattern:" /etc/apt-cacher-ng/acng.conf
then
  echo "PassThroughPattern: .*" >> /etc/apt-cacher-ng/acng.conf
  systemctl restart apt-cacher-ng
fi
HTTP_PROXY_ENV="env http_proxy=http://localhost:3142/"
APT_INSTALL="${HTTP_PROXY_ENV} ${APT_INSTALL}"
APT_UPGRADE="${HTTP_PROXY_ENV} ${APT_UPGRADE}"
${APT_INSTALL} debootstrap gdisk zfsutils-linux

BOOT_DISK="/dev/nvme0n1"
BOOT_PART="1"
BOOT_DEVICE="${BOOT_DISK}p${BOOT_PART}"

POOL_DISK="/dev/nvme0n1"
POOL_PART="2"
POOL_DEVICE="${POOL_DISK}p${POOL_PART}"

ROOT_FS="zroot/ROOT_x"
HOME_FS="zroot/home_x"

IMG_HOSTNAME="ai-trainer-X."
CHR_DIR="/mnt"

for fs in "${ROOT_FS}" "${HOME_FS}"
do
  if ! zfs get -H available "${fs}" >/dev/null 2>/dev/null
  then
    continue
  fi
  if mountpoint "${CHR_DIR}" >/dev/null
  then
    umount -R "${CHR_DIR}"
  fi
  zfs destroy -f -r "${fs}"
done

zfs create -o mountpoint=none "${ROOT_FS}"
zfs create -o mountpoint="${CHR_DIR}" "${ROOT_FS}/${ID}"
zfs create -o mountpoint="${CHR_DIR}/home" "${HOME_FS}"

udevadm trigger

#cat << __EOF__ > "${CHR_DIR}/tmp/provision.sh"
#zgenhostid
${HTTP_PROXY_ENV} debootstrap "${VERSION_CODENAME}" "${CHR_DIR}"

cp /etc/resolv.conf "${CHR_DIR}/etc"

mount -t proc proc "${CHR_DIR}/proc"
mount -t sysfs sys "${CHR_DIR}/sys"
mount -B /dev "${CHR_DIR}/dev"
mount -t devpts pts "${CHR_DIR}/dev/pts"

zgenhostid -o "${CHR_DIR}/etc/hostid"

cat << __EOF__ > "${CHR_DIR}/etc/apt/sources.list"
# Uncomment the deb-src entries if you need source packages

deb http://archive.ubuntu.com/ubuntu/ lunar main restricted universe multiverse
# deb-src http://archive.ubuntu.com/ubuntu/ lunar main restricted universe multiverse

deb http://archive.ubuntu.com/ubuntu/ lunar-updates main restricted universe multiverse
# deb-src http://archive.ubuntu.com/ubuntu/ lunar-updates main restricted universe multiverse

deb http://archive.ubuntu.com/ubuntu/ lunar-security main restricted universe multiverse
# deb-src http://archive.ubuntu.com/ubuntu/ lunar-security main restricted universe multiverse

deb http://archive.ubuntu.com/ubuntu/ lunar-backports main restricted universe multiverse
# deb-src http://archive.ubuntu.com/ubuntu/ lunar-backports main restricted universe multiverse
__EOF__

cat << __EOF__ > "${CHR_DIR}/tmp/provision.sh"
#!/bin/sh

set -e
set -x

echo "${IMG_HOSTNAME}" > /etc/hostname
echo -e "127.0.1.1\t${IMG_HOSTNAME}" >> /etc/hosts
${APT_UPDATE}
${APT_UPGRADE}
${APT_INSTALL} --no-install-recommends linux-generic locales

localedef -f UTF-8 -i en_US en_US.UTF-8
perl -pi -e 's|^.*en_US.UTF-8 |en_US.UTF-8 |'  /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8

echo "tzdata tzdata/Areas select Etc" | debconf-set-selections
echo "tzdata tzdata/Zones/Etc select UTC" | debconf-set-selections
DEBIAN_FRONTEND=noninteractive dpkg-reconfigure tzdata

${APT_INSTALL} dosfstools zfs-initramfs zfsutils-linux

systemctl enable zfs.target
systemctl enable zfs-import-cache
systemctl enable zfs-mount
systemctl enable zfs-import.target

update-initramfs -c -k all
zfs set org.zfsbootmenu:commandline="quiet loglevel=4" "${ROOT_FS}"

${APT_INSTALL} intel-gpu-tools wget gpg
wget -qO - https://repositories.intel.com/gpu/intel-graphics.key | \
 gpg --dearmor --output /usr/share/keyrings/intel-graphics.gpg
echo "deb [arch=amd64,i386 signed-by=/usr/share/keyrings/intel-graphics.gpg] http://repositories.intel.com/gpu/ubuntu jammy client" | \
 tee /etc/apt/sources.list.d/intel-gpu-jammy.list
wget -O- https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB | \
 gpg --dearmor --output /usr/share/keyrings/oneapi-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/oneapi-archive-keyring.gpg] https://apt.repos.intel.com/oneapi all main" | \
 tee /etc/apt/sources.list.d/oneAPI.list
${APT_UPDATE}
${APT_INSTALL} level-zero intel-oneapi-runtime-libs intel-oneapi-compiler-dpcpp-cpp

${APT_CLEAN}
__EOF__

chmod 755 "${CHR_DIR}/tmp/provision.sh"
chroot "${CHR_DIR}" "/tmp/provision.sh"
