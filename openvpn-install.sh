#!/bin/bash

# Secure OpenVPN server installer for Debian, Ubuntu, CentOS and Arch Linux
# https://github.com/Angristan/OpenVPN-install
# The OpenVPN 2.4 is great, easy-rsa 3.0.4 is great, but I want to use ufw not iptables, so removing from the script and handling that manually
# (using branch openvpn-2.4-update as the basis for the ufw branch)

if [[ "$EUID" -ne 0 ]]; then
	echo "Sorry, you need to run this as root"
	exit 1
fi

if [[ ! -e /dev/net/tun ]]; then
	echo "TUN is not available"
	exit 2
fi

if grep -qs "CentOS release 5" "/etc/redhat-release"; then
	echo "CentOS 5 is too old and not supported"
	exit 3
fi

if [[ -e /etc/debian_version ]]; then
	OS="debian"
	# Getting the version number, to verify that a recent version of OpenVPN is available
	VERSION_ID=$(grep "VERSION_ID" /etc/os-release)
	SYSCTL='/etc/sysctl.conf'
	if [[ "$VERSION_ID" != 'VERSION_ID="8"' ]] && [[ "$VERSION_ID" != 'VERSION_ID="9"' ]] && [[ "$VERSION_ID" != 'VERSION_ID="14.04"' ]] && [[ "$VERSION_ID" != 'VERSION_ID="16.04"' ]] && [[ "$VERSION_ID" != 'VERSION_ID="17.10"' ]]; then
		echo "Your version of Debian/Ubuntu is not supported."
		echo "I can't install a recent version of OpenVPN on your system."
		echo ""
		echo "However, if you're using Debian unstable/testing, or Ubuntu beta,"
		echo "then you can continue, a recent version of OpenVPN is available on these."
		echo "Keep in mind they are not supported, though."
		while [[ $CONTINUE != "y" && $CONTINUE != "n" ]]; do
			read -p "Continue ? [y/n]: " -e CONTINUE
		done
		if [[ "$CONTINUE" = "n" ]]; then
			echo "Ok, bye !"
			exit 4
		fi
	fi
elif [[ -e /etc/fedora-release ]]; then
	OS=fedora
	SYSCTL='/etc/sysctl.d/openvpn.conf'
elif [[ -e /etc/centos-release || -e /etc/redhat-release || -e /etc/system-release ]]; then
	OS=centos
	SYSCTL='/etc/sysctl.conf'
elif [[ -e /etc/arch-release ]]; then
	OS=arch
	SYSCTL='/etc/sysctl.d/openvpn.conf'
else
	echo "Looks like you aren't running this installer on a Debian, Ubuntu, CentOS or ArchLinux system"
	exit 4
fi

newclient () {
	# Where to write the custom client.ovpn?
	if [ ${SUDO_USER} ]; then   # if not, use SUDO_USER
		homeDir="/home/${SUDO_USER}"
	else  # if not SUDO_USER, use /root
		homeDir="/root"
	fi
	# Generates the custom client.ovpn
	cp /etc/openvpn/client-template.txt $homeDir/$1.ovpn
	echo "<ca>" >> $homeDir/$1.ovpn
	cat /etc/openvpn/easy-rsa/pki/ca.crt >> $homeDir/$1.ovpn
	echo "</ca>" >> $homeDir/$1.ovpn
	echo "<cert>" >> $homeDir/$1.ovpn
	cat /etc/openvpn/easy-rsa/pki/issued/$1.crt >> $homeDir/$1.ovpn
	echo "</cert>" >> $homeDir/$1.ovpn
	echo "<key>" >> $homeDir/$1.ovpn
	cat /etc/openvpn/easy-rsa/pki/private/$1.key >> $homeDir/$1.ovpn
	echo "</key>" >> $homeDir/$1.ovpn
	#We verify if we used tls-crypt or tls-auth during the installation
	TLS_SIG=$(cat /etc/openvpn/TLS_SIG)
	if [[ $TLS_SIG == "1" ]]; then
		echo "<tls-crypt>" >> $homeDir/$1.ovpn
		cat /etc/openvpn/tls-crypt.key >> $homeDir/$1.ovpn
		echo "</tls-crypt>" >> $homeDir/$1.ovpn
	elif [[ $TLS_SIG == "2" ]]; then
		echo "key-direction 1" >> $homeDir/$1.ovpn
		echo "<tls-auth>" >> $homeDir/$1.ovpn
		cat /etc/openvpn/tls-auth.key >> $homeDir/$1.ovpn
		echo "</tls-auth>" >> $homeDir/$1.ovpn
	fi
}

# Try to get our IP from the system and fallback to the Internet.
# I do this to make the script compatible with NATed servers (LowEndSpirit/Scaleway)
# and to avoid getting an IPv6.
IP=$(ip addr | grep 'inet' | grep -v inet6 | grep -vE '127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | grep -o -E '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -1)
if [[ "$IP" = "" ]]; then
	IP=$(wget -qO- ipv4.icanhazip.com)
fi
# Get Internet network interface with default route
NIC=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)

if [[ -e /etc/openvpn/server.conf ]]; then
	while :
	do
	clear
		echo "OpenVPN-install (github.com/krider2010/OpenVPN-install)"
		echo ""
		echo "Looks like OpenVPN is already installed"
		echo ""
		echo "What do you want to do?"
		echo "   1) Add a cert for a new user"
		echo "   2) Revoke existing user cert"
		echo "   3) Remove OpenVPN"
		echo "   4) Exit"
		read -p "Select an option [1-4]: " option
		case $option in
			1)
			echo ""
			echo "Tell me a name for the client cert"
			echo "Please, use one word only, no special characters"
			read -p "Client name: " -e -i newclient CLIENT
			cd /etc/openvpn/easy-rsa/
			./easyrsa build-client-full $CLIENT nopass
			# Generates the custom client.ovpn
			newclient "$CLIENT"
			echo ""
			echo "Client $CLIENT added, certs available at $homeDir/$CLIENT.ovpn"
			exit
			;;
			2)
			NUMBEROFCLIENTS=$(tail -n +2 /etc/openvpn/easy-rsa/pki/index.txt | grep -c "^V")
			if [[ "$NUMBEROFCLIENTS" = '0' ]]; then
				echo ""
				echo "You have no existing clients!"
				exit 5
			fi
			echo ""
			echo "Select the existing client certificate you want to revoke"
			tail -n +2 /etc/openvpn/easy-rsa/pki/index.txt | grep "^V" | cut -d '=' -f 2 | nl -s ') '
			if [[ "$NUMBEROFCLIENTS" = '1' ]]; then
				read -p "Select one client [1]: " CLIENTNUMBER
			else
				read -p "Select one client [1-$NUMBEROFCLIENTS]: " CLIENTNUMBER
			fi
			CLIENT=$(tail -n +2 /etc/openvpn/easy-rsa/pki/index.txt | grep "^V" | cut -d '=' -f 2 | sed -n "$CLIENTNUMBER"p)
			cd /etc/openvpn/easy-rsa/
			./easyrsa --batch revoke $CLIENT
			EASYRSA_CRL_DAYS=3650 ./easyrsa gen-crl
			rm -rf pki/reqs/$CLIENT.req
			rm -rf pki/private/$CLIENT.key
			rm -rf pki/issued/$CLIENT.crt
			rm -rf /etc/openvpn/crl.pem
			cp /etc/openvpn/easy-rsa/pki/crl.pem /etc/openvpn/crl.pem
			chmod 644 /etc/openvpn/crl.pem
			echo ""
			echo "Certificate for client $CLIENT revoked"
			echo "Exiting..."
			exit
			;;
			3)
			echo ""
			read -p "Do you really want to remove OpenVPN? [y/n]: " -e -i n REMOVE
			if [[ "$REMOVE" = 'y' ]]; then
				if [[ "$OS" = 'debian' ]]; then
					apt-get autoremove --purge -y openvpn
				elif [[ "$OS" = 'arch' ]]; then
					pacman -R openvpn --noconfirm
				else
					yum remove openvpn -y
				fi
				rm -rf /etc/openvpn
				rm -rf /usr/share/doc/openvpn*
				# Where are the client files?
				if [ ${SUDO_USER} ]; then   # if not, use SUDO_USER
					homeDir="/home/${SUDO_USER}"
				else  # if not SUDO_USER, use /root
					homeDir="/root"
				fi
				rm $homeDir/*.ovpn
				echo ""
				echo "OpenVPN removed!"
			else
				echo ""
				echo "Removal aborted!"
			fi
			exit
			;;
			4) exit;;
		esac
	done
else
	clear
	echo "Welcome to the secure OpenVPN installer (github.com/Angristan/OpenVPN-install)"
	echo ""
	# OpenVPN setup and first user creation
	echo "I need to ask you a few questions before starting the setup"
	echo "You can leave the default options and just press enter if you are ok with them"
	echo ""
	echo "I need to know the IPv4 address of the network interface you want OpenVPN listening to."
	echo "If your server is running behind a NAT, (e.g. LowEndSpirit, Scaleway) leave the IP address as it is. (local/private IP)"
	echo "Otherwise, it should be your public IPv4 address."
	read -p "IP address: " -e -i $IP IP
	echo ""
	echo "What port do you want for OpenVPN?"
	read -p "Port: " -e -i 1194 PORT
	echo ""
	echo "What protocol do you want for OpenVPN?"
	echo "Unless UDP is blocked, you should not use TCP (unnecessarily slower)"
	echo "   1) UDP (recommended)"
	echo "   2) TCP"
	while [[ $PROTOCOL != "1" && $PROTOCOL != "2" ]]; do
		read -p "Protocol [1-2]: " -e -i 1 PROTOCOL
	done
	echo ""
	echo "What DNS do you want to use with the VPN?"
	echo "   1) Current system resolvers (from /etc/resolv.conf)"
	echo "   2) Quad9 (Anycast: worldwide)"
	echo "   3) FDN (France)"
	echo "   4) DNS.WATCH (Germany)"
	echo "   5) OpenDNS (Anycast: worldwide)"
	echo "   6) Google (Anycast: worldwide)"
	echo "   7) Yandex Basic (Russia)"
	echo "   8) AdGuard DNS (Russia)"
	echo "   9) Don't send DNS via the VPN (only do this if you know you want to do this)"
	while [[ $DNS != "1" && $DNS != "2" && $DNS != "3" && $DNS != "4" && $DNS != "5" && $DNS != "6" && $DNS != "7" && $DNS != "8" && $DNS != "9" ]]; do
		read -p "DNS [1-9]: " -e -i 1 DNS
	done
	echo ""
	echo "Choose which compression algorithm you want to use:"
	echo "   1) LZ4 (faster)"
	echo "   2) LZ0 (use for OpenVPN 2.3 compatibility)"
	echo "   3) No compression"
	while [[ $COMPRESSION != "1" && $COMPRESSION != "2" && $COMPRESSION != "3" ]]; do
		read -p "Compression algorithm [1-3]: " -e -i 1 COMPRESSION
	done
	case $COMPRESSION in
		1)
		COMPRESSION="lz4"
		;;
		2)
		COMPRESSION="lzo"
		;;
		3)
		# We don't do anything
		;;
	esac
	echo ""
	echo "See https://github.com/krider2010/OpenVPN-install#encryption to learn more about "
	echo "the encryption in OpenVPN and the choices proposed in this script."
	echo "Please note that all the choices proposed are secure enough considering today's strandards, unlike some default OpenVPN options"
	echo "You can just type "enter" if you don't know what to choose."
	echo "Note that if you want to use an OpenVPN 2.3 client, You'll have to choose OpenVPN 2.3-compatible options."
	echo "All OpenVPN 2.3-compatible choices are specified for each following option."
	echo ""
	echo "Choose which cipher you want to use for the data channel:"
	echo "   1) AES-128-GCM (recommended)"
	echo "   2) AES-192-GCM"
	echo "   3) AES-256-GCM"
	echo "Only use AES-CBC for OpenVPN 2.3 compatibilty"
	echo "   4) AES-128-CBC"
	echo "   5) AES-192-CBC"
	echo "   6) AES-256-CBC"
	while [[ $CIPHER != "1" && $CIPHER != "2" && $CIPHER != "3" && $CIPHER != "4" && $CIPHER != "5" && $CIPHER != "6" ]]; do
		read -p "Data channel cipher [1-6]: " -e -i 1 CIPHER
	done
	case $CIPHER in
		1)
		CIPHER="cipher AES-128-GCM"
		;;
		2)
		CIPHER="cipher AES-192-GCM"
		;;
		3)
		CIPHER="cipher AES-256-GCM"
		;;
		4)
		CIPHER="cipher AES-128-CBC"
		;;
		5)
		CIPHER="cipher AES-192-CBC"
		;;
		6)
		CIPHER="cipher AES-256-CBC"
		;;
	esac
	echo ""
	echo "Choose what kind of certificate you want to use:"
	echo "Elleptic Curves keys (EC) are recommended, they're faster, lighter and more secure."
	echo "Use RSA for OpenVPN 2.3 compatibilty"
	echo "   1) ECDSA (recommended)"
	echo "   2) RSA"
	while [[ $CERT_TYPE != "1" && $CERT_TYPE != "2" ]]; do
		read -p "Certificate type [1-2]: " -e -i 1 CERT_TYPE
	done
	case $CERT_TYPE in
		1)
			echo ""
			echo "Choose which curve you want to use for the EC key:"
			echo "   1) secp256r1"
			echo "   2) secp384r1 (recommended)"
			echo "   3) secp521r1"
			while [[ $CERT_CURVE != "1" && $CERT_CURVE != "2" && $CERT_CURVE != "3" ]]; do
				read -p "Curve [1-3]: " -e -i 2 CERT_CURVE
			done
			case $CERT_CURVE in
				1)
					CERT_CURVE="secp256r1"
				;;
				2)
					CERT_CURVE="secp384r1"
				;;
				3)
					CERT_CURVE="secp521r1"
				;;
			esac
		;;
		2)
			echo ""
			echo "Choose which RSA key size you want to use:"
			echo "   1) 2048 bits"
			echo "   2) 3072 bits (recommended)"
			echo "   3) 4096 bits"
			while [[ $RSA_SIZE != "1" && $RSA_SIZE != "2" && $RSA_SIZE != "3" ]]; do
				read -p "DH key size [1-3]: " -e -i 2 RSA_SIZE
			done
			case $RSA_SIZE in
				1)
					RSA_SIZE="2048"
				;;
				2)
					RSA_SIZE="3072"
				;;
				3)
					RSA_SIZE="4096"
				;;
			esac
		;;
	esac
	echo ""
	echo "Choose which hash algorithm you want to use for the certificate:"
	echo "   1) SHA-256"
	echo "   2) SHA-384 (recommended)"
	echo "   3) SHA-512"
	while [[ $CERT_HASH != "1" && $CERT_HASH != "2" && $CERT_HASH != "3" ]]; do
		read -p "Hash algorithm [1-3]: " -e -i 2 CERT_HASH
	done
	case $CERT_HASH in
		1)
			CERT_HASH="sha256"
		;;
		2)
			CERT_HASH="sha384"
		;;
		3)
			CERT_HASH="sha512"
		;;
	esac
	echo ""
	echo "Choose what kind of Diffie-Hellman key you want to use."
	echo "Elleptic Curves (EC) are recommended, they're faster, lighter and more secure."
	echo "Use DH for OpenVPN 2.3 compatibilty"
	echo "   1) ECDH (recommended)"
	echo "   2) DH"
	while [[ $DH_TYPE != "1" && $DH_TYPE != "2" ]]; do
		read -p "DH key type [1-2]: " -e -i 1 DH_TYPE
	done
	case $DH_TYPE in
		1)
			echo ""
			echo "Choose which curve you want to use for the ECDH key"
			echo "   1) secp256r1"
			echo "   2) secp384r1 (recommended)"
			echo "   3) secp521r1"
			while [[ $DH_CURVE != "1" && $DH_CURVE != "2" && $DH_CURVE != "3" ]]; do
				read -p "Curve [1-3]: " -e -i 2 DH_CURVE
			done
			case $DH_CURVE in
				1)
					DH_CURVE="secp256r1"
				;;
				2)
					DH_CURVE="secp384r1"
				;;
				3)
					DH_CURVE="secp521r1"
				;;
			esac
		;;
		2)
			echo""
			echo "Choose which DH key size you want to use"
			echo "   1) 2048 bits"
			echo "   2) 3072 bits (recommended)"
			echo "   3) 4096 bits"
			while [[ $DH_SIZE != "1" && $DH_SIZE != "2" && $DH_SIZE != "3" ]]; do
				read -p "DH key size [1-3]: " -e -i 2 DH_SIZE
			done
			case $DH_SIZE in
				1)
					DH_SIZE="2048"
				;;
				2)
					DH_SIZE="3072"
				;;
				3)
					DH_SIZE="4096"
				;;
			esac
		;;
	esac
	echo ""
	echo "Choose which cipher you want to use for the control channel:"
	if [[ "$CERT_TYPE" = '1' ]]; then
		echo "   1) ECDHE-ECDSA-AES-256-GCM-SHA384 (recommended)"
		echo "   2) ECDHE-ECDSA-AES-128-GCM-SHA256"
		while [[ $CC_ENC != "1" && $CC_ENC != "2" ]]; do
			read -p "Control channel cipher [1-2]: " -e -i 1 CC_ENC
		done
		case $CC_ENC in
			1)
				CC_ENC="TLS-ECDHE-ECDSA-WITH-AES-256-GCM-SHA384"
			;;
			2)
				CC_ENC="TLS-ECDHE-ECDSA-WITH-AES-128-GCM-SHA256"
			;;
		esac
	elif [[ "$CERT_TYPE" = '2' ]]; then
		echo "   1) ECDHE-RSA-AES-256-GCM-SHA384 (recommended)"
		echo "   2) ECDHE-RSA-AES-128-GCM-SHA256"
		while [[ $CC_ENC != "1" && $CC_ENC != "2" ]]; do
			read -p "Control channel cipher [1-2]: " -e -i 1 CC_ENC
		done
		case $CC_ENC in
			1)
				CC_ENC="TLS-ECDHE-RSA-WITH-AES-256-GCM-SHA384"
			;;
			2)
				CC_ENC="TLS-ECDHE-RSA-WITH-AES-128-GCM-SHA256"
			;;
		esac
	fi
	echo ""
	echo "Do you want to use tls-crypt or tls-auth?"
	echo "They both encrypt and authenticate all control channel packets with a key."
	echo "tls-crypt is more advanced and secure than tls-auth, but it's an OpenVPN 2.4 feature."
	echo "   1) tls-crypt (recommended)"
	echo "   2) tls-auth (use only for OpenVPN 2.3 client compatibility)"
	while [[ $TLS_SIG != "1" && $TLS_SIG != "2" ]]; do
			read -p "Crontrol channel additional security layer [1-2]: " -e -i 1 TLS_SIG
	done
	echo""
	if [[ $CIPHER = "cipher AES-256-GCM" ]] || [[ $CIPHER = "cipher AES-192-GCM" ]] || [[ $CIPHER = "cipher AES-128-GCM" ]]; then
		echo "Choose which message digest algorithm you want to use for the tls-auth/tls-crypt control channel packets:"
	elif [[ $CIPHER = "cipher AES-256-CBC" ]] || [[ $CIPHER = "cipher AES-192-CBC" ]] || [[ $CIPHER = "cipher AES-128-CBC" ]]; then
		echo "Choose which message digest algorithm you want to use for the data channel packets"
		echo "and the tls-auth/tls-crypt control channel packets:"
	fi
	echo "   1) SHA-256"
	echo "   2) SHA-384 (recommended)"
	echo "   3) SHA-512"
		while [[ $HMAC_AUTH != "1" && $HMAC_AUTH != "2" && $HMAC_AUTH != "3" ]]; do
			read -p "HMAC authentication algorithm [1-3]: " -e -i 2 HMAC_AUTH
	done
	case $HMAC_AUTH in
		1)
			HMAC_AUTH="SHA256"
		;;
		2)
			HMAC_AUTH="SHA384"
		;;
		3)
			HMAC_AUTH="SHA512"
		;;
	esac
	echo ""
	echo "Finally, tell me a name for the client certificate and configuration"
	while [[ $CLIENT = "" ]]; do
		echo "Please, use one word only, no special characters"
		read -p "Client name: " -e -i client CLIENT
	done
	echo ""
	echo "Okay, that was all I needed. We are ready to setup your OpenVPN server now"
	read -n1 -r -p "Press any key to continue..."

	if [[ "$OS" = 'debian' ]]; then
		apt-get install ca-certificates gpg -y
		# We add the OpenVPN repo to get the latest version.
		# Debian 8
		if [[ "$VERSION_ID" = 'VERSION_ID="8"' ]]; then
			echo "deb http://build.openvpn.net/debian/openvpn/stable jessie main" > /etc/apt/sources.list.d/openvpn.list
			wget -O - https://swupdate.openvpn.net/repos/repo-public.gpg | apt-key add -
		elif [[ "$VERSION_ID" = 'VERSION_ID="9"' ]]; then
			echo "deb http://build.openvpn.net/debian/openvpn/stable stretch main" > /etc/apt/sources.list.d/openvpn.list
			wget -O - https://swupdate.openvpn.net/repos/repo-public.gpg | apt-key add -
		# Ubuntu 14.04
		elif [[ "$VERSION_ID" = 'VERSION_ID="14.04"' ]]; then
			echo "deb http://build.openvpn.net/debian/openvpn/stable trusty main" > /etc/apt/sources.list.d/openvpn.list
			wget -O - https://swupdate.openvpn.net/repos/repo-public.gpg | apt-key add -
		# Ubuntu 16.04
		elif [[ "$VERSION_ID" = 'VERSION_ID="16.04"' ]]; then
			echo "deb http://build.openvpn.net/debian/openvpn/stable xenial main" > /etc/apt/sources.list.d/openvpn.list
			wget -O - https://swupdate.openvpn.net/repos/repo-public.gpg | apt-key add -
		fi
		# Ubuntu >= 17.04 and Debian > 9 have OpenVPN 2.4 without the need of a third party repository.
		# The we install OpenVPN
		apt-get update
		apt-get install openvpn openssl wget ca-certificates curl -y
	elif [[ "$OS" = 'centos' || "$OS" = 'fedora' ]]; then
		if [[ "$OS" = 'centos' ]]; then
			yum install epel-release -y
		fi
		yum install openvpn openssl wget ca-certificates curl -y
	else
		# Else, the distro is ArchLinux
		echo ""
		echo ""
		echo "As you're using ArchLinux, I need to update the packages on your system to install those I need."
		echo "Not doing that could cause problems between dependencies, or missing files in repositories."
		echo ""
		echo "Continuing will update your installed packages and install needed ones."
		while [[ $CONTINUE != "y" && $CONTINUE != "n" ]]; do
			read -p "Continue ? [y/n]: " -e -i y CONTINUE
		done
		if [[ "$CONTINUE" = "n" ]]; then
			echo "Ok, bye !"
			exit 4
		fi

		if [[ "$OS" = 'arch' ]]; then
			# Install dependencies
			pacman -Syu openvpn openssl wget ca-certificates curl --needed --noconfirm
			systemctl daemon-reload
		fi
	fi

	#To remember if we use tls-crypt or tls-auth when generating a new client conf
	echo $TLS_SIG > /etc/openvpn/TLS_SIG

	# Find out if the machine uses nogroup or nobody for the permissionless group
	if grep -qs "^nogroup:" /etc/group; then
		NOGROUP=nogroup
	else
		NOGROUP=nobody
	fi

	# An old version of easy-rsa was available by default in some openvpn packages
	if [[ -d /etc/openvpn/easy-rsa/ ]]; then
		rm -rf /etc/openvpn/easy-rsa/
	fi
	# Get easy-rsa
	wget -O ~/EasyRSA-3.0.4.tgz https://github.com/OpenVPN/easy-rsa/releases/download/v3.0.4/EasyRSA-3.0.4.tgz
	tar xzf ~/EasyRSA-3.0.4.tgz -C ~/
	mv ~/EasyRSA-3.0.4/ /etc/openvpn/
	mv /etc/openvpn/EasyRSA-3.0.4/ /etc/openvpn/easy-rsa/
	chown -R root:root /etc/openvpn/easy-rsa/
	rm -rf ~/EasyRSA-3.0.4.tgz
	cd /etc/openvpn/easy-rsa/
	if [[ $CERT_TYPE == "1" ]]; then
		echo "set_var EASYRSA_ALGO ec
    set_var EASYRSA_CURVE $CERT_CURVE" > vars
	elif [[ $CERT_TYPE == "2" ]]; then
		echo "set_var EASYRSA_KEY_SIZE $RSA_SIZE" > vars
	fi
	# Generate a random, alphanumeric identifier of 16 characters for CN and one for server name
	SERVER_CN="cn_$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)"
	SERVER_NAME="server_$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)"
	echo 'set_var EASYRSA_DIGEST "'$CERT_HASH'"' >> vars
	echo "set_var EASYRSA_REQ_CN $SERVER_CN" >> vars
	# Create the PKI, set up the CA, the DH params and the server + client certificates
	./easyrsa init-pki
	./easyrsa --batch build-ca nopass
	if [[ $DH_TYPE == "2" ]]; then
		openssl dhparam -out dh.pem $DH_SIZE
	fi
	./easyrsa build-server-full $SERVER_NAME nopass
	./easyrsa build-client-full $CLIENT nopass
	EASYRSA_CRL_DAYS=3650 ./easyrsa gen-crl
	if [[ $TLS_SIG == "1" ]]; then
		# Generate tls-crypt key
		openvpn --genkey --secret /etc/openvpn/tls-crypt.key
	elif [[ $TLS_SIG == "2" ]]; then
		# Generate tls-auth key
		openvpn --genkey --secret /etc/openvpn/tls-auth.key
	fi
	# Move all the generated files
	cp pki/ca.crt pki/private/ca.key pki/issued/$SERVER_NAME.crt pki/private/$SERVER_NAME.key /etc/openvpn/easy-rsa/pki/crl.pem /etc/openvpn
	if [[ $DH_TYPE == "2" ]]; then
		cp dh.pem /etc/openvpn
	fi
	# Make cert revocation list readable for non-root
	chmod 644 /etc/openvpn/crl.pem

	# Generate server.conf
	echo "port $PORT" > /etc/openvpn/server.conf
	if [[ "$PROTOCOL" = '1' ]]; then
		echo "proto udp" >> /etc/openvpn/server.conf
	elif [[ "$PROTOCOL" = '2' ]]; then
		echo "proto tcp" >> /etc/openvpn/server.conf
	fi
	echo "dev tun
user nobody
group $NOGROUP
persist-key
persist-tun
keepalive 10 120
topology subnet
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt" >> /etc/openvpn/server.conf
	# DNS resolvers
	case $DNS in
		1)
		# Obtain the resolvers from resolv.conf and use them for OpenVPN
		grep -v '#' /etc/resolv.conf | grep 'nameserver' | grep -E -o '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | while read line; do
			echo "push \"dhcp-option DNS $line\"" >> /etc/openvpn/server.conf
		done
		echo 'push "redirect-gateway def1 bypass-dhcp" '>> /etc/openvpn/server.conf
		;;
		2) #Quad9
		echo 'push "dhcp-option DNS 9.9.9.9"' >> /etc/openvpn/server.conf
		echo 'push "redirect-gateway def1 bypass-dhcp" '>> /etc/openvpn/server.conf
		;;
		3) #FDN
		echo 'push "dhcp-option DNS 80.67.169.40"' >> /etc/openvpn/server.conf
		echo 'push "dhcp-option DNS 80.67.169.12"' >> /etc/openvpn/server.conf
		echo 'push "redirect-gateway def1 bypass-dhcp" '>> /etc/openvpn/server.conf
		;;
		4) #DNS.WATCH
		echo 'push "dhcp-option DNS 84.200.69.80"' >> /etc/openvpn/server.conf
		echo 'push "dhcp-option DNS 84.200.70.40"' >> /etc/openvpn/server.conf
		echo 'push "redirect-gateway def1 bypass-dhcp" '>> /etc/openvpn/server.conf
		;;
		5) #OpenDNS
		echo 'push "dhcp-option DNS 208.67.222.222"' >> /etc/openvpn/server.conf
		echo 'push "dhcp-option DNS 208.67.220.220"' >> /etc/openvpn/server.conf
		echo 'push "redirect-gateway def1 bypass-dhcp" '>> /etc/openvpn/server.conf
		;;
		6) #Google
		echo 'push "dhcp-option DNS 8.8.8.8"' >> /etc/openvpn/server.conf
		echo 'push "dhcp-option DNS 8.8.4.4"' >> /etc/openvpn/server.conf
		echo 'push "redirect-gateway def1 bypass-dhcp" '>> /etc/openvpn/server.conf
		;;
		7) #Yandex Basic
		echo 'push "dhcp-option DNS 77.88.8.8"' >> /etc/openvpn/server.conf
		echo 'push "dhcp-option DNS 77.88.8.1"' >> /etc/openvpn/server.conf
		echo 'push "redirect-gateway def1 bypass-dhcp" '>> /etc/openvpn/server.conf
		;;
		8) #AdGuard DNS
		echo 'push "dhcp-option DNS 176.103.130.130"' >> /etc/openvpn/server.conf
		echo 'push "dhcp-option DNS 176.103.130.131"' >> /etc/openvpn/server.conf
		echo 'push "redirect-gateway def1 bypass-dhcp" '>> /etc/openvpn/server.conf
		;;
		9) # Don't send DNS via the VPN
		;;
	esac
echo "crl-verify crl.pem
ca ca.crt
cert $SERVER_NAME.crt
key $SERVER_NAME.key" >> /etc/openvpn/server.conf
if [[ $TLS_SIG == "1" ]]; then
	echo "tls-crypt tls-crypt.key 0" >> /etc/openvpn/server.conf
elif [[ $TLS_SIG == "2" ]]; then
	echo "tls-auth tls-auth.key 0" >> /etc/openvpn/server.conf
fi
if [[ $DH_TYPE == "1" ]]; then
	echo "dh none
ecdh-curve $DH_CURVE" >> /etc/openvpn/server.conf
elif [[ $DH_TYPE == "2" ]]; then
	echo "dh dh.pem" >> /etc/openvpn/server.conf
fi
echo "auth $HMAC_AUTH
$CIPHER
ncp-disable
tls-server
tls-version-min 1.2
tls-cipher $CC_ENC" >> /etc/openvpn/server.conf

if [[ $COMPRESSION == "lz4" || $COMPRESSION == "lzo"  ]]; then
	echo "compress $COMPRESSION" >> /etc/openvpn/server.conf
fi

echo "status openvpn.log
verb 3" >> /etc/openvpn/server.conf

	# Create the sysctl configuration file if needed (mainly for Arch Linux)
	if [[ ! -e $SYSCTL ]]; then
		touch $SYSCTL
	fi

	# Enable net.ipv4.ip_forward for the system
	sed -i '/\<net.ipv4.ip_forward\>/c\net.ipv4.ip_forward=1' $SYSCTL
	if ! grep -q "\<net.ipv4.ip_forward\>" $SYSCTL; then
		echo 'net.ipv4.ip_forward=1' >> $SYSCTL
	fi
	# Avoid an unneeded reboot
	echo 1 > /proc/sys/net/ipv4/ip_forward
	# If SELinux is enabled and a custom port was selected, we need this
	if hash sestatus 2>/dev/null; then
		if sestatus | grep "Current mode" | grep -qs "enforcing"; then
			if [[ "$PORT" != '1194' ]]; then
				# semanage isn't available in CentOS 6 by default
				if ! hash semanage 2>/dev/null; then
					yum install policycoreutils-python -y
				fi
				if [[ "$PROTOCOL" = '1' ]]; then
					semanage port -a -t openvpn_port_t -p udp $PORT
				elif [[ "$PROTOCOL" = '2' ]]; then
					semanage port -a -t openvpn_port_t -p tcp $PORT
				fi
			fi
		fi
	fi
	# And finally, restart OpenVPN
	if [[ "$OS" = 'debian' ]]; then
		# Little hack to check for systemd
		if pgrep systemd-journal; then
				#Workaround to fix OpenVPN service on OpenVZ
				sed -i 's|LimitNPROC|#LimitNPROC|' /lib/systemd/system/openvpn\@.service
				sed -i 's|/etc/openvpn/server|/etc/openvpn|' /lib/systemd/system/openvpn\@.service
				sed -i 's|%i.conf|server.conf|' /lib/systemd/system/openvpn\@.service
				systemctl daemon-reload
				systemctl restart openvpn
				systemctl enable openvpn
		else
			/etc/init.d/openvpn restart
		fi
	else
		if pgrep systemd-journal; then
			if [[ "$OS" = 'arch' || "$OS" = 'fedora' ]]; then
				#Workaround to avoid rewriting the entire script for Arch & Fedora
				sed -i 's|/etc/openvpn/server|/etc/openvpn|' /usr/lib/systemd/system/openvpn-server@.service
				sed -i 's|%i.conf|server.conf|' /usr/lib/systemd/system/openvpn-server@.service
				systemctl daemon-reload
				systemctl restart openvpn-server@openvpn.service
				systemctl enable openvpn-server@openvpn.service
			else
				systemctl restart openvpn@server.service
				systemctl enable openvpn@server.service
			fi
		else
			service openvpn restart
			chkconfig openvpn on
		fi
	fi
	# Try to detect a NATed connection and ask about it to potential LowEndSpirit/Scaleway users
	EXTERNALIP=$(wget -qO- ipv4.icanhazip.com)
	if [[ "$IP" != "$EXTERNALIP" ]]; then
		echo ""
		echo "Looks like your server is behind a NAT!"
		echo ""
        echo "If your server is NATed (e.g. LowEndSpirit, Scaleway, or behind a router),"
        echo "then I need to know the address that can be used to access it from outside."
        echo "If that's not the case, just ignore this and leave the next field blank"
        read -p "External IP or domain name: " -e USEREXTERNALIP
		if [[ "$USEREXTERNALIP" != "" ]]; then
			IP=$USEREXTERNALIP
		fi
	fi
	# client-template.txt is created so we have a template to add further users later
	echo "client" > /etc/openvpn/client-template.txt
	if [[ "$PROTOCOL" = '1' ]]; then
		echo "proto udp" >> /etc/openvpn/client-template.txt
	elif [[ "$PROTOCOL" = '2' ]]; then
		echo "proto tcp-client" >> /etc/openvpn/client-template.txt
	fi
	echo "remote $IP $PORT
dev tun
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verify-x509-name $SERVER_NAME name
auth $HMAC_AUTH
auth-nocache
$CIPHER
tls-client
tls-version-min 1.2
tls-cipher $CC_ENC" >> /etc/openvpn/client-template.txt

if [[ $COMPRESSION == "lz4" || $COMPRESSION == "lzo"  ]]; then
	echo "compress $COMPRESSION" >> /etc/openvpn/client-template.txt
fi

echo "setenv opt block-outside-dns
verb 3" >> /etc/openvpn/client-template.txt

	# Generate the custom client.ovpn
	newclient "$CLIENT"
	echo ""
	echo "Finished!"
	echo ""
	echo "Your client config is available at $homeDir/$CLIENT.ovpn"
	echo "If you want to add more clients, you simply need to run this script another time!"
fi
exit 0;
