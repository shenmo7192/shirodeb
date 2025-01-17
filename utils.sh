#!env bash

# This file provides functions could be used inside build.sh

# ===== Log =====

function log.color_output() {
    local color=$1
    shift 1

    echo >&2 -e "\033[${color}m$@\033[0m"
    return 0
}

# Log is named without prefix "utils." for convenience
# Usage: log.log <level> ...content
function log.log() {
    if [[ $# < 2 ]]; then
        return -1
    fi

    local level=$1
    shift 1

    case $level in
    error) log.color_output "0;31" "[ERROR] $@" ;;
    warn) log.color_output "1;33" "[WARN] $@" ;;
    info) log.color_output "1;37" "[INFO] $@" ;;
    debug) log.color_output "1;30" "[DEBUG] $@" ;;
    esac

    return 0
}

function log.error() { log.log "error" "$@"; }
function log.warn() { log.log "warn" $@; }
function log.info() { log.log "info" $@; }
function log.debug() { log.log "debug" $@; }

# ===== Desktop =====

# Edit desktop file entries using sed. Necessary escape for entry matching is needed for sed.
# Usage: utils.desktop.edit <Entry> <Value> <Desktop File>
function utils.desktop.edit() {
    local CONFIG_FILE="$3"
    sed -i "s#^\($1\)=.*#\1=$2#g" $CONFIG_FILE
    return $?
}

# Usage: utils.desktop.collect <search-root> [additional-find-parameters]
function utils.desktop.collect() {
    local SEARCH_ROOT="$1"
    local FIND_PARAM="$2"
    local DESKTOP_DIR=$APP_DIR/entries/applications
    mkdir -p $DESKTOP_DIR
    local desktop_files=($(find $SEARCH_ROOT $FIND_PARAM -name "*.desktop"))

    if [ ${#desktop_files[@]} -gt 0 ]; then
        local common=$({ for i in ${desktop_files[@]}; do echo $(basename ${i%.[^.]*}); done; } | sed -e 'N;s/^\(.*\).*\n\1.*$/\1\n\1/;D')
        common=$(basename $common)

        for desktop_file in ${desktop_files[@]}; do
            local filename=$(basename $desktop_file)
            local target_desktop_file="$DESKTOP_DIR/${filename/$common/$PACKAGE}"
            cp "$desktop_file" $target_desktop_file
            utils.desktop.edit "Icon" "$PACKAGE" $target_desktop_file
            utils.desktop.edit "Terminal" "false" $target_desktop_file
        done
    else
        echo "No desktop file found"
    fi
    return 0
}

# ===== Icon =====

# Convert svg icon to png.
# Usage: utils.icon.svg_to_png <filepath> [size=512]
function utils.icon.svg_to_png() {
    local PNG_FILE="$1"
    local SZ="${2:-512}"
    W=$(inkscape -W $PNG_FILE | cut -d'.' -f 1)
    H=$(inkscape -H $PNG_FILE | cut -d'.' -f 1)
    png_fn=${PNG_FILE/\.svg/\.png}
    if ((W > H)); then
        inkscape --export-png=$png_fn --export-dpi=96 --export-background-opacity=0 -w $SZ ${1}
    else
        inkscape --export-png=$png_fn --export-dpi=96 --export-background-opacity=0 -h $SZ ${1}
    fi
    convert $png_fn -background none -scale ${SZ}x${SZ} -gravity center -extent ${SZ}x${SZ} $png_fn
}

# Usage: utils.icon.collect <search-root> [additional-find-parameters]
function utils.icon.collect() {
    local SEARCH_ROOT="$1"
    local FIND_PARAM="$2"
    local ICON_DIR=$APP_DIR/entries/icons/hicolor/
    mkdir -p $ICON_DIR
    local svg_icons=($(find $SEARCH_ROOT $FIND_PARAM -name "*.svg"))
    local png_icons=($(find $SEARCH_ROOT $FIND_PARAM -name "*.png"))

    if [ ${#svg_icons[@]} -gt 0 ]; then
        mkdir -p $ICON_DIR/scalable/apps/
        # if [ ${#svg_icons[@]} -eq 1]; then
        # cp ${svg_icons[0]} $ICON_DIR/scalable/apps/${PACKAGE}.svg
        # else
        local common=$({ for i in ${svg_icons[@]}; do echo $(basename ${i%.[^.]*}); done; } | sed -e 'N;s/^\(.*\).*\n\1.*$/\1\n\1/;D')
        common=$(basename $common)
        for svg_icon in ${svg_icons[@]}; do
            local filename=$(basename $svg_icon)
            cp $svg_icon $ICON_DIR/scalable/apps/${filename/$common/$PACKAGE}
            cp $svg_icon $ICON_DIR/scalable/apps/$filename
        done
        # fi
    else
        if [ ${#png_icons[@]} -gt 0 ]; then
            local common=$({ for i in ${png_icons[@]}; do
                local j=$(basename $i)
                echo ${j%.[^.]*}
            done; } | sed -e 'N;s/^\(.*\).*\n\1.*$/\1\n\1/;D')
            common=$(basename $common)
            for png_icon in ${png_icons[@]}; do
                local filename=$(basename $png_icon)
                local sz=$(identify $png_icon | cut -d' ' -f 3 | cut -d'x' -f 1)
                if (($sz > 512)); then
                    sz=512
                    mkdir -p $ICON_DIR/${sz}x${sz}/apps
                    convert $png_icons -scale 512x512\! $ICON_DIR/${sz}x${sz}/apps/${filename/$common/$PACKAGE}
                    convert $png_icons -scale 512x512\! $ICON_DIR/${sz}x${sz}/apps/$filename
                else
                    mkdir -p $ICON_DIR/${sz}x${sz}/apps
                    cp $png_icons $ICON_DIR/${sz}x${sz}/apps/${filename/$common/$PACKAGE}
                    cp $png_icons $ICON_DIR/${sz}x${sz}/apps/$filename
                fi
            done
        else
            echo "No icon found under $SEARCH_ROOT"
        fi
    fi
}

# ===== Misc =====

# Find a file reverse up the file tree from current work dir
# Usage: utils.misc.find_up <filename>
function utils.misc.find_up() {
    local p=$(pwd)
    while [[ "$p" != "" && ! -e "$p/$1" ]]; do
        p=${p%/*}
    done
    echo "$p/$1"
    return 0
}

# Get current platform arch
function utils.misc.get_current_arch() {
    sed -e 's/x86_/amd/;s/aarch/arm/' <<<$(uname -m)
}

# Write postinst script for chrome-sandbox
function utils.misc.chrome_sandbox_treat() {
    # Check whether a chrome-sandbox existed
    local chrome_sandboxes=($(find ${APP_DIR}/files -name "chrome-sandbox"))

    if [ ${#chrome_sandboxes[@]} -eq 0 ]; then
        return 0
    fi

    local POSTINST="${PKG_DIR}/debian/postinst"
    if [[ ! -f $POSTINST ]]; then
        cat <<EOF >$POSTINST
#!/bin/bash

EOF
    fi

    cat <<EOF >$POSTINST
# SUID chrome-sandbox for Electron 5+ with Kernel 4.19
EOF

    for chrome_sandbox in ${chrome_sandboxes[@]}; do
        cat <<EOF >$POSTINST
chmod 4755 '/opt/apps/${PACKAGE}/files/${chrome_sandbox#${APP_DIR}/files/}' || true
EOF
    done

    chmod +x ${PKG_DIR}/debian/postinst
}

# Export Control fields from an existing control file
function utils.misc.read_control_from() {
    local ORIG_CONTROL_FILE="$1"

    export DESC1=$(cat ${ORIG_CONTROL_FILE} | grep -oP "Description: \K(.*)$")
    export DESC2=$(cat ${ORIG_CONTROL_FILE} | grep -oP "^ \K(.*)$")
    export DEPENDS=$(cat ${ORIG_CONTROL_FILE} | grep -oP "^Depends: \K(.*)$")
    export HOMEPAGE=$(cat ${ORIG_CONTROL_FILE} | grep -oP "^Homepage: \K(.*)$" | sed "s/\\#/\\\\#/")
    export SECTION=$(cat ${ORIG_CONTROL_FILE} | grep -oP "^Section: \K(.*)$")
    export PROVIDES=$(cat ${ORIG_CONTROL_FILE} | grep -oP "^Provides: \K(.*)$")

    return 0
}
