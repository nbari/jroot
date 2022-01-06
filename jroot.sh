#!/bin/sh
# ----------------------------------------------------------------------------
# jroot
# requires devel/ccache
# ----------------------------------------------------------------------------

FREEBSD_VERSION=13
NUMBER_OF_CORES=`sysctl -n hw.ncpu`
START=$(date +%s)

set_defaults() {
    ZPOOL="zroot"
    JAIL_NAME="test"
}

write() {
    NOW=$(date +%s)
    DIFF=$(echo "$NOW - $START" | bc)
    ELAPSED=$(printf '%02dh:%02dm:%02ds\n' $(($DIFF/3600)) $(($DIFF%3600/60)) $(($DIFF%60)))
    echo -e '\e[0;32m'
    cat <<-EOF
#----------------------------------------------------------------------------
# [${ELAPSED}] $1
#----------------------------------------------------------------------------
EOF
    echo -e '\e[0m'
}

build() {
    # echo "Fetching src-jail.conf"
    if [ -f /etc/src-jail.conf ]; then
        fetch -a https://raw.githubusercontent.com/nbari/jroot/master/src-jail.conf -o /etc/src-jail.conf -i /etc/src-jail.conf
    else
        fetch -a https://raw.githubusercontent.com/nbari/jroot/master/src-jail.conf -o /etc/src-jail.conf
    fi

    write "Creating /jroot datasets"
    set +e
    zfs create -o mountpoint=/jroot ${ZPOOL}/jroot
    zfs create -p ${ZPOOL}/jroot/build/obj
    zfs create ${ZPOOL}/jroot/releases
    set -e
    zfs set exec=on ${ZPOOL}/tmp

    write "Updating sources FreeBSD: ${FREEBSD_VERSION}"
    cd /usr/src
    git checkout stable/${FREEBSD_VERSION} && git pull
    REV=$(git rev-parse --short HEAD)

    if [ -d "/jroot/releases/base-${REV}" ]; then
        write "${REV} - already built"
        exit 1
    fi

    write "Creating ${ZPOOL}/jroot/releases/base-${REV}"
    zfs create -p ${ZPOOL}/jroot/releases/base-${REV}/var

    write "${REV} - building"
    env MAKEOBJDIRPREFIX=/jroot/build/obj SRCCONF=/etc/src-jail.conf __MAKE_CONF=/etc/make.conf make -j${NUMBER_OF_CORES} buildworld
    env MAKEOBJDIRPREFIX=/jroot/build/obj SRCCONF=/etc/src-jail.conf __MAKE_CONF=/etc/make.conf make DESTDIR=/jroot/releases/base-${REV} installworld 2>&1 | tee /tmp/${REV}-installworld.log
    env MAKEOBJDIRPREFIX=/jroot/build/obj SRCCONF=/etc/src-jail.conf __MAKE_CONF=/etc/make.conf make DESTDIR=/jroot/releases/base-${REV} distribution 2>&1 | tee /tmp/${REV}-distribution.log

    write "Creating ${ZPOOL}/jroot/releases/skel-${REV}"
    zfs create ${ZPOOL}/jroot/releases/skel-${REV}

    JAIL_PATH=/jroot/releases/base-${REV}
    SKEL_PATH=/jroot/releases/skel-${REV}

    cp /etc/localtime ${JAIL_PATH}/etc/localtime
    cp /etc/resolv.conf ${JAIL_PATH}/etc/resolv.conf

    write "Creating skeleton ${SKEL_PATH}"
    mv ${JAIL_PATH}/.cshrc ${SKEL_PATH}/.cshrc
    mv ${JAIL_PATH}/.profile ${SKEL_PATH}/.profile
    mv ${JAIL_PATH}/COPYRIGHT ${SKEL_PATH}/COPYRIGHT
    mv ${JAIL_PATH}/dev ${SKEL_PATH}/dev
    mv ${JAIL_PATH}/etc ${SKEL_PATH}/etc
    mv ${JAIL_PATH}/mnt ${SKEL_PATH}/mnt
    mv ${JAIL_PATH}/net ${SKEL_PATH}/net
    mv ${JAIL_PATH}/proc ${SKEL_PATH}/proc
    mv ${JAIL_PATH}/root ${SKEL_PATH}/root
    mv ${JAIL_PATH}/tmp ${SKEL_PATH}/tmp
    mkdir ${SKEL_PATH}/usr
    mv ${JAIL_PATH}/usr/local/ ${SKEL_PATH}/usr/local
    mv ${JAIL_PATH}/usr/obj ${SKEL_PATH}/usr/obj
    # works with kern_securelevel > 0
    (cd ${JAIL_PATH}/var && find . | cpio -pmud ${SKEL_PATH}/var)
    zfs destroy ${ZPOOL}/jroot/releases/base-${REV}/var

    # symlink the directories to the skeleton
    cd ${SKEL_PATH}
    mkdir jroot
    ln -s jroot/bin bin
    ln -s jroot/boot boot
    ln -s jroot/lib lib
    ln -s jroot/libexec libexec
    ln -s jroot/sbin sbin
    ln -s ../jroot/usr/bin usr/bin
    ln -s ../jroot/usr/include usr/include
    ln -s ../jroot/usr/lib usr/lib
    ln -s ../jroot/usr/libdata usr/libdata
    ln -s ../jroot/usr/libexec usr/libexec
    ln -s ../jroot/usr/sbin usr/sbin
    ln -s ../jroot/usr/share usr/share
    ln -s ../jroot/usr/src usr/src

    ISO8601=$(date -u +%FT%TZ)
    write "Creating snapshot ${ZPOOL}/jroot/releases/skel-${REV}@${ISO8601}"
    zfs snapshot ${ZPOOL}/jroot/releases/skel-${REV}@${ISO8601}

    echo "/jroot/releases/base-${REV}" > /jroot/build/latest-base
    echo "${ZPOOL}/jroot/releases/skel-${REV}@${ISO8601}" > /jroot/build/latest-skeleton

    zfs set exec=off ${ZPOOL}/tmp

    write "Done!"
}

create() {
    if [ -d "/jails/${JAIL_NAME}" ]; then
        write "${JAIL_NAME} - already exists"
        exit 1
    fi

    zfs create -o mountpoint=/jails ${ZPOOL}/jails

    if [ ! -s /jroot/build/latest-skeleton ]; then
        write "no skeleton found, run build first to create one"
        exit 1
    fi
    read -r SKELETON < /jroot/build/latest-skeleton

    write "Cloning  skeleton: ${SKELETON}"
    zfs clone ${SKELETON} ${ZPOOL}/jails/${JAIL_NAME}

    read -r BASE < /jroot/build/latest-base

    write "Creating /etc/fstab.${JAIL_NAME} with jail base: ${BASE}"
    echo "${BASE}	/jails/${JAIL_NAME}/jroot	nullfs	ro	0	0" > /etc/fstab.${JAIL_NAME}
}

usage() {
    set_defaults
    cat <<-EOF
Usage: $(basename "$0") build - creates a new jail base from source (depends on your system it may take hours to finish)
       $(basename "$0") create=name - create a jail
       $(basename "$0") update=name - update defined jail
       $(basename "$0") updateall - update all jails to latest release

Example: Build sources using zpool tank
       $(basename "$0") -z=tank build

         Create a jail named www and using zpool tank
       $(basename "$0") -z=tank create=www

Available pools:
$(zpool list)

Parameters:
    -h | --help)
        Show this help.
    -z | --zpool)
        ZFS pool to use
        Default: ${ZPOOL}
EOF
}

parse_args() {
    set_defaults
    SAFE_DELIMITER="$(printf "\a")"
    while [ "$1" != "" ]
    do
        PARAM=$(echo $1 | cut -f1 -d=)
        VALUE=$(echo $1 | sed "s/=/${SAFE_DELIMITER}/" | cut -f2 "-d${SAFE_DELIMITER}")
        case $PARAM in
            -h | --help)
                usage
                exit
                ;;
            build)
                build
                break
                ;;
            create)
                JAIL_NAME=${VALUE}
                create
                break
                ;;
            -z | --zpool)
                ZPOOL="${VALUE}"
                ;;
            *)
                echo "ERROR: Unknown parameter ${PARAM}"
                usage
                exit 1
        esac
        shift
    done
}

main() {
    if [ $# -eq 0 ]
    then
        usage
        exit
    fi
    parse_args $@
}

main $@

exit 0
