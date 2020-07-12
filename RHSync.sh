#!/usr/bin/env bash
# RHSync
# The Remote HTTP Synchronization
#
# author  Oros42 (ecirtam.net)
# link    https://github.com/Oros42/RHSync
# license CC0 Public Domain
# date    2020-07-12

# need :
# sudo apt install parallel gpg wget

set -euo pipefail

function checkGPGConf()
{
	if [[ "$email" == "" ]]; then
		echo "Please set the variable \$email in config"
		exit 1
	fi
	if [[ "$gpgHome" == "" ]]; then
		echo "Please set the variable \$gpgHome in config"
		exit 1
	fi

	mkdir -p $gpgHome
	chmod 700 $gpgHome
	export GNUPGHOME=$gpgHome
}
function makeGPGKey()
{
	checkGPGConf

	gpg --batch --quick-generate-key "<$email>" ed25519 cert 20y

	FPR=$(gpg -k $email|head -n 2|tail -n 1|awk '{print $1}')
	echo "Key ID : $FPR"
	gpg --batch --quick-add-key $FPR ed25519 sign 20y

	#gpg -a --export "$email" > public.gpg

	echo "Open the link and click on send email verification"
	#gpg --export $email | curl -T - https://keys.openpgp.org
	k=$(gpg -a --export $email)
	wget --method=PUT --body-data="$k" https://keys.openpgp.org -qO-
	exit
}

function ckeckKey()
{
	if [[ "$(gpg --no-default-keyring --keyring ./public_keyrings.gpg -k|grep $email)" == "" ]]; then
		gpg --no-default-keyring --keyring ./public_keyrings.gpg --keyserver hkps://keys.openpgp.org --search-keys $email
	fi
	if [[ $refreshKeys -eq 1 ]]; then
		gpg --no-default-keyring --keyring ./public_keyrings.gpg --keyserver hkps://keys.openpgp.org --refresh-keys
	fi
}


function makeContents()
{
	pushd $wwwDir > /dev/null
	rm -f Contents*
	find * -type f -not -path "Release*" -exec sha512sum '{}' \; >> Contents.tmp
	sort -t' ' -k2 Contents.tmp > Contents
	rm Contents.tmp
	gzip -c Contents  > Contents.gz
	rm Contents
	popd > /dev/null
}

function makeRelease()
{
	checkGPGConf
	pushd $wwwDir > /dev/null
	gunzip -k Contents.gz
	gpg --clear-sign --digest-algo SHA512 --output Release --default-key $email Contents
	gzip -c Release  > Release.gz
	rm Release
	date +"%F %T UTC" -u > ReleaseInfos.txt
	sha512sum Release.gz >> ReleaseInfos.txt
	gpg --clear-sign --digest-algo SHA512 --output ReleaseInfos --default-key $email ReleaseInfos.txt
	rm ReleaseInfos.txt
	rm Contents
	popd > /dev/null
}


function checkAndExtract()
{
	local input=$1
	local output=$2
	set +e
	gpg --no-default-keyring --keyring ./public_keyrings.gpg --verify $input > /dev/null 2>&1
	ERROR_CODE=$?
	if [[ ${ERROR_CODE} == 0 ]]; then
		gpg --no-default-keyring --keyring ./public_keyrings.gpg --output $output --decrypt $input > /dev/null 2>&1
	fi
	set -e
}


function getVersion()
{
	local url=$1
	local tmpDirectory=$(mktemp -d -t tmp.XXXXXXXXXX)
	if [[ "${url::7}" == "http://" || "${url::7}" == "https:/" ]]; then
		set +e
		wget -q --tries=5 --timeout=60 "${url}ReleaseInfos" -O "$tmpDirectory/ReleaseInfos"
		set -e
		ReleaseInfosPath="$tmpDirectory/ReleaseInfos"
	else
		ReleaseInfosPath=$url
	fi
	if [[ -s "$ReleaseInfosPath" ]]; then
		ReleaseInfosTxtPath="$tmpDirectory/ReleaseInfos.txt"
		checkAndExtract "$ReleaseInfosPath" "$ReleaseInfosTxtPath"
		if [[ -s "$ReleaseInfosTxtPath" ]]; then
			version=$(head -n 1 "$ReleaseInfosTxtPath")
			hash=$(head -n 2 "$ReleaseInfosTxtPath"|tail -n 1)
		else
			version=""
		fi
	else
		version=""	
	fi

	rm -r "$tmpDirectory"
}

function sync()
{
	ckeckKey

	localVersion="2000-01-01 01:00:00 UTC"
	getVersion $wwwTmp/ReleaseInfos
	if [[ "$version" != "" ]]; then
		localVersion=$version
	fi

echo "local $localVersion"


	local canditateVersion=""
	local canditateUrl=""
	local canditateHash=""
	local version=""
	local hash=""
	# search the last version available
	for url in $nodes; do 
		getVersion $url
#FIXME keep in cache ReleaseInfos !!!
		if [[ "$localVersion" < "$version" ]]; then
			if [[ "$canditateVersion" == "" || "$canditateVersion" < "$version" ]]; then
				canditateVersion=$version
				canditateUrl=$url
				canditateHash="$hash"
			fi
		fi
		version=""
		hash=""
	done

	if [[ "$canditateVersion" != "" 
			&& "$canditateUrl" != "" 
			&& "$canditateHash" != "" 
		]]; then
		local tmpDirectory=$(mktemp -d -t tmp.XXXXXXXXXX)
echo  $tmpDirectory
		set +e
		echo "$canditateHash" > $tmpDirectory/Release.sum

		wget -q --tries=5 --timeout=60 ${canditateUrl}Contents.gz -O $tmpDirectory/Contents.gz
#TODO check error
		wget -q --tries=5 --timeout=60 ${canditateUrl}Release.gz -O $tmpDirectory/Release.gz
#TODO check error
		set -e

		if [[ -s "$tmpDirectory/Release.gz" ]]; then
			pushd $tmpDirectory > /dev/null
			sha512sum -c Release.sum
			popd > /dev/null

			gunzip -t $tmpDirectory/Release.gz
#TODO check error
			gunzip -k $tmpDirectory/Release.gz

			checkAndExtract "$tmpDirectory/Release" "$tmpDirectory/Release.tmp"
			mv "$tmpDirectory/Release.tmp" "$tmpDirectory/Release"

			gunzip -t $tmpDirectory/Contents.gz
#TODO check error
			gunzip $tmpDirectory/Contents.gz

			if [[ ! -f ./cache/Contents ]]; then
				touch ./cache/Contents
			fi
			
			set +e
			diff -n --suppress-common-lines ./cache/Contents $tmpDirectory/Release  > $tmpDirectory/newFiles
			set -e

			# cleaning
			sed -i "/^[ad][0-9]* [0-9]*$/d" $tmpDirectory/newFiles

			# extract new files available in Contents
			set +e
			touch $tmpDirectory/availableNewFiles
			while read line; do
				grep "$line" $tmpDirectory/Contents >> $tmpDirectory/availableNewFiles
			done < $tmpDirectory/newFiles
			set -e

			cp $tmpDirectory/availableNewFiles $tmpDirectory/availableNewFiles.url
			# remove hash and keep url
			sed -i "s|^[0-9a-f]*  |$canditateUrl|" $tmpDirectory/availableNewFiles.url

			if [[ "$(head -n 1 $tmpDirectory/availableNewFiles.url)" != "" ]]; then
				echo "update"
				

#FIXME some time the name of file is truncate :-/
# need to fix long path + long file name
# happen on encrypted partition
				outDir=$(echo "$url" | awk -F/ '{print $3}' | sed 's|:80$||')
				cat $tmpDirectory/availableNewFiles.url | parallel --gnu "wget --tries=5 --timeout=60 -qc -P $wwwTmp -x "'{}' > /dev/null 2>&1
				pushd $wwwTmp/$outDir > /dev/null
				sha512sum -c $tmpDirectory/availableNewFiles
				mv $tmpDirectory/Release.gz .
				popd > /dev/null
#FIXME
				cp $tmpDirectory/Release ./cache/Contents
			fi

		fi

echo "end :-)"
#rm -r $tmpDirectory
	fi
	exit
}



function help()
{
	readonly PROGNAME=$(basename $0)
	cat <<- EOF
		Remote HTTP Synchronization
		Usage: $PROGNAME [OPTION] ACTION

		Actions:
		sync		Synchronization
		index		Create new hash index (Contents.gz)
		release		Create new release (Release.gz + ReleaseInfos)
		keygen		Generate a PGP key used to sign Release.gz and ReleaseInfos

		Options:
		-c, --config	Path to the config file
		-h, --help		Help
		--refreshkeys	[1|0] 1: Refresh PGP key, 0: skip the refresh

		Examples:
		./$PROGNAME sync
		./$PROGNAME -c myConf1 sync
		./$PROGNAME -c myConf1 --refreshkeys 0 sync
	EOF
	exit
}


confName="config"
refreshKeys=1

eval set -- $(getopt -l conf:,help,refreshkeys: -o c:h -- "$@")

while true
do
	name="$1"
	shift
	case $name in
		-c|--config)
			confName="${1%:*}"
			shift
			;;
		-h|--help)
			help
			;;
		--refreshkeys)
			if [[ "${1%:*}" -eq 1 ]]; then
				refreshKeys=1
			else
				refreshKeys=0
			fi
			shift
			;;
		--)
			break
			;;
		*)
			echo "Illegal option: $name"
			exit 1
			;;
	esac
done

if [[ $# -lt 1 ]]; then
	help
fi

if [[ ! -f $confName ]]; then
	echo "$confName not found"
	echo "Copy config.dist to $confName and adapt it"
	exit 1
fi
. ./$confName

readonly ARG="$1"
if [[ "$ARG" == "sync" ]]; then
	sync
elif [[ "$ARG" == "index" ]]; then
	if [[ "$2" != "" ]]; then
		wwwDir=$2
	fi
	makeContents
elif [[ "$ARG" == "release" ]]; then
	if [[ "$2" != "" ]]; then
		wwwDir=$2
	fi
	makeRelease
elif [[ "$ARG" == "keygen" ]]; then
	makeGPGKey
else
	help
fi
