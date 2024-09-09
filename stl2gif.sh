#!/bin/bash

set -ue

# Variables for image size
IMG_WIDTH=1920
IMG_HEIGHT=1080
RENDER_MOV=true
COPY_PNG=false

if [ "$COPY_PNG" = true ]; then
    echo "Removing all .png files in the current directory..."
    find . -type f -name "*.png" -exec rm -f {} \;  
fi

if [ -z "$(docker --version)" ]; then
	echo "Docker is not installed. Please install docker before running this script."
	exit 1
fi

docker pull spuder/stl2origin:latest
docker pull linuxserver/ffmpeg:version-4.4-cli
docker pull openscad/openscad:2021.01

echo "Creating temporary docker volumes stl2gif-input and stl2gif-output"
docker volume create --name stl2gif-input
INPUT_ID=$(docker run -d -v stl2gif-input:/input busybox true)
docker volume create --name stl2gif-output
OUTPUT_ID=$(docker run -d -v stl2gif-output:/output busybox true)

find ~+ -type f -name "*.stl" -print0 | while read -d '' -r file; do 

    filename=$(basename "$file" ".stl")
    dirname=$(dirname "$file")
    gif_path="${dirname}/${filename}.gif"
    mov_path="${dirname}/${filename}.mov"

    # Generate random file name for temporary files
    RANDOM_FILENAME=$(mktemp -u "tempfile_XXXXXX")

    echo "Reading $file"
    MYTMPDIR="$(mktemp -d)"
    trap 'rm -rf -- "$MYTMPDIR"' EXIT
    echo "Creating temp directory ${MYTMPDIR}"

    echo "Copying ${filename}.stl to stl2gif-input docker volume"
	docker cp "${dirname}/${filename}.stl" "${INPUT_ID}:/input/${filename}.stl"

    echo ""
    echo "Detecting ${filename} offset from origin"
    echo "========================================"

    # Fixed filename 'foo.sh' inside container
    docker run \
        -e OUTPUT_STDOUT=true \
        -e OUTPUT_BASH_FILE=/output/foo.sh \
        -v stl2gif-input:/input \
        -v stl2gif-output:/output \
        --rm spuder/stl2origin:latest \
        "/input/${filename}.stl"

    # Copy from 'foo.sh' and then rename it to the random filename
	docker cp "${OUTPUT_ID}:/output/foo.sh" "${MYTMPDIR}/${RANDOM_FILENAME}.sh"

    source ${MYTMPDIR}/${RANDOM_FILENAME}.sh
    cat ${MYTMPDIR}/${RANDOM_FILENAME}.sh

    echo ""
    echo "Duplicating ${filename} and centering object at origin"
    echo "======================================================"
    docker run \
        --rm \
        -v stl2gif-input:/input \
        -v stl2gif-output:/output \
        openscad/openscad:2021.01 openscad /dev/null -D "translate([$XTRANS-$XMID,$YTRANS-$YMID,$ZTRANS-$ZMID])import(\"/input/${filename}.stl\");" -o "/output/${RANDOM_FILENAME}-centered.stl"
    docker cp "${OUTPUT_ID}:/output/${RANDOM_FILENAME}-centered.stl" "${MYTMPDIR}/${RANDOM_FILENAME}-centered.stl"

    echo ""
    echo "Converting ${filename} into 360 degree .png files"
    echo "=================================================="
    openscad_path=""
    if [ ! -z "$(which openscad)" ]; then
        openscad_path=$(which openscad)
    elif [ -f "/Applications/OpenSCAD.app/Contents/MacOS/OpenSCAD" ]; then
        openscad_path='/Applications/OpenSCAD.app/Contents/MacOS/OpenSCAD'
    else
        echo "OpenSCAD is not installed. Please install openscad before running this script."
        exit 1
    fi

    openscad_version=$($openscad_path -v 2>&1 | grep -o '\d\d\d\d')
    if [ "$openscad_version" -lt "2021" ]; then
        echo "OpenSCAD 2021.01 or later is required to run this script. Please update openscad before running this script."
        exit 1
    fi

    if [ ! -f "$HOME/Documents/OpenSCAD/libraries/hsvtorgb.scad" ]; then
        echo "hsvtorgb.scad is not installed. Installing"
        mkdir -p "$HOME/Documents/OpenSCAD/libraries"
        cp lib/hsvtorgb.scad "$HOME/Documents/OpenSCAD/libraries/hsvtorgb.scad"
    fi

    # @see https://en.wikibooks.org/wiki/OpenSCAD_User_Manual/Other_Language_Features#Viewport:_$vpr,_$vpt,_$vpf_and_$vpd
    $openscad_path /dev/null \
        -D '$vpr = [0, 60, 360 * $t];' \
        -D '$vpd = 1000;' \
        -D '$vpf = 10;' \
        -o "${MYTMPDIR}/${RANDOM_FILENAME}.png"  \
        -D "color([68/255, 127/255, 244/255]) import(\"${MYTMPDIR}/${RANDOM_FILENAME}-centered.stl\");" \
        --imgsize=${IMG_WIDTH},${IMG_HEIGHT} \
        --projection=perspective \
        --viewall \
        --camera '0,0,0,0,0,360 * $t,0' \
        --animate 60 \
        --preview \
        --colorscheme "Starnight" \
        --quiet

    if [ "$COPY_PNG" = true ]; then
        echo ""
        echo "Copying .PNG frames to host folder"
        echo "=================================="
        find ${MYTMPDIR} -type f -name "${RANDOM_FILENAME}*.png" -print0 | while read -d '' -r png_file; do 
            cp "${png_file}" "${dirname}/"
        done
    fi
    
    echo ""
    echo "Copying .png files to docker volume"
    find ${MYTMPDIR} -type f -name "${RANDOM_FILENAME}*.png" -print0 | while read -d '' -r file; do 
        docker cp "${file}" "${INPUT_ID}:/input/" 
    done

    echo ""
    echo "Deleting existing GIF if it exists"
    if [ -f "$gif_path" ]; then
        rm -f "$gif_path"
    fi

    echo "Converting ${filename} .PNG files into .GIF and rotating 90° to the right"
    echo "==========================================="
    docker run --rm \
        -v stl2gif-input:/input \
        -v stl2gif-output:/output \
        linuxserver/ffmpeg:version-4.4-cli -y -framerate 60 -pattern_type glob -i 'input/*.png' -vf "scale=512:-1,transpose=1" "/output/${filename}.gif";
        

    # Crop the GIF to 60 frames
    docker run --rm \
        -v stl2gif-output:/output \
        linuxserver/ffmpeg:version-4.4-cli -i "/output/${filename}.gif" -vf "select='lte(n\,60)',setpts=N/FRAME_RATE/TB" -r 30 "/output/${filename}_cropped.gif"


    docker cp "${OUTPUT_ID}:/output/${filename}_cropped.gif" "${gif_path}"

    if [ "$RENDER_MOV" = true ]; then
        echo ""
        echo "Deleting existing MOV if it exists"
        if [ -f "$mov_path" ]; then
            rm -f "$mov_path"
        fi

        echo "Converting ${filename} .GIF to .MOV"
        echo "==================================="
        docker run --rm \
            -v stl2gif-input:/input \
            -v stl2gif-output:/output \
            linuxserver/ffmpeg:version-4.4-cli -y -i "/output/${filename}_cropped.gif" -movflags faststart -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" -pix_fmt yuv420p "/output/${filename}.mov";
        docker cp "${OUTPUT_ID}:/output/${filename}.mov" "${mov_path}"
    fi

    ls "${MYTMPDIR}"
    echo ""
    echo "Cleaning up temp directory ${MYTMPDIR}"
    echo "======================================"
    rm -rf -- "${MYTMPDIR}"
done

docker rm $INPUT_ID
docker rm $OUTPUT_ID
docker volume rm stl2gif-input
docker volume rm stl2gif-output