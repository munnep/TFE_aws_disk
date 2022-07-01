#!/bin/bash

# TODO: make this in a terraform way
# first is Alvaro
# Second is Patrick
cat >> /home/ubuntu/.ssh/authorized_keys <<EOF
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDBzMaSE9ORQsJoIi+UrMQ+U8WFSpiYFXIKSvqFWbqyhpEM6MSoidX09CuvYIVPMtTeZZj/ZO+o+nL0TffIDNzkGgalhdlw5RL9OgJXgmUNWjW4VwIoR96D7TcP6EUyXkD0wxSgjryJSn4aONR3tIIYvHdM9YjRrivLlS/N7WzIRM6xvWJ8UK7fVYdD3V6FMp4+a33Uc+Ezk8XPWCvDt5vXluFPiKa8RlU7XXqPqI2bR89VJ5cpCnZorVtjVVlvgtOFdY/5hT7qqX1hxQyARkSLcnJiVylL3H3arDlnT/6nO71WY2/ZfyVUbQqcTC12UpFSJRH7JRCgf0stTdfzugCsq61XCMkZBfZ2OTBWeO8Qm2yDW7d4NwzKj31xKqDxT3sr7Gz6qiJO0XhaEjgBSAFB41hVDaNR8Fa6Ir1DObVQ+QsHOv4m2xhh8XxLaZZh30KWZNFAxVmeXoec0paDuj53UTM/ddhbKQr+8vPkbdlR4p5hxSSoVH+SBNLmGY4+K+0= kikitux@kikitux-C02ZR1GLLVDM
EOF

# wait until archive is available. Wait until there is internet before continue
until ping -c1 archive.ubuntu.com &>/dev/null; do
 echo "waiting for networking to initialise"
 sleep 3 
done 

# install monitoring tools
apt-get update
apt-get install -y ctop net-tools sysstat

# Set swappiness
if test -f /sys/kernel/mm/transparent_hugepage/enabled; then
  echo never > /sys/kernel/mm/transparent_hugepage/enabled
fi

if test -f /sys/kernel/mm/transparent_hugepage/defrag; then
  echo never > /sys/kernel/mm/transparent_hugepage/defrag
fi

# heavy swap vm.swappiness=80
# no swap vm.swappiness=1
sysctl vm.swappiness=1
sysctl vm.min_free_kbytes=67584
sysctl vm.drop_caches=1
# make it permanent over server reboots
echo vm.swappiness=80 >> /etc/sysctl.conf
echo vm.min_free_kbytes=67584 >> /etc/sysctl.conf


# we get a list of disk
# DISKS=($(lsblk  -p -I 259 -n -o SIZE | tail +3 | tr -d 'G'))

# if [ $${DISKS[1]} -gt $${DISKS[0]} ]; then
# 	SWAP="/dev/nvme1n1"
# 	DOCKER="/dev/nvme2n1"    
# else
# 	SWAP="/dev/nvme2n1"
# 	DOCKER="/dev/nvme1n1"
# fi

SWAP=/dev/$(lsblk|grep nvme | grep -v nvme0n1 |sort -k 4 | awk '{print $1}'| awk '(NR==1)')
DOCKER=/dev/$(lsblk|grep nvme | grep -v nvme0n1 |sort -k 4 | awk '{print $1}'| awk '(NR==2)')
TFE=/dev/$(lsblk|grep nvme | grep -v nvme0n1 |sort -k 4 | awk '{print $1}'| awk '(NR==3)')

echo $SWAP
echo $DOCKER
echo $TFE

# swap
# if SWAP exists
# we format if no format
if [ -b $SWAP ]; then
	blkid $SWAP
	if [ $? -ne 0 ]; then
		mkswap $SWAP
	fi
fi

# if SWAP not in fstab
# we add it
grep "$SWAP" /etc/fstab
if [ $? -ne 0 ]; then
	echo "$SWAP swap swap defaults 0 0" | tee -a /etc/fstab
	swapon -a
fi

# docker
# if DOCKER exists
# we format if no format
if [ -b $DOCKER ]; then
	blkid $DOCKER
	if [ $? -ne 0 ]; then
		mkfs.xfs $DOCKER
	fi
fi

# if DOCKER not in fstab
# we add it
grep "$DOCKER" /etc/fstab
if [ $? -ne 0 ]; then
	echo "$DOCKER /var/lib/docker xfs defaults 0 0" | tee -a /etc/fstab
	mkdir -p /var/lib/docker
	mount -a
fi

# tfe
# if TFE exists
# we format if no format
if [ -b $TFE ]; then
	blkid $TFE
	if [ $? -ne 0 ]; then
		mkfs.xfs $TFE
	fi
fi

# if TFE not in fstab
# we add it
grep "$TFE" /etc/fstab
if [ $? -ne 0 ]; then
	echo "$TFE /opt/tfe xfs defaults 0 0" | tee -a /etc/fstab
	mkdir -p /opt/tfe
	mount -a
fi

# Netdata will be listening on port 19999
curl -sL https://raw.githubusercontent.com/automodule/bash/main/install_netdata.sh | bash

# install requirements for tfe
# curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
# echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
# apt-get update
# apt-get -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Download all the software and files needed
apt-get -y install awscli
aws s3 cp s3://${tag_prefix}-software/${filename_license} /tmp/${filename_license}
aws s3 cp s3://${tag_prefix}-software/certificate_pem /tmp/certificate_pem
aws s3 cp s3://${tag_prefix}-software/issuer_pem /tmp/issuer_pem
aws s3 cp s3://${tag_prefix}-software/private_key_pem /tmp/private_key_pem

# Create a full chain from the certificates
cat /tmp/certificate_pem >> /tmp/fullchain_pem
cat /tmp/issuer_pem >> /tmp/fullchain_pem

pushd /opt/tfe


# create the configuration file for replicated installation
cat > /tmp/tfe_settings.json <<EOF
{
    "enc_password": {
        "value": "${tfe_password}"
    },
    "hairpin_addressing": {
        "value": "1"
    },
    "hostname": {
        "value": "${dns_hostname}.${dns_zonename}"
    },
    "production_type": {
        "value": "disk"
    },
    "disk_path": {
        "value": "/opt/tfe"
    }
}
EOF


# replicated.conf file
cat > /etc/replicated.conf <<EOF
{
    "DaemonAuthenticationType":          "password",
    "DaemonAuthenticationPassword":      "${tfe_password}",
    "TlsBootstrapType":                  "server-path",
    "TlsBootstrapHostname":              "${dns_hostname}.${dns_zonename}",
    "TlsBootstrapCert":                  "/tmp/fullchain_pem",
    "TlsBootstrapKey":                   "/tmp/private_key_pem",
    "BypassPreflightChecks":             true,
    "ImportSettingsFrom":                "/tmp/tfe_settings.json",
    "LicenseFileLocation":               "/tmp/${filename_license}"
}
EOF

# sudo bash ./install.sh private-address=${tfe-private-ip}

curl -o /var/tmp/install.sh https://install.terraform.io/ptfe/stable

if [ "${tfe_release_sequence}" ] ; then
  bash /var/tmp/install.sh release-sequence=${tfe_release_sequence} no-proxy private-address=${tfe-private-ip} public-address=${tfe-private-ip}
else
  bash /var/tmp/install.sh no-proxy private-address=${tfe-private-ip} public-address=${tfe-private-ip}
fi
