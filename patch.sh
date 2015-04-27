#!/usr/bin/env bash

PROJECT_DIR=$PWD

########## get argument-values
while getopts 'r:' OPTION ; do
case "${OPTION}" in
        r) PROJECT_DIR="${OPTARG}";;
        \?) echo; usage 1;;
    esac
done

if [ ! -f $PROJECT_DIR/app/Mage.php ]; then
    echo "Magento basedir not found. Please run ./patch.sh -r /path/to/magento/"
    exit 99
fi

MAGENTO_VERSION=$(grep 'function getVersionInfo\(\)' -A6 $PROJECT_DIR/app/Mage.php | sed s/[^0-9]//g | tr '\n' '.' | sed s/'\.\.*'// | sed s/'\.$'//)
echo "Your Magento version is $MAGENTO_VERSION"

export $(grep 'function getVersionInfo()' -A6 $PROJECT_DIR/app/Mage.php | grep = | sed s/,// | sed s/\>// | sed s/'[\t ]'//g | tr "a-z" "A-Z" | sed s/^/MAGENTO_/ | sed s/"'"//g)


# Some patches depend on other patches being applied first
# key: patchfile value: dependency (substring matched)
declare -A PATCH_DEPENDENCIES
PATCH_DEPENDENCIES=(
    ["1.7.0.0-1.8.1.0/PATCH_SUPEE-4334_EE_1.11.0.0-1.13.0.2_v1.sh"]="PATCH_SUPEE-1868_EE"
)

die()
{
    echo "$1"
    exit 1
}

msg()
{
    echo "--> $@"
}

ask()
{
	echo "$1"
	echo "Continue?"
	select yn in "Yes" "No"; do
        case $yn in
            Yes ) break;;
            No ) die; break;;
        esac
    done
}


# Compare version strings, returns true if greater or equal
# Taken from http://stackoverflow.com/a/24067243, modified for busybox
version_gt() { test "$(echo "$@" | tr " " "\n" | sort | tail -n 1)" == "$1"; }

# Returns 0 if given string contains given word. Does not match substrings.
#
# Arguments:
# 1: STRING
# 2: WORD
string_has_word() {
    regex="(^| )${2}($| )"
    if [[ "${1}" =~ $regex ]];then
        return 0
    else
        return 1
    fi
}

# Returns patches suitable for given $MAGE_VERSION
# 
# Arguments:
# 1: MAGE_VERSION
find_patches() {
    VERSION="${1}"
    PATCHES=()
    cd ${PATCHES_PATH}
    for PATCH_DIR in *; do
        PATCH_VERSION_RANGE=(${PATCH_DIR//-/ })
        LOWER_LIMIT=${PATCH_VERSION_RANGE[0]}
        UPPER_LIMIT=${PATCH_VERSION_RANGE[1]}

        if [ "${VERSION}" == "${LOWER_LIMIT}" ] || [ "${VERSION}" == "${UPPER_LIMIT}" ] || \
            (version_gt $VERSION ${LOWER_LIMIT} && ! version_gt $VERSION ${UPPER_LIMIT}); then

            for PATCH in $PATCH_DIR/*; do
                PATCHES+=($PATCH)
            done
        fi
    done
    printf -v PATCHES "%s " "${PATCHES[@]}"
    PATCHES=${PATCHES%?}

    PATCHES_SORTED=""
    # generate patch order
    for PATCH in $PATCHES; do
        check_patch_dependencies ${PATCH}
        if [ -z "$PATCHES_SORTED" ]; then
            PATCHES_SORTED="${PATCH}"
        else
            ! string_has_word "${PATCHES_SORTED}" ${PATCH} && PATCHES_SORTED+=" ${PATCH}"
        fi
    done
    echo "${PATCHES_SORTED}"
}

# Check patch dependencies and populate PATCHES_SORTED. Recursive.
#
# Arguments:
#
# 1: PATCH
check_patch_dependencies() {
    local PATCH="${1}"
    if [ ${PATCH_DEPENDENCIES[$PATCH]+abc} ] && [[ "${PATCHES}" =~ ${PATCH_DEPENDENCIES[$PATCH]} ]]; then
        regex=[[:space:]]?\([a-zA-Z0-9_\/\.\-]*${PATCH_DEPENDENCIES[$PATCH]}[a-zA-Z0-9_\/\.\-]*\)[[:space:]]?
        if [[ "${PATCHES}" =~ $regex ]]; then
            match="${BASH_REMATCH[1]}"
            # skip further checking if already processed
            if ! string_has_word "${PATCHES_SORTED}" ${PATCH}; then
                # check for further patch dependencies
                [ ${PATCH_DEPENDENCIES[$match]+abc} ] && check_patch_dependencies $match
                PATCHES_SORTED+=" ${match}";
            fi
        fi
    fi
}

#
# Download patches
#
if [ ! -d /tmp/magento-patches ]; then
	git clone https://github.com/edannenberg/mage-mirror.git /tmp/magento-patches
fi

#PROJECT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PATCHES_PATH="/tmp/magento-patches/patches"

PATCHES=$(find_patches ${MAGENTO_VERSION})
for PATCH in $PATCHES; do
	echo ${PATCH}
	PATCH_FILE=$(basename $PATCH)
	cp "${PATCHES_PATH}/${PATCH}" "./"
	if [[ "${PATCH_FILE}" == *.sh ]]; then
		PATCHER=("bash" "${PATCH_FILE}")
	else
		PATCHER=("patch" "-p1" "-i" "${PATCH_FILE}")
	fi
	"${PATCHER[@]}" || ask "error applying patch: ${PATCH}"
	rm "${PATCH_FILE}"
done
