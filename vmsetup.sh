#!/bin/bash

#set -x # debug mode
set -e

# =============================================================================================
# global vars

# force english messages
export LANG=C
export LC_ALL=C

# template vm vars
TEMPLATE_VMID="900"
TEMPLATE_VMSTORAGE="local"
SNIPPET_STORAGE="local"
VMDISK_OPTIONS=",discard=on"

TEMPLATE_IGNITION="fcos-base-template.yaml"

# fcos version
STREAMS=stable
VERSION=40.20240519.3.0
PLATEFORM=qemu
BASEURL=https://builds.coreos.fedoraproject.org


# https://builds.coreos.fedoraproject.org/prod/streams/stable/builds/40.20240519.3.0/x86_64/fedora-coreos-40.20240519.3.0-qemu.x86_64.qcow2.xz

# =============================================================================================
# main()

# pve storage exist ?
echo -n "Check if vm storage ${TEMPLATE_VMSTORAGE} exist... "
pvesh get /storage/${TEMPLATE_VMSTORAGE} --noborder --noheader &> /dev/null || {
        echo -e "[failed]"
        exit 1
}
echo "[ok]"

# pve storage snippet ok ?
echo -n "Check if snippet storage ${SNIPPET_STORAGE} exist... "
pvesh get /storage/${SNIPPET_STORAGE} --noborder --noheader &> /dev/null || {
        echo -e "[failed]"
        exit 1
}
echo "[ok]"

# pve storage snippet enable
pvesh get /storage/${SNIPPET_STORAGE} --noborder --noheader | grep -q snippets || {
	echo "You must activate content snippet on storage: ${SNIPPET_STORAGE}"
	exit 1
}

# copy files
echo "Copy hook script and ignition config to snippet storage..."
snippet_storage="$(pvesh get /storage/${SNIPPET_STORAGE} --noborder --noheader | grep ^path | awk '{print $NF}')"
cp -av ${TEMPLATE_IGNITION} hook-fcos.sh ${snippet_storage}/snippets
sed -e "/^COREOS_TMPLT/ c\COREOS_TMPLT=${snippet_storage}/snippets/${TEMPLATE_IGNITION}" -i ${snippet_storage}/snippets/hook-fcos.sh
chmod 755 ${snippet_storage}/snippets/hook-fcos.sh

# storage type ? (https://pve.proxmox.com/wiki/Storage)
echo -n "Get storage \"${TEMPLATE_VMSTORAGE}\" type... "
case "$(pvesh get /storage/${TEMPLATE_VMSTORAGE} --noborder --noheader | grep ^type | awk '{print $2}')" in
        dir|nfs|cifs|glusterfs|cephfs) TEMPLATE_VMSTORAGE_type="file"; echo "[file]"; ;;
        lvm|lvmthin|iscsi|iscsidirect|rbd|zfs|zfspool) TEMPLATE_VMSTORAGE_type="block"; echo "[block]" ;;
        *)
                echo "[unknown]"
                exit 1
        ;;
esac

# download fcos vdisk
[[ ! -e fedora-coreos-${VERSION}-${PLATEFORM}.x86_64.qcow2 ]]&& {
    echo "Downloading Fedora CoreOS..."
    wget -q --show-progress \
        ${BASEURL}/prod/streams/${STREAMS}/builds/${VERSION}/x86_64/fedora-coreos-${VERSION}-${PLATEFORM}.x86_64.qcow2.xz
    xz -dv fedora-coreos-${VERSION}-${PLATEFORM}.x86_64.qcow2.xz
}

# create a new VM
echo "Create Fedora CoreOS vm ${VMID}"
qm create ${TEMPLATE_VMID} --name fcos-template
qm set ${TEMPLATE_VMID} --memory 8192 \
			--cpu host \
			--cores 8 \
			--agent enabled=1 \
			--autostart \
			--onboot 1 \
			--ostype l26 \
			--tablet 0 \
			--boot c --bootdisk scsi0

template_vmcreated=$(date +%Y-%m-%d)
qm set ${TEMPLATE_VMID} --description "Fedora CoreOS Template

 - Version             : ${VERSION}
 - Cloud-init          : true

Creation date : ${template_vmcreated}
"

qm set ${TEMPLATE_VMID} --net0 virtio,bridge=vmbr0
#qm set ${TEMPLATE_VMID} --net1 virtio,bridge=vmbr1

echo -e "\nCreate Cloudinit vmdisk..."
qm set ${TEMPLATE_VMID} --ide2 ${TEMPLATE_VMSTORAGE}:cloudinit

# import fedora disk
if [[ "x${TEMPLATE_VMSTORAGE_type}" = "xfile" ]]
then
	vmdisk_name="${TEMPLATE_VMID}/vm-${TEMPLATE_VMID}-disk-0.qcow2"
	vmdisk_format="--format qcow2"
else
	vmdisk_name="vm-${TEMPLATE_VMID}-disk-0"
        vmdisk_format=""
fi
qm importdisk ${TEMPLATE_VMID} fedora-coreos-${VERSION}-${PLATEFORM}.x86_64.qcow2 ${TEMPLATE_VMSTORAGE} ${vmdisk_format}
qm set ${TEMPLATE_VMID} --scsihw virtio-scsi-pci --scsi0 ${TEMPLATE_VMSTORAGE}:${vmdisk_name}${VMDISK_OPTIONS}

# set hook-script
qm set ${TEMPLATE_VMID} -hookscript ${SNIPPET_STORAGE}:snippets/hook-fcos.sh


# convert vm template
echo -n "Convert VM ${TEMPLATE_VMID} in Proxmox VM template... "
qm template ${TEMPLATE_VMID} &> /dev/null || true
echo "[done]"
