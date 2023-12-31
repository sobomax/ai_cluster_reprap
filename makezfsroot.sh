#!/bin/sh

set -e

. /etc/os-release

APT_ENV="env DEBIAN_FRONTEND=noninteractive"
APT_CMD="${APT_ENV} apt"
APT_GET_CMD="${APT_ENV} apt-get"
APT_UPDATE="${APT_CMD} update -y"
APT_UPGRADE="${APT_CMD} upgrade -y"
APT_INSTALL="${APT_GET_CMD} install -y"

${APT_UPDATE}
${APT_INSTALL} apt-cacher-ng

systemctl enable apt-cacher-ng
systemctl start apt-cacher-ng
if ! grep -q "^PassThroughPattern:" /etc/apt-cacher-ng/acng.conf
then
  echo "PassThroughPattern: .*" >> /etc/apt-cacher-ng/acng.conf
  echo "AllowUserPorts: 80 443" >> /etc/apt-cacher-ng/acng.conf
  echo "PfilePatternEx: .*" >> /etc/apt-cacher-ng/acng.conf
  systemctl restart apt-cacher-ng
fi
HTTP_PROXY_ENV="env http_proxy=http://localhost:3142/"
APT_UPDATE="${HTTP_PROXY_ENV} ${APT_UPDATE}"
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
CACHE_FS="zroot/ai_build_cache"
CACHE_FS_USER="${CACHE_FS}/user"
CACHE_FS_SYS="${CACHE_FS}/sys"
CACHE_FS_APT="${CACHE_FS}/apt"

IMG_HOSTNAME="ai-trainer-X."
CHR_DIR="/mnt"
DEFAULT_CP="UTF-8"
DEFAULT_LC="en_US"
DEFAULT_LANG="${DEFAULT_LC}.${DEFAULT_CP}"
DEFAULT_AUSER="sobomax"
DEFAULT_APSWD="123qwe"

zfs_exists() {
  zfs get -H available "${1}" >/dev/null 2>/dev/null
  return "${?}"
}

if mountpoint "${CHR_DIR}" >/dev/null
then
  umount -R "${CHR_DIR}"
fi

for fs in "${ROOT_FS}" "${HOME_FS}"
do
  if ! zfs_exists "${fs}"
  then
    continue
  fi
  zfs destroy -f -r "${fs}"
done

if ! zfs_exists "${CACHE_FS}"
then
  zfs create -o mountpoint=none "${CACHE_FS}"
  for fs in "${CACHE_FS_USER}" "${CACHE_FS_SYS}" "${CACHE_FS_APT}"
  do
    zfs create -o mountpoint=legacy "${fs}"
  done
fi

zfs create -o mountpoint=none "${ROOT_FS}"
zfs create -o mountpoint="${CHR_DIR}" "${ROOT_FS}/${ID}"
zfs create -o mountpoint="${CHR_DIR}/home" "${HOME_FS}"

udevadm trigger

${HTTP_PROXY_ENV} debootstrap "${VERSION_CODENAME}" "${CHR_DIR}"

cp /etc/resolv.conf "${CHR_DIR}/etc"

mount -t proc proc "${CHR_DIR}/proc"
mount -t sysfs sys "${CHR_DIR}/sys"
mount -B /dev "${CHR_DIR}/dev"
mount -B /dev/shm "${CHR_DIR}/dev/shm"
mount -t devpts pts "${CHR_DIR}/dev/pts"
mount -t zfs "${CACHE_FS_SYS}" "${CHR_DIR}/var/cache"
mount -t zfs "${CACHE_FS_APT}" "${CHR_DIR}/var/lib/apt/lists"

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
echo "127.0.1.1\t${IMG_HOSTNAME}" >> /etc/hosts
${APT_UPDATE}
${APT_UPGRADE}
${APT_INSTALL} --no-install-recommends linux-generic locales

localedef -f ${DEFAULT_CP} -i ${DEFAULT_LC} ${DEFAULT_LANG}
perl -pi -e "s|^.*${DEFAULT_LANG} |${DEFAULT_LANG} |"  /etc/locale.gen
locale-gen
update-locale LANG=${DEFAULT_LANG}

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

${APT_INSTALL} sudo git libgl1 strace

adduser --disabled-password --gecos "" "${DEFAULT_AUSER}"
echo "${DEFAULT_AUSER}:${DEFAULT_APSWD}" | chpasswd
usermod -aG render "${DEFAULT_AUSER}"

echo "${DEFAULT_AUSER}    ALL=(ALL:ALL) ALL" > /etc/sudoers.d/default_auser
chmod 600 /etc/sudoers.d/default_auser

${APT_INSTALL} intel-gpu-tools libgomp1 clinfo wget gpg
wget -qO - https://repositories.intel.com/gpu/intel-graphics.key | \
 gpg --dearmor --output /usr/share/keyrings/intel-graphics.gpg
echo "deb [arch=amd64,i386 signed-by=/usr/share/keyrings/intel-graphics.gpg] http://repositories.intel.com/gpu/ubuntu jammy client" | \
 tee /etc/apt/sources.list.d/intel-gpu-jammy.list
wget -O- https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB | \
 gpg --dearmor --output /usr/share/keyrings/oneapi-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/oneapi-archive-keyring.gpg] https://apt.repos.intel.com/oneapi all main" | \
 tee /etc/apt/sources.list.d/oneAPI.list
${APT_UPDATE}

${APT_INSTALL} ocl-icd-libopencl1 intel-opencl-icd intel-level-zero-gpu level-zero
${APT_INSTALL} intel-oneapi-runtime-libs intel-oneapi-compiler-dpcpp-cpp
__EOF__

chmod 755 "${CHR_DIR}/tmp/provision.sh"
chroot "${CHR_DIR}" "/tmp/provision.sh"
rm "${CHR_DIR}/tmp/provision.sh"

CONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
CONDA_MAINENV="SpeechT5"

CACHE_DIR="/home/${DEFAULT_AUSER}/.cache"
CHR_CACHE_DIR="${CHR_DIR}/${CACHE_DIR}"
mkdir "${CHR_CACHE_DIR}"
chroot "${CHR_DIR}" chown "${DEFAULT_AUSER}" "${CACHE_DIR}"
mount -t zfs "${CACHE_FS_USER}" "${CHR_CACHE_DIR}"
chroot "${CHR_DIR}" chown "${DEFAULT_AUSER}" "${CACHE_DIR}"

cat << __EOF__ > "${CHR_DIR}/tmp/provision_user.sh"
#!/bin/sh

set -e
set -x

mkdir -p ~/miniconda3

${HTTP_PROXY_ENV} wget http://HTTPS///repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O ~/miniconda3/miniconda.sh
bash ~/miniconda3/miniconda.sh -b -u -p ~/miniconda3
rm ~/miniconda3/miniconda.sh

if [ ! -e ~/.cache/conda/pkgs ]
then
  mkdir -p ~/.cache/conda/pkgs
fi
mv ~/miniconda3/pkgs/*.conda ~/.cache/conda/pkgs
rm -r ~/miniconda3/pkgs
ln -sf ~/.cache/conda/pkgs ~/miniconda3/pkgs

~/miniconda3/bin/conda init bash
. ~/miniconda3/etc/profile.d/conda.sh

conda update -y conda
conda create -y --name "${CONDA_MAINENV}" python=3.10
conda activate "${CONDA_MAINENV}"
conda install -y pip
python -m pip install torch==2.0.1a0 torchvision==0.15.2a0 intel_extension_for_pytorch==2.0.110+xpu -f https://developer.intel.com/ipex-whl-stable-xpu

python -c 'import intel_extension_for_pytorch as ipex;import torch;t=torch.tensor([1, 2, 3, 4, 5]).to("xpu");t=t*t;print(t)'
__EOF__

chmod 755 "${CHR_DIR}/tmp/provision_user.sh"
chroot "${CHR_DIR}" su -l "${DEFAULT_AUSER}" -c "/tmp/provision_user.sh"
