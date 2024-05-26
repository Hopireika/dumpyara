#!/usr/bin/env bash

[[ $# = 0 ]] && echo "No Input" && exit 1

OS=$(uname)
if [ "$OS" = 'Darwin' ]; then
	export LC_CTYPE=C
fi

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
# Create input & working directory if it does not exist
mkdir -p "$PROJECT_DIR"/input "$PROJECT_DIR"/working
UTILSDIR="${PROJECT_DIR}"/utils

# Determine which command to use for privilege escalation
if command -v sudo >/dev/null 2>&1; then
	sudo_cmd="sudo"
elif command -v doas >/dev/null 2>&1; then
	sudo_cmd="doas"
else
	echo "Neither sudo nor doas found. Please install one of them."
	exit 1
fi

EXTERNAL_TOOLS=(
	Hopireika/android_tools
)

for tool_slug in "${EXTERNAL_TOOLS[@]}"; do
	if ! [[ -d "${UTILSDIR}"/"${tool_slug#*/}" ]]; then
		git clone -q https://github.com/"${tool_slug}".git "${UTILSDIR}"/"${tool_slug#*/}"
	else
		git -C "${UTILSDIR}"/"${tool_slug#*/}" pull
	fi
done

# Activate virtual environment
source .venv/bin/activate

# GitHub token
if [[ -n $2 ]]; then
	GIT_OAUTH_TOKEN=$2
elif [[ -f ".githubtoken" ]]; then
	GIT_OAUTH_TOKEN=$(<.githubtoken)
else
	echo "GitHub token not found. Dumping just locally..."
fi

# download or copy from local?
if echo "$1" | grep -e '^\(https\?\|ftp\)://.*$' >/dev/null; then
	# 1DRV URL DIRECT LINK IMPLEMENTATION
	if echo "$1" | grep -e '1drv.ms' >/dev/null; then
		URL=$(curl -I "$1" -s | grep location | sed -e "s/redir/download/g" | sed -e "s/location: //g")
	else
		URL=$1
	fi
	cd "$PROJECT_DIR"/input || exit
	{ type -p aria2c >/dev/null 2>&1 && printf "Downloading File...\n" && aria2c -x16 --check-certificate=false -j"$(nproc)" "${URL}"; } || { printf "Downloading File...\n" && wget -q --content-disposition --show-progress --progress=bar:force "${URL}" || exit 1; }
	if [[ ! -f "$(echo ${URL##*/} | inline-detox)" ]]; then
		URL=$(wget --server-response --spider "${URL}" 2>&1 | awk -F"filename=" '{print $2}')
	fi
	detox "${URL##*/}"
else
	URL=$(printf "%s\n" "$1")
	[[ -e "$URL" ]] || { echo "Invalid Input" && exit 1; }
fi

ORG=Hopireika #your GitHub org name
FILE=$(echo ${URL##*/} | inline-detox)
EXTENSION=$(echo ${URL##*.} | inline-detox)
UNZIP_DIR=${FILE/.$EXTENSION/}
PARTITIONS="system systemex system_ext system_other vendor cust odm odm_ext oem factory product modem xrom oppo_product opproduct reserve india my_preload my_odm my_stock my_operator my_country my_product my_company my_engineering my_heytap my_custom my_manifest my_carrier my_region my_bigball my_version special_preload vendor_dlkm odm_dlkm system_dlkm mi_ext"

if [[ -d "$1" ]]; then
	echo 'Directory detected. Copying...'
	cp -a "$1" "$PROJECT_DIR"/working/"${UNZIP_DIR}"
elif [[ -f "$1" ]]; then
	echo 'File detected. Copying...'
	cp -a "$1" "$PROJECT_DIR"/input/"${FILE}" >/dev/null 2>&1
fi

# clone other repo's
if [[ -d "$PROJECT_DIR/Firmware_extractor" ]]; then
	git -C "$PROJECT_DIR"/Firmware_extractor pull --recurse-submodules
else
	git clone -q --recurse-submodules https://github.com/Hopireika/Firmware_extractor "$PROJECT_DIR"/Firmware_extractor
fi
if [[ -d "$PROJECT_DIR/mkbootimg_tools" ]]; then
	git -C "$PROJECT_DIR"/mkbootimg_tools pull --recurse-submodules
else
	git clone -q https://github.com/carlitros900/mkbootimg_tools "$PROJECT_DIR/mkbootimg_tools"
fi
if [[ -d "$PROJECT_DIR/vmlinux-to-elf" ]]; then
	git -C "$PROJECT_DIR"/vmlinux-to-elf pull --recurse-submodules
else
	git clone -q https://github.com/marin-m/vmlinux-to-elf "$PROJECT_DIR/vmlinux-to-elf"
fi

# extract rom via Firmware_extractor
[[ ! -d "$1" ]] && bash "$PROJECT_DIR"/Firmware_extractor/extractor.sh "$PROJECT_DIR"/input/"${FILE}" "$PROJECT_DIR"/working/"${UNZIP_DIR}"

# Extract boot.img
if [[ -f "$PROJECT_DIR"/working/"${UNZIP_DIR}"/boot.img ]]; then
	extract-dtb "$PROJECT_DIR"/working/"${UNZIP_DIR}"/boot.img -o "$PROJECT_DIR"/working/"${UNZIP_DIR}"/bootimg >/dev/null # Extract boot
	bash "$PROJECT_DIR"/mkbootimg_tools/mkboot "$PROJECT_DIR"/working/"${UNZIP_DIR}"/boot.img "$PROJECT_DIR"/working/"${UNZIP_DIR}"/boot >/dev/null 2>&1
	echo 'boot extracted'
	# extract-ikconfig
	[[ ! -e "${PROJECT_DIR}"/extract-ikconfig ]] && curl https://raw.githubusercontent.com/torvalds/linux/master/scripts/extract-ikconfig >${PROJECT_DIR}/extract-ikconfig
	bash "${PROJECT_DIR}"/extract-ikconfig "$PROJECT_DIR"/working/"${UNZIP_DIR}"/boot.img >"$PROJECT_DIR"/working/"${UNZIP_DIR}"/ikconfig
	# vmlinux-to-elf
	mkdir -p "$PROJECT_DIR"/working/"${UNZIP_DIR}"/bootRE
	python3 "${PROJECT_DIR}"/vmlinux-to-elf/vmlinux_to_elf/kallsyms_finder.py "$PROJECT_DIR"/working/"${UNZIP_DIR}"/boot.img >"$PROJECT_DIR"/working/"${UNZIP_DIR}"/bootRE/boot_kallsyms.txt 2>&1
	echo 'boot_kallsyms.txt generated'
	python3 "${PROJECT_DIR}"/vmlinux-to-elf/vmlinux_to_elf/main.py "$PROJECT_DIR"/working/"${UNZIP_DIR}"/boot.img "$PROJECT_DIR"/working/"${UNZIP_DIR}"/bootRE/boot.elf >/dev/null 2>&1
	echo 'boot.elf generated'
fi

if [[ -f "$PROJECT_DIR"/working/"${UNZIP_DIR}"/dtbo.img ]]; then
	extract-dtb "$PROJECT_DIR"/working/"${UNZIP_DIR}"/dtbo.img -o "$PROJECT_DIR"/working/"${UNZIP_DIR}"/dtbo >/dev/null # Extract dtbo
	echo 'dtbo extracted'
fi

# Extract dts
mkdir -p "$PROJECT_DIR"/working/"${UNZIP_DIR}"/bootdts
dtb_list=$(find "$PROJECT_DIR"/working/"${UNZIP_DIR}"/bootimg -name '*.dtb' -type f -printf '%P\n' | sort)
for dtb_file in $dtb_list; do
	dtc -I dtb -O dts -o "$(echo "$PROJECT_DIR"/working/"${UNZIP_DIR}"/bootdts/"$dtb_file" | sed -r 's|.dtb|.dts|g')" "$PROJECT_DIR"/working/"${UNZIP_DIR}"/bootimg/"$dtb_file" >/dev/null 2>&1
done

# extract PARTITIONS
cd "$PROJECT_DIR"/working/"${UNZIP_DIR}" || exit
for p in $PARTITIONS; do
	# Try to extract images via fsck.erofs
	if [ -f $p.img ] && [ $p != "modem" ]; then
		echo "Trying to extract $p partition via fsck.erofs."
		"$PROJECT_DIR"/Firmware_extractor/tools/Linux/bin/fsck.erofs --extract="$p" "$p".img
		# Deletes images if they were correctly extracted via fsck.erofs
		if [ -d "$p" ]; then
			rm "$p".img >/dev/null 2>&1
		else
			# Uses 7z if images could not be extracted via fsck.erofs
			if [[ -e "$p.img" ]]; then
				mkdir "$p" 2>/dev/null || rm -rf "${p:?}"/*
				echo "Extraction via fsck.erofs failed, extracting $p partition via 7z"
				7z x "$p".img -y -o"$p"/ >/dev/null 2>&1
				if [ $? -eq 0 ]; then
					rm "$p".img >/dev/null 2>&1
				else
					echo "Couldn't extract $p partition via 7z. Using mount loop"
					$sudo_cmd mount -o loop -t auto "$p".img "$p"
					mkdir "${p}_"
					$sudo_cmd cp -rf "${p}/"* "${p}_"
					$sudo_cmd umount "${p}"
					$sudo_cmd cp -rf "${p}_/"* "${p}"
					$sudo_cmd rm -rf "${p}_"
					if [ $? -eq 0 ]; then
						rm -fv "$p".img >/dev/null 2>&1
					else
						echo "Couldn't extract $p partition. It might use an unsupported filesystem."
						echo "For EROFS: make sure you're using Linux 5.4+ kernel."
						echo "For F2FS: make sure you're using Linux 5.15+ kernel."
					fi
				fi
			fi
		fi
	fi
done

# Fix permissions
$sudo_cmd chown "$(whoami)" "$PROJECT_DIR"/working/"${UNZIP_DIR}"/./* -fR
$sudo_cmd chmod -fR u+rwX "$PROJECT_DIR"/working/"${UNZIP_DIR}"/./*

# board-info.txt
find "$PROJECT_DIR"/working/"${UNZIP_DIR}"/modem -type f -exec strings {} \; | grep "QC_IMAGE_VERSION_STRING=MPSS." | sed "s|QC_IMAGE_VERSION_STRING=MPSS.||g" | cut -c 4- | sed -e 's/^/require version-baseband=/' >>"$PROJECT_DIR"/working/"${UNZIP_DIR}"/board-info.txt
find "$PROJECT_DIR"/working/"${UNZIP_DIR}"/tz* -type f -exec strings {} \; | grep "QC_IMAGE_VERSION_STRING" | sed "s|QC_IMAGE_VERSION_STRING|require version-trustzone|g" >>"$PROJECT_DIR"/working/"${UNZIP_DIR}"/board-info.txt
if [ -e "$PROJECT_DIR"/working/"${UNZIP_DIR}"/vendor/build.prop ]; then
	strings "$PROJECT_DIR"/working/"${UNZIP_DIR}"/vendor/build.prop | grep "ro.vendor.build.date.utc" | sed "s|ro.vendor.build.date.utc|require version-vendor|g" >>"$PROJECT_DIR"/working/"${UNZIP_DIR}"/board-info.txt
fi
sort -u -o "$PROJECT_DIR"/working/"${UNZIP_DIR}"/board-info.txt "$PROJECT_DIR"/working/"${UNZIP_DIR}"/board-info.txt

# set variables
ls system/build*.prop 2>/dev/null || ls system/system/build*.prop 2>/dev/null || { echo "No system build*.prop found, pushing cancelled!" && exit; }
flavor=$(grep -oP "(?<=^ro.build.flavor=).*" -hs {system,system/system,vendor}/build*.prop | head -n 1)
[[ -z "${flavor}" ]] && flavor=$(grep -oP "(?<=^ro.vendor.build.flavor=).*" -hs vendor/build*.prop | head -n 1)
[[ -z "${flavor}" ]] && flavor=$(grep -oP "(?<=^ro.system.build.flavor=).*" -hs {system,system/system}/build*.prop | head -n 1)
[[ -z "${flavor}" ]] && flavor=$(grep -oP "(?<=^ro.build.type=).*" -hs {system,system/system}/build*.prop | head -n 1)
release=$(grep -oP "(?<=^ro.build.version.release=).*" -hs {system,system/system,vendor}/build*.prop | head -n 1)
[[ -z "${release}" ]] && release=$(grep -oP "(?<=^ro.vendor.build.version.release=).*" -hs vendor/build*.prop | head -n 1)
[[ -z "${release}" ]] && release=$(grep -oP "(?<=^ro.system.build.version.release=).*" -hs {system,system/system}/build*.prop | head -n 1)
release=$(echo "$release" | head -1)
id=$(grep -oP "(?<=^ro.build.id=).*" -hs {system,system/system,vendor}/build*.prop | head -n 1)
[[ -z "${id}" ]] && id=$(grep -oP "(?<=^ro.vendor.build.id=).*" -hs vendor/build*.prop | head -n 1)
[[ -z "${id}" ]] && id=$(grep -oP "(?<=^ro.system.build.id=).*" -hs {system,system/system}/build*.prop | head -n 1)
incremental=$(grep -oP "(?<=^ro.build.version.incremental=).*" -hs {system,system/system,vendor}/build*.prop | head -n 1)
[[ -z "${incremental}" ]] && incremental=$(grep -oP "(?<=^ro.vendor.build.version.incremental=).*" -hs vendor/build*.prop | head -n 1)
[[ -z "${incremental}" ]] && incremental=$(grep -oP "(?<=^ro.system.build.version.incremental=).*" -hs {system,system/system}/build*.prop | head -n 1)
tags=$(grep -oP "(?<=^ro.build.tags=).*" -hs {system,system/system,vendor}/build*.prop | head -n 1)
[[ -z "${tags}" ]] && tags=$(grep -oP "(?<=^ro.vendor.build.tags=).*" -hs vendor/build*.prop | head -n 1)
[[ -z "${tags}" ]] && tags=$(grep -oP "(?<=^ro.system.build.tags=).*" -hs {system,system/system}/build*.prop | head -n 1)
platform=$(grep -oP "(?<=^ro.board.platform=).*" -hs {system,system/system,vendor}/build*.prop | head -n 1)
[[ -z "${platform}" ]] && platform=$(grep -oP "(?<=^ro.vendor.board.platform=).*" -hs vendor/build*.prop | head -n 1)
[[ -z "${platform}" ]] && platform=$(grep -oP "(?<=^ro.system.board.platform=).*" -hs {system,system/system}/build*.prop | head -n 1)
manufacturer=$(grep -oP "(?<=^ro.product.odm.manufacturer=).*" -hs odm/etc/build*.prop | head -n 1)
[[ -z "${manufacturer}" ]] && manufacturer=$(grep -oP "(?<=^ro.product.manufacturer=).*" -hs {system,system/system,vendor}/build*.prop | head -n 1)
[[ -z "${manufacturer}" ]] && manufacturer=$(grep -oP "(?<=^ro.vendor.product.manufacturer=).*" -hs vendor/build*.prop | head -n 1)
[[ -z "${manufacturer}" ]] && manufacturer=$(grep -oP "(?<=^ro.system.product.manufacturer=).*" -hs {system,system/system}/build*.prop | head -n 1)
[[ -z "${manufacturer}" ]] && manufacturer=$(grep -oP "(?<=^ro.product.vendor.manufacturer=).*" -hs vendor/build*.prop | head -n 1)
[[ -z "${manufacturer}" ]] && manufacturer=$(grep -oP "(?<=^ro.product.system.manufacturer=).*" -hs {system,system/system}/build*.prop | head -n 1)
fingerprint=$(grep -oP "(?<=^ro.odm.build.fingerprint=).*" -hs odm/etc/*build*.prop | head -n 1)
[[ -z "${fingerprint}" ]] && fingerprint=$(grep -oP "(?<=^ro.build.fingerprint=).*" -hs {system,system/system,vendor}/build*.prop | head -n 1)
[[ -z "${fingerprint}" ]] && fingerprint=$(grep -oP "(?<=^ro.vendor.build.fingerprint=).*" -hs vendor/build*.prop | head -n 1)
[[ -z "${fingerprint}" ]] && fingerprint=$(grep -oP "(?<=^ro.system.build.fingerprint=).*" -hs {system,system/system}/build*.prop | head -n 1)
codename=$(grep -oP "(?<=^ro.product.odm.device=).*" -hs odm/etc/build*.prop | head -1)
[[ -z "${codename}" ]] && codename=$(grep -oP "(?<=^ro.product.device=).*" -hs {vendor,system,system/system}/build*.prop | head -1)
[[ -z "${codename}" ]] && codename=$(grep -oP "(?<=^ro.product.vendor.device=).*" -hs vendor/build*.prop | head -1)
[[ -z "${codename}" ]] && codename=$(grep -oP "(?<=^ro.vendor.product.device=).*" -hs vendor/build*.prop | head -1)
[[ -z "${codename}" ]] && codename=$(grep -oP "(?<=^ro.product.system.device=).*" -hs {system,system/system}/build*.prop | head -1)
[[ -z "${codename}" ]] && codename=$(echo "$fingerprint" | cut -d / -f3 | cut -d : -f1)
[[ -z "${codename}" ]] && codename=$(grep -oP "(?<=^ro.build.fota.version=).*" -hs {system,system/system}/build*.prop | cut -d - -f1 | head -1)
[[ -z "${codename}" ]] && codename=$(grep -oP "(?<=^ro.build.product=).*" -hs {vendor,system,system/system}/build*.prop | head -1)
brand=$(grep -oP "(?<=^ro.product.odm.brand=).*" -hs odm/etc/${codename}_build.prop | head -1)
[[ -z "${brand}" ]] && brand=$(grep -oP "(?<=^ro.product.odm.brand=).*" -hs odm/etc/build*.prop | head -1)
[[ -z "${brand}" ]] && brand=$(grep -oP "(?<=^ro.product.brand=).*" -hs {vendor,system,system/system}/build*.prop | head -1)
[[ -z "${brand}" ]] && brand=$(grep -oP "(?<=^ro.product.vendor.brand=).*" -hs vendor/build*.prop | head -1)
[[ -z "${brand}" ]] && brand=$(grep -oP "(?<=^ro.vendor.product.brand=).*" -hs vendor/build*.prop | head -1)
[[ -z "${brand}" ]] && brand=$(grep -oP "(?<=^ro.product.system.brand=).*" -hs {system,system/system}/build*.prop | head -1)
[[ -z "${brand}" ]] && brand=$(echo "$fingerprint" | cut -d / -f1)
description=$(grep -oP "(?<=^ro.build.description=).*" -hs {system,system/system,vendor}/build*.prop | head -n 1)
[[ -z "${description}" ]] && description=$(grep -oP "(?<=^ro.vendor.build.description=).*" -hs vendor/build*.prop | head -n 1)
[[ -z "${description}" ]] && description=$(grep -oP "(?<=^ro.system.build.description=).*" -hs {system,system/system}/build*.prop | head -n 1)
[[ -z "${description}" ]] && description="$flavor $release $id $incremental $tags"
is_ab=$(grep -oP "(?<=^ro.build.ab_update=).*" -hs {system,system/system,vendor}/build*.prop | head -1)
[[ -z "${is_ab}" ]] && is_ab="false"
branch=$(echo "$description" | tr ' ' '-')
repo=$(echo "$brand"_"$codename"_dump | tr '[:upper:]' '[:lower:]')
platform=$(echo "$platform" | tr '[:upper:]' '[:lower:]' | tr -dc '[:print:]' | tr '_' '-' | cut -c 1-35)
top_codename=$(echo "$codename" | tr '[:upper:]' '[:lower:]' | tr -dc '[:print:]' | tr '_' '-' | cut -c 1-35)
manufacturer=$(echo "$manufacturer" | tr '[:upper:]' '[:lower:]' | tr -dc '[:print:]' | tr '_' '-' | cut -c 1-35)
printf "# %s\n- manufacturer: %s\n- platform: %s\n- codename: %s\n- flavor: %s\n- release: %s\n- id: %s\n- incremental: %s\n- tags: %s\n- fingerprint: %s\n- is_ab: %s\n- brand: %s\n- branch: %s\n- repo: %s\n" "$description" "$manufacturer" "$platform" "$codename" "$flavor" "$release" "$id" "$incremental" "$tags" "$fingerprint" "$is_ab" "$brand" "$branch" "$repo" >"$PROJECT_DIR"/working/"${UNZIP_DIR}"/README.md
cat "$PROJECT_DIR"/working/"${UNZIP_DIR}"/README.md

# Generate AOSP device tree
if python3 -c "import aospdtgen"; then
	echo "aospdtgen installed, generating device tree"
	mkdir -p "${PROJECT_DIR}/working/${UNZIP_DIR}/aosp-device-tree"
	if python3 -m aospdtgen . --output "${PROJECT_DIR}/working/${UNZIP_DIR}/aosp-device-tree"; then
		echo "AOSP device tree successfully generated"
	else
		echo "Failed to generate AOSP device tree"
	fi
fi

# Generate Files having the sha1sum values of the Blobs
function write_sha1sum() {
	# Usage: write_sha1sum <file> <destination_file>

	local SRC_FILE=$1
	local DST_FILE=$2

	# Temporary file
	local TMP_FILE=${SRC_FILE}.sha1sum.tmp

	# Get rid of all the Blank lines and Comments
	(cat ${SRC_FILE} | grep -v '^[[:space:]]*$' | grep -v "# ") >${TMP_FILE}

	# Append the sha1sum of blobs in the Destination File
	cp ${SRC_FILE} ${DST_FILE}
	cat ${TMP_FILE} | while read -r i; do {
		local BLOB=${i}

		# Do we have a "-" before the blob's path? If yes, then remove it
		local BLOB_TOPDIR=$(echo ${BLOB} | cut -d / -f1)
		[ "${BLOB_TOPDIR:0:1}" = "-" ] && local BLOB=${BLOB_TOPDIR/-/}/${BLOB/${BLOB_TOPDIR}\//}

		# Is it a non- /vendor blob?
		[ ! -e "${BLOB}" ] && {
			# for system libs, bins etc.
			if [ -e "system/${BLOB}" ]; then
				local BLOB="system/${BLOB}"
			# for system-as-root system libs, bins etc.
			elif [ -e "system/system/${BLOB}" ]; then
				local BLOB="system/system/${BLOB}"
			fi
		}
		local SHA1=$(sha1sum ${BLOB} | gawk '{print $1}')

		local BLOB=${i} # Switch back to the Original Blob's name
		local ORG_EXP="${BLOB}"
		local FINAL_EXP="${BLOB}|${SHA1}"

		# Append the |sha1sum
		sed -i "s:${ORG_EXP}$:${FINAL_EXP}:g" "${DST_FILE}"
	}; done

	# Delete the Temporary file
	rm ${TMP_FILE}
}

# Generate proprietary-files.txt
printf "Generating proprietary-files.txt...\n"
bash "${UTILSDIR}"/android_tools/tools/proprietary-files.sh "$PROJECT_DIR"/working/"${UNZIP_DIR}" >/dev/null
printf "# All blobs from %s, unless pinned\n" "${description}" >"$PROJECT_DIR"/working/"${UNZIP_DIR}"/proprietary-files.txt
cat "${UTILSDIR}"/android_tools/working/proprietary-files.txt >>"$PROJECT_DIR"/working/"${UNZIP_DIR}"/proprietary-files.txt

# Generate proprietary-files.sha1
printf "Generating proprietary-files.sha1...\n"
printf "# All blobs are from \"%s\" and are pinned with sha1sum values\n" "${description}" >"$PROJECT_DIR"/working/"${UNZIP_DIR}"/proprietary-files.sha1
write_sha1sum ${UTILSDIR}/android_tools/working/proprietary-files.{txt,sha1}
cat "${UTILSDIR}"/android_tools/working/proprietary-files.sha1 >>"$PROJECT_DIR"/working/"${UNZIP_DIR}"/proprietary-files.sha1

# Stash the changes done at ${UTILSDIR}/android_tools
git -C "${UTILSDIR}"/android_tools/ add --all
git -C "${UTILSDIR}"/android_tools/ stash

# copy file names
chown "$(whoami)" ./* -R
chmod -R u+rwX ./* #ensure final permissions
find "$PROJECT_DIR"/working/"${UNZIP_DIR}" -type f -printf '%P\n' | sort | grep -v ".git/" >"$PROJECT_DIR"/working/"${UNZIP_DIR}"/all_files.txt

if [[ -n $GIT_OAUTH_TOKEN ]]; then
	GITPUSH=(git push https://"$GIT_OAUTH_TOKEN"@github.com/$ORG/"${repo,,}".git "$branch")
	curl --silent --fail "https://raw.githubusercontent.com/$ORG/$repo/$branch/all_files.txt" 2>/dev/null && echo "Firmware already dumped!" && exit 1
	git init
	git config --global user.email kizziama@proton.me
	git config --global user.name Kizziama
	git config http.postBuffer 157286400
	curl -s -X POST -H "Authorization: token ${GIT_OAUTH_TOKEN}" -d '{ "name": "'"$repo"'" }' "https://api.github.com/orgs/${ORG}/repos" #create new repo
	curl -s -X PUT -H "Authorization: token ${GIT_OAUTH_TOKEN}" -H "Accept: application/vnd.github.mercy-preview+json" -d '{ "names": ["'"$manufacturer"'","'"$platform"'","'"$top_codename"'"]}' "https://api.github.com/repos/${ORG}/${repo}/topics"
	git remote add origin https://github.com/$ORG/"${repo,,}".git
	git checkout -b "$branch"
	find . -size +97M -printf '%P\n' -o -name "*sensetime*" -printf '%P\n' -o -name "*.lic" -printf '%P\n' >|.gitignore
	compressed_files=()
	while IFS= read -r file_path; do
		if [ -f "$file_path" ]; then
			if [[ "$file_path" == *"$pattern"* ]]; then
				compressed_file="${file_path}.xz"
				zstd --ultra -22 --long -M512 -T0 --format=xz "$file_path" -o "$compressed_file"
				file_size=$(du -b "$compressed_file" | cut -f1)
				if [ "$file_size" -le $((99 * 1024 * 1024)) ]; then # 99M
					compressed_files+=("$compressed_file")
				else
					rm -rf "${compressed_file}"
				fi
			fi
		fi
	done <.gitignore
	printf '%s\n' "${compressed_files[@]}" >compressed_files.txt
	cat >extract_files.sh <<'EOF'
#!/bin/bash

while IFS= read -r file; do
    unzstd "$file"
done < compressed_files.txt
EOF
	chmod +x extract_files.sh
	git add --all
	git commit -asm "Add ${description}"
	git update-ref -d HEAD
	git reset system/ vendor/ product/
	git checkout -b "$branch"
	git commit -asm "Add extras for ${description}" && "${GITPUSH[@]}"
	git add vendor/
	git commit -asm "Add vendor for ${description}" && "${GITPUSH[@]}"
	git add system/system/app/ || git add system/app/
	git commit -asm "Add system app for ${description}" && "${GITPUSH[@]}"
	git add system/system/priv-app/ || git add system/priv-app/
	git commit -asm "Add system priv-app for ${description}" && "${GITPUSH[@]}"
	git add system/
	git commit -asm "Add system for ${description}" && "${GITPUSH[@]}"
	git add product/app/
	git commit -asm "Add product app for ${description}" && "${GITPUSH[@]}"
	git add product/priv-app/
	git commit -asm "Add product priv-app for ${description}" && "${GITPUSH[@]}"
	git add product/
	git commit -asm "Add product for ${description}" && "${GITPUSH[@]}"
else
	echo "Dump done locally."
	exit 1
fi

# Telegram channel
TG_TOKEN=$(<"$PROJECT_DIR"/.tgtoken)
if [[ -n "$TG_TOKEN" ]]; then
	CHAT_ID="@hopireika_dump"
	commit_head=$(git log --format=format:%H | head -n 1)
	commit_link="https://github.com/$ORG/$repo/commit/$commit_head"
	echo -e "Sending telegram notification"
	printf "<b>Brand: %s</b>" "$brand" >|"$PROJECT_DIR"/working/tg.html
	{
		printf "\n<b>Device: %s</b>" "$codename"
		printf "\n<b>Version:</b> %s" "$release"
		printf "\n<b>Fingerprint:</b> %s" "$fingerprint"
		printf "\n<b>GitHub:</b>"
		printf "\n<a href=\"%s\">Commit</a>" "$commit_link"
		printf "\n<a href=\"https://github.com/%s/%s/tree/%s/\">%s</a>" "$ORG" "$repo" "$branch" "$codename"
	} >>"$PROJECT_DIR"/working/tg.html
	TEXT=$(<"$PROJECT_DIR"/working/tg.html)
	curl -s "https://api.telegram.org/bot${TG_TOKEN}/sendmessage" --data "text=${TEXT}&chat_id=${CHAT_ID}&parse_mode=HTML&disable_web_page_preview=True" >/dev/null
	rm -rf "$PROJECT_DIR"/working/tg.html
fi
