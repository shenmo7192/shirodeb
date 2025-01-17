#!env bash

# Get dirname of what
function dir() {
    if [[ -z "$1" ]]; then
        echo $ROOT_DIR
    else
        local d
        case $1 in
        src) d=$SRC_DIR ;;
        pkg) d=$PKG_DIR ;;
        download*) d=$DOWNLOAD_DIR ;;
        output) d=$OUTPUT_DIR ;;
        app) d=$APP_DIR ;;
        esac
        echo $d
    fi
    return 0
}

# Install&Uninstall Packed applications
function install() {
    local result_file="$OUTPUT_DIR/$VERSION/${PACKAGE}_${VERSION}_$ARCH.deb"
    if [[ ! -f $result_file ]]; then
        log.error "You have not make it yet."
        exit -1
    fi
    sudo apt install $result_file
}

function remove() {
    sudo apt remove -y $PACKAGE
}

# Save it for uploading
function save() {
    local result_file="$OUTPUT_DIR/$VERSION/${PACKAGE}_${VERSION}_$ARCH.deb"
    if [[ ! -f $result_file ]]; then
        log.error "You have not make it yet."
        exit -1
    fi

    if [[ $DEB_UPLOAD_PATH == "" ]]; then
        log.error "You have not specify DEB_UPLOAD_PATH."
        exit -1
    fi

    local upload_path=$DEB_UPLOAD_PATH/$PACKAGE/$ARCH/
    mkdir -p $upload_path
    log.debug "Copy $result_file to $upload_path"
    cp "$result_file" "$upload_path"

    # save icon if not saved already
    if [[ ! -f $upload_path/../icon.svg || ! -f $upload_path/../icon.png ]]; then
        local ICON_DIR=$APP_DIR/entries/icons/hicolor/
        local svg_icon="$ICON_DIR/scalable/apps/$PACKAGE.svg"

        if [[ -f $svg_icon ]]; then
            cp $svg_icon $upload_path/../icon.svg
            utils.icon.svg_to_png $upload_path/../icon.svg
            rm $upload_path/../icon.svg
        else
            sz=$(/usr/bin/ls -1r ${ICON_DIR}/ | head -1)

            png_icon=${ICON_DIR}/$sz/apps/${PACKAGE}.png
            if [[ -f $png_icon ]]; then
                cp $png_icon $upload_path/../icon.png
            else
                log.warn "No icon image found."
            fi
        fi
    fi

    # save some information
    if [[ -z $HOMEPAGE ]]; then
        local HOMEPAGE=$(dpkg --field $result_file Homepage)
    fi
    if [[ -z $DESC1 ]]; then
        local DESC1=$(dpkg --field $result_file | grep -oP "Description: \K(.*)$")
    fi
    if [[ -z $DESC2 ]]; then
        local DESC2=$(dpkg --field $result_file | grep -oP "^ \K(.*)$")
    fi

    if [[ -z $AUTHOR && $HOMEPAGE == "https://github.com/"* ]]; then
        local AUTHOR=$(echo $HOMEPAGE | grep -oP "github.com/\K[^/]*")
    fi

    cat <<EOF >$upload_path/../info.txt
${NAME}
${HOMEPAGE}
${AUTHOR}
${DESC1}
${DESC2}
EOF

    log.info "Saved, please fill screenshot manually"
    return 0
}

# Start a new project from templates
function start() {
    if [[ $1 != "" && -d $TEMPLATES_ROOT/boilerplates/$1 ]]; then
        echo "Using boilerplates $1"
        local boilerplate=$TEMPLATES_ROOT/boilerplates/$1
    else
        local boilerplate=$TEMPLATES_ROOT/boilerplates/raw
    fi

    echo -n "Enter App ID: "
    read appid
    mkdir -p $appid

    cp ${boilerplate}/* $appid/
    sed -i "s/<appid>/$appid/" $appid/build.sh
    return 0
}

# Remove files
function clean() {
    rm -rf "$ROOT_DIR/src" "$ROOT_DIR/pkg" "$DOWNLOAD_DIR" "$OUTPUT_DIR"
    return 0
}

function purge() {
    local LOCAL_DD=${LOCAL_DOWNLOAD_DIR:-${DOWNLOAD_DIR}}

    for url in ${URL[@]}; do
        local download_filename

        if [[ "$url" =~ "::" ]]; then
            # Url is provided with preferred filename
            download_filename=$(awk -F '::' '{print $1}' <<<$url)
        else
            download_filename=$(basename $url)
        fi

        rm -rf $DOWNLOAD_DIR/$download_filename
        rm -rf $LOCAL_DD/$download_filename
    done
    return 0
}

# Download files
function download() {
    __internal.download "${URL[@]}"
}

# Build it
function __internal.make.stage1() {
    UNARCHIVED_SRC_DIRS=() # build.sh could use it

    download
    local downloaded_files="${ret[@]}"

    # unarchive source
    for downloaded_file in ${downloaded_files[@]}; do
        __internal.unar "$downloaded_file" "$SRC_DIR"
        UNARCHIVED_SRC_DIRS[${#UNARCHIVED_SRC_DIRS[@]}]=$ret
    done
    unset ret

    # build "debian"
    pushd "$PKG_DIR"
    dh_make --createorig -s -n -y >/dev/null || exit -1

    # rm unused files
    rm debian/*.ex debian/*.EX
    rm -rf debian/*.docs debian/README debian/README.*
    rm -rf debian/copyright

    # copy template
    cp -R $TEMPLATES_ROOT/debian/* debian/

    # build uos specified structure
    mkdir -p ${APP_DIR}/entries
    mkdir -p ${APP_DIR}/files

    # build info json
    cat $TEMPLATES_ROOT/info |
        jq "$(echo $REQUIRED_PERMISSIONS | awk -F, 'BEGIN{ORS=" | "} {for (i=1;i<=NF;i++){print ".permissions." $i " = true"}}' | sed 's/ | $//')" |
        jq '.appid = "'${PACKAGE}'" | .name = "'"${NAME}"'" | .version = "'${VERSION}'" | .arch[0] = "'${ARCH}'"' \
            >${APP_DIR}/info
    popd
}

function __internal.make.stage2() {
    pushd "$PKG_DIR"
    if [[ $ARCH == "all" ]]; then
        fakeroot dpkg-buildpackage -us -uc -b -tc
    else
        fakeroot dpkg-buildpackage -us -uc -b -tc --host-arch $ARCH
    fi

    [[ $? == 0 ]] || exit -1

    # copy to output
    mkdir -p $OUTPUT_DIR/$VERSION
    mv ../${PACKAGE}_${VERSION}_$ARCH.* $OUTPUT_DIR/$VERSION/

    # done
    log.info "Finish, the output is under $OUTPUT_DIR/$VERSION/"

    popd
}

function make() {
    local ONLY_STAGE_1=0
    local ONLY_STAGE_2=0
    local NO_BUILD=0

    if [[ $1 == "--no-build" ]]; then
        NO_BUILD=1
        log.info "Will not executing build function."
        shift 1
    fi

    if [[ $1 == "--stage1" ]]; then
        ONLY_STAGE_1=1
        log.info "Only build file structure and not package into .deb file."
        shift 1
    elif [[ $1 == "--stage2" ]]; then
        ONLY_STAGE_2=1
        log.info "Only package into .deb file and not touch file structure."
        shift 1
    fi

    if [[ $1 == "--no-build" ]]; then
        NO_BUILD=1
        log.info "Will not executing build function."
        shift echo $BUILD_SH1
    fi

    log.info "Building file structure"

    rm -rf "${PKG_DIR}"
    mkdir -p ${PKG_DIR}

    if [[ $ONLY_STAGE_2 != 1 ]]; then
        __internal.make.stage1
    fi

    if [[ $NO_BUILD != 1 ]]; then
        log.info "Execute build function"
        build $@
    fi

    # apply control.patch
    pushd $PKG_DIR/debian/
    envsubst <${TEMPLATES_ROOT}/control.patch | tee result.patch | patch -p0
    [[ $? == 0 ]] || exit -1
    if [[ -z $DESC2 ]]; then
        sed -i "s#<DESC2>##g" control
    else
        if [ $(echo -e "$DESC2" | wc -l) = 1 ]; then
            local _DESC2=" $DESC2"
        else
            local _DESC2=$(echo -e "$DESC2" | sed ':a;N;$!ba;s/\n/\\n\\ /g;s/^/\\ /g')
        fi
        sed -i "s#<DESC2>#$_DESC2#g" control
    fi
    popd

    if [[ $ONLY_STAGE_1 != 1 ]]; then
        __internal.make.stage2
    fi

    return 0
}
