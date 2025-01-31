#!/bin/bash

if [ ! -e /etc/sysconfig/openhpc-test.config ]; then
	echo "Local configuration file missing"
	echo "Please create /etc/sysconfig/openhpc-test.config"
	exit 1
fi

# shellcheck disable=SC1091
. /etc/sysconfig/openhpc-test.config

if [ $# -ne 2 ]; then
	echo "Exactly two parameter required: ${0} <TARGET> <OS>"
	exit 1
fi

TARGET=$1
OS=$2

if [[ "${TARGET}" == "unknown" ]]; then
	echo
	echo "Aborting with SMS=${TARGET}"
	echo
	exit 1
fi

BMC="m${TARGET}"

echo
echo "-----------------------------------------------------------"
echo "LAUNCH SMS"
echo "--> SMS = ${TARGET}"
echo "--> OS  = ${OS}"
echo "--> BMC = ${BMC}"

# sleep to allow for potential finish of upstream Cleanup job
HOLD="${SMS_REBOOT_WAIT:-5}"
echo "--> Sleeping for ${HOLD} seconds..."
for i in $(seq "${HOLD}" -1 1); do
	echo "----> ${i}"
	sleep 1;
done

echo "--> Installing ${OS} on ${TARGET}"
cd ansible || exit
ansible-playbook --extra-vars "distro=${OS}" -i inventory/test roles/test/test-oe-repo.yml
cd ..
ssh "${BOOT_SERVER}" systemctl start dhcpd
echo -n "----> Switching boot device to PXE: "
export IPMI_PASSWORD=${SMS_IPMI_PASSWORD}
/usr/bin/ipmitool -C 3 -E -I lanplus -H "${BMC}" -U root chassis bootdev pxe
echo -n "----> Rebooting ${TARGET}: "
/usr/bin/ipmitool -C 3 -E -I lanplus -H "${BMC}" -U root chassis power reset
echo "----> done"

echo "--> Waiting for ${TARGET} to finish installation"
# This can take up to 15 minutes
for i in $(seq 90 -1 1); do
	echo "----> ${i}"
	nc -v -w 1 "${TARGET}" 22 < /dev/null >& /dev/null
	IGOT=$?

	if [ "${IGOT}" -eq 0 ];then
		echo "----> ${TARGET} is up"
		break
	fi
	sleep 10
done

# abort on timeout
if [ "${IGOT}" -ne 0 ];then
	echo "Reboot of ${TARGET} failed"
	exit 1
fi

echo
echo "Host ${TARGET} is up. Launching Jenkins Swarm client" | logger -s

# Handling new SSH host keys
ssh-keygen -R "${TARGET}"
ssh -o StrictHostKeyChecking=accept-new "${TARGET}" hostname

# swarm client jar and jar cache
# jar cache is especially important as it reduces
# the swarm client startup by up to 30 minutes
rsync -av /var/cache/jenkins-agent "${TARGET}":/var/cache/

# shellcheck disable=SC2029
ssh "${TARGET}" "echo SWARM_USER=$SWARM_USER > /etc/sysconfig/swarm-agent"
# shellcheck disable=SC2029
ssh "${TARGET}" "echo SWARM_PASSWORD=$SWARM_PASSWORD >> /etc/sysconfig/swarm-agent"

# The boot server only has dhcpd enabled during SMS installation
ssh "${BOOT_SERVER}" systemctl stop dhcpd

cd ansible || exit
ansible-playbook --extra-vars "distro=${OS}" -i inventory/test roles/test/test-oe-sms.yml
cd ..

# for openEuler we need to use CPAN. This speeds up the
# CPAN module installation.
rsync -av /root/.cpan-backup/ "${TARGET}":/root/.cpan/

# sync time
ssh "${TARGET}" date
ssh "${TARGET}" "chronyc -m 'burst 3/3' 'makestep 0.1 3'"
ssh "${TARGET}" /sbin/hwclock --systohc
ssh "${TARGET}" date
