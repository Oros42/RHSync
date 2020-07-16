#!/usr/bin/env bash
# RHSync
# The Remote HTTP Synchronization
#
# author  Oros42 (ecirtam.net)
# link    https://github.com/Oros42/RHSync
# license CC0 Public Domain
# date    2020-07-13

# need :
# sudo apt install parallel gpg wget rsync

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
	path=$1
	pushd $path > /dev/null
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

	if [[ ! -f Contents.gz ]]; then
		makeContents $wwwDir
	fi

	gunzip -k Contents.gz
	gpg --clear-sign --digest-algo SHA512 --output Release --default-key $email Contents
	gzip -c Release  > Release.gz
	rm Release
	date +"%F %T UTC" -u > ReleaseInfos.txt
	sha512sum Release.gz >> ReleaseInfos.txt
	if [[ -f ReleaseInfos ]]; then
		rm ReleaseInfos
	fi
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

function cleanUpPath()
{
	if [[ ! "${wwwDir: -1}" == "/" ]]; then
		wwwDir="$wwwDir/"
	fi
	if [[ ! "${wwwTmp: -1}" == "/" ]]; then
		wwwDir="$wwwTmp/"
	fi
}


function getVersion()
{
	local url=$1
	local tmpDirectory=$(mktemp -d -t tmp.XXXXXXXXXX)
	ReleaseInfosContentTmp=""

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
			ReleaseInfosContentTmp=$(cat $ReleaseInfosPath)
		else
			version=""
		fi
	else
		version=""	
	fi

	rm -r "$tmpDirectory"
}


function extractRelease()
{
	local in=$1
	local out=$2
	if [ -f $out ]; then
		rm $out
	fi
	gunzip -c $in > ${out}.tmp
	checkAndExtract ${out}.tmp ${out}
}

function extractContents()
{
	local in=$1
	local out=$2
	if [ -f $out ]; then
		rm $out
	fi
	gunzip -c $in > $out
}

function checkNoMissingFiles()
{
	set +e
	local path=$1
	local ok=0
	if [[ -s ${wwwDir}Release.gz && -s ${wwwDir}Contents.gz ]]; then
		local tmp=$(mktemp -d -t tmp.XXXXXXXXXX)
		extractRelease ${wwwDir}Release.gz $tmp/Release
		extractContents ${wwwDir}Contents.gz $tmp/Contents
		set +e
		diff -n --suppress-common-lines $tmp/Contents $tmp/Release  > $tmp/newFiles
		set -e

		sed -i "/^[ad][0-9]* [0-9]*$/d" $tmp/newFiles

		if [ -s $tmp/newFiles ]; then
			ok=0
		else
			ok=1
		fi
		rm -r $tmp
	else
		ok=0
	fi

	echo $ok
}
function sync()
{
	local canditateVersion=""
	local canditateUrl=()
	local canditateHash=""
	local version=""
	local hash=""
	local ReleaseInfosContent=""
	local ReleaseInfosContentTmp=""

	cleanUpPath

	ckeckKey

	localVersion="2000-01-01 01:00:00 UTC"

	getVersion ${wwwDir}ReleaseInfos

	ret=$(checkNoMissingFiles ${wwwDir})
	if [ "$ret" -eq 1 ]; then
		# if no missing files
		if [[ "$version" != "" ]]; then
			localVersion=$version
		fi
	fi

	# search the last version available
	for url in $nodes; do 
		getVersion $url

		if [[ "$localVersion" < "$version" ]]; then
			if [[ "$canditateVersion" == "" || "$canditateVersion" < "$version" ]]; then
				canditateVersion=$version
				canditateUrl=($url)
				canditateHash="$hash"
				ReleaseInfosContent="$ReleaseInfosContentTmp"
			elif [[ "$canditateVersion" != "" || "$canditateVersion" == "$version" ]]; then
				canditateUrl[${#canditateUrl[*]}]=$url
			fi
		fi
		version=""
		hash=""
	done

	if [[ "$canditateVersion" != "" 
			&& ${#canditateUrl[*]} -gt 0
			&& "$canditateHash" != "" 
		]]; then

		echo "Local version: $localVersion"
		echo "Canditate version: $canditateVersion"

		local tmpDirectory=$(mktemp -d -t tmp.XXXXXXXXXX)

		echo "$ReleaseInfosContent" > $tmpDirectory/ReleaseInfos
		echo "$canditateHash" > $tmpDirectory/Release.sum


		if [[ -f ${wwwDir}Contents.gz ]]; then
			cp ${wwwDir}Contents.gz $tmpDirectory/LocalContents.gz
			gunzip $tmpDirectory/LocalContents.gz
		else
			touch $tmpDirectory/LocalContents
		fi

		if [ -d ${wwwTmp}tmp ]; then
			rm -r ${wwwTmp}tmp
		fi

		if [ -d ${wwwTmp}ok ]; then
			rm -r ${wwwTmp}ok
		fi

		mkdir -p ${wwwTmp}{tmp,ok}

		# for each canditates or exit if synchro is finish
		for serverUrl in  ${canditateUrl[*]}; do
			set +e
#TODO check error
			if [[ ! -s $tmpDirectory/Release.gz ]]; then
				wget -q --tries=5 --timeout=60 ${serverUrl}Release.gz -O $tmpDirectory/Release.gz

				if [[ -s "$tmpDirectory/Release.gz" ]]; then
					pushd $tmpDirectory > /dev/null
					sha512sum -c Release.sum
					popd > /dev/null

					gunzip -t $tmpDirectory/Release.gz
#TODO check error
					gunzip -k $tmpDirectory/Release.gz

					checkAndExtract "$tmpDirectory/Release" "$tmpDirectory/Release.tmp"
					if [[ -s "$tmpDirectory/Release.tmp" ]]; then
						mv "$tmpDirectory/Release.tmp" "$tmpDirectory/Release"
					else
						rm "$tmpDirectory/Release"
					fi
				fi
			fi
#TODO check error
			set -e

			if [[ -s "$tmpDirectory/Release" ]]; then
				if [ -f $tmpDirectory/Contents.gz ]; then
					rm $tmpDirectory/Contents.gz
				fi
				if [ -f $tmpDirectory/Contents ]; then
					rm $tmpDirectory/Contents
				fi

				set +e
				wget -q --tries=5 --timeout=60 ${serverUrl}Contents.gz -O $tmpDirectory/Contents.gz
				set -e

				gunzip -t $tmpDirectory/Contents.gz
#TODO check error
				gunzip $tmpDirectory/Contents.gz
				
				set +e
				diff -n --suppress-common-lines $tmpDirectory/LocalContents $tmpDirectory/Release  > $tmpDirectory/newFiles
				set -e

				# cleaning
				sed -i "/^[ad][0-9]* [0-9]*$/d" $tmpDirectory/newFiles

				if [ ! -s $tmpDirectory/newFiles ]; then
					# No new files
					break
				fi

				# extract new files available in Contents
				set +e
				if [ -f $tmpDirectory/availableNewFiles ]; then
					rm $tmpDirectory/availableNewFiles
				fi
				touch $tmpDirectory/availableNewFiles

				while read line; do
					grep "$line" $tmpDirectory/Contents >> $tmpDirectory/availableNewFiles
				done < $tmpDirectory/newFiles
				set -e

				# if have new files
				if [ -s $tmpDirectory/availableNewFiles ]; then
					cp $tmpDirectory/availableNewFiles $tmpDirectory/availableNewFiles.url
					# remove hash and keep url
					sed -i "s|^[0-9a-f]*  |$serverUrl|" $tmpDirectory/availableNewFiles.url

					if [[ "$(head -n 1 $tmpDirectory/availableNewFiles.url)" != "" ]]; then
						echo "update"
						

#FIXME some time the name of file is truncate :-/
# need to fix long path + long file name
# happen on encrypted partition
						#outDir=$(echo "$serverUrl" | awk -F/ '{print $3}' | sed 's|:80$||')
						cat $tmpDirectory/availableNewFiles.url | parallel --gnu "wget --tries=5 --timeout=60 -qc -P ${wwwTmp}tmp -x -nH "'{}' > /dev/null 2>&1

						pushd ${wwwTmp}tmp > /dev/null

						# fin sub folder path
						local path=${serverUrl:8}
						path=${path#*/}
						if [ "$path" != "" ]; then
							if [ -d $path ]; then
								cd $path
							else
#FIXME
echo "Path ${wwwTmp}$path doesn't exist !"
							fi
						fi

#TODO loop on files and remove corrupted files
						sha512sum -c $tmpDirectory/availableNewFiles


						# update local contents
						find * -type f -not -path "Release*" -exec sha512sum '{}' \; >> $tmpDirectory/Contents.tmp
						cat $tmpDirectory/LocalContents >> $tmpDirectory/Contents.tmp
						sort -u -t' ' -k2 $tmpDirectory/Contents.tmp > $tmpDirectory/LocalContents	


						rsync --remove-source-files -a ./* ${wwwTmp}ok
						popd > /dev/null
					fi

				fi

			fi
		done

		# publish new files
		mv $tmpDirectory/Release.gz ${wwwTmp}ok
		mv $tmpDirectory/ReleaseInfos ${wwwTmp}ok
		rsync --remove-source-files -a ${wwwTmp}ok/ ${wwwDir}
		mv $tmpDirectory/LocalContents $tmpDirectory/Contents
		gzip -c $tmpDirectory/Contents  > ${wwwDir}Contents.gz


		rm -r $tmpDirectory
		if [ ! -z "$(ls -A ${wwwTmp})" ]; then
			rm -r ${wwwTmp}*
		fi

		echo "end :-)"
	else
		#TODO quite mode
		echo "No update"
	fi
	exit
}



function help()
{
	readonly PROGNAME=$(basename $0)
	cat <<- EOF
		Remote HTTP Synchronization
		Usage: RHSync.sh [OPTION] ACTION [wwwDir]

		Actions:
		sync		Synchronization
		index		Create new hash index (Contents.gz)
		release		Create new release (Release.gz + ReleaseInfos)
		keygen		Generate a PGP key used to sign Release.gz and ReleaseInfos

		Options:
		-c, --config	Path to the config file
		-h, --help		Help
		--refreshkeys	[1|0] 1: Refresh PGP key, 0: skip the refresh

		wwwDir: Path to the www directory

		Examples:
		./RHSync.sh sync
		./RHSync.sh -c myConf1 sync
		./RHSync.sh -c myConf1 --refreshkeys 0 sync
		./RHSync.sh index /var/www/mySite
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

# TODO add
# - no GPG check
# - no wwwTmp


readonly ARG="$1"
if [[ "$ARG" == "sync" ]]; then
	sync
elif [[ "$ARG" == "index" ]]; then
	if [[ "$#" -gt 1 ]]; then
		wwwDir="$2"
	fi
	makeContents $wwwDir
elif [[ "$ARG" == "release" ]]; then
	if [[ "$#" -gt 1 ]]; then
		wwwDir="$2"
	fi
	makeRelease
elif [[ "$ARG" == "keygen" ]]; then
	makeGPGKey
else
	help
fi
