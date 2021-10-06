#!/bin/sh

#
# Copyright (c) 2015 Baptiste Daroussin <bapt@FreeBSD.org>
# All rights reserved.
# Copyright (c) 2021 Emmanuel Vadot <manu@FreeBSD.org>
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.

rawdisk_check()
{

	[ -n "${IMAGESIZE}" ] || err 1 "Please specify the imagesize"
	[ -f "${mnt}/boot/kernel/kernel" ] || \
	    err 1 "The ${MEDIATYPE} media type requires a jail with a kernel"
}

rawdisk_prepare()
{
	truncate -s ${IMAGESIZE} ${WRKDIR}/raw.img
	md=$(/sbin/mdconfig ${WRKDIR}/raw.img)
	newfs -j -L ${IMAGENAME} /dev/${md}
	mount /dev/${md} ${WRKDIR}/world
}

rawdisk_build()
{

	cat >> ${WRKDIR}/world/etc/fstab <<-EOF
	/dev/ufs/${IMAGENAME} / ufs rw 1 1
	EOF
}

rawdisk_generate()
{

	FINALIMAGE=${IMAGENAME}.img
	umount ${WRKDIR}/world
	/sbin/mdconfig -d -u ${md#md}
	md=
	mv ${WRKDIR}/raw.img "${OUTPUTDIR}/${FINALIMAGE}"
}

zrawdisk_check()
{

	[ -n "${IMAGESIZE}" ] || err 1 "Please specify the imagesize"
	[ -f "${mnt}/boot/kernel/kernel" ] || \
	    err 1 "The ${MEDIATYPE} media type requires a jail with a kernel"
}

zrawdisk_prepare()
{

	truncate -s ${IMAGESIZE} ${WRKDIR}/raw.img
	md=$(/sbin/mdconfig ${WRKDIR}/raw.img)
	zroot=${IMAGENAME}root
	gpart create -s GPT ${md}
	# Set up a UEFI boot partition.  3M is the smallest size for a FAT16
	# partition.  Loader is <1M.  We could use boot1.efi (which is <100K) but
	# it just forwards to loader.efi after finding it in the zfs pool and we
	# have more than enough space to just boot loader directly and we don't
	# need multiboot support in a VM image.
	gpart add -t efi -s 3M ${md}
	newfs_msdos -F 16 -c 1 /dev/${md}p1
	mkdir ${WRKDIR}/efi
	mount -t msdosfs /dev/${md}p1 ${WRKDIR}/efi
	mkdir -p ${WRKDIR}/efi/EFI/BOOT
	cp /boot/loader.efi ${WRKDIR}/efi/EFI/BOOT/BOOTX64.efi
	umount ${WRKDIR}/efi
	rmdir ${WRKDIR}/efi
	# Create an MBR boot partition and install the bootcode.
	gpart add -t freebsd-boot -s 545K -l zfs-boot-disk ${md}
	gpart bootcode -b /boot/pmbr -p /boot/gptzfsboot -i 2 ${md}
	# Create the partition to hold the ZFS filesystem.  ZFS boot requires a
	# partition, not a raw disk.
	gpart add -t freebsd-zfs -a 1M -l zfs-boot-disk ${md}
	# Create a pool called zroot, with the temporary name derived from the image.
	zpool create \
		-O mountpoint=none \
		-O compression=lz4 \
		-O atime=off \
		-R ${WRKDIR}/world -t ${zroot} zroot /dev/${md}p3
	zfs create -o mountpoint=none ${zroot}/ROOT
	zfs create -o mountpoint=/ ${zroot}/ROOT/default
	zfs create -o mountpoint=/var ${zroot}/var
	zfs create -o mountpoint=/var/tmp -o setuid=off ${zroot}/var/tmp
	zfs create -o mountpoint=/tmp -o setuid=off ${zroot}/tmp
	zfs create -o mountpoint=/home ${zroot}/home
	chmod 1777 ${WRKDIR}/world/tmp ${WRKDIR}/world/var/tmp
	zfs create -o mountpoint=/var/crash \
		-o exec=off -o setuid=off \
		${zroot}/var/crash
	zfs create -o mountpoint=/var/log \
		-o exec=off -o setuid=off \
		${zroot}/var/log
	zfs create -o mountpoint=/var/run \
		-o exec=off -o setuid=off \
		${zroot}/var/run
	zfs create -o mountpoint=/var/db \
		-o exec=off -o setuid=off \
		${zroot}/var/db
	zfs create -o mountpoint=/var/mail \
		-o exec=off -o setuid=off \
		${zroot}/var/mail
	zfs create -o mountpoint=/var/cache \
		-o compression=off \
		-o exec=off -o setuid=off \
		${zroot}/var/cache
	zfs create -o mountpoint=/var/empty ${zroot}/var/empty
}

zrawdisk_build()
{

	cat >> ${WRKDIR}/world/boot/loader.conf <<-EOF
	zfs_load="YES"
	vfs.root.mountfrom="zfs:zroot/ROOT/default"
	EOF
	cat >> ${WRKDIR}/world/etc/rc.conf <<-EOF
	zfs_enable="YES"
	EOF
}

zrawdisk_generate()
{

	FINALIMAGE=${IMAGENAME}.img
	zfs umount -f ${zroot}/ROOT/default
	zfs set mountpoint=none ${zroot}/ROOT/default
	zfs set readonly=on ${zroot}/var/empty
	zpool set bootfs=${zroot}/ROOT/default ${zroot}
	zpool set autoexpand=on ${zroot}
	zpool list ${zroot}
	zpool export ${zroot}
	zroot=
	/sbin/mdconfig -d -u ${md#md}
	md=
	mv ${WRKDIR}/raw.img "${OUTPUTDIR}/${FINALIMAGE}"
}
