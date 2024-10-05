#!/bin/bash

set -ue

# Variables for image size
IMG_WIDTH=1920
IMG_HEIGHT=1080
RENDER_MOV=true
COPY_PNG=false
DEBUG_MODE=false  # Default value for debug mode
VERBOSE=false  # Default value for verbose mode

# Function to display progress bar
show_progress() {
    local PROG=$1
    local TOTAL=$2
    local BAR_WIDTH=40
    local FILLED_WIDTH=$((PROG * BAR_WIDTH / TOTAL))
    local EMPTY_WIDTH=$((BAR_WIDTH - FILLED_WIDTH))
    
    printf "\r["
    printf "%0.s#" $(seq 1 $FILLED_WIDTH)
    printf "%0.s " $(seq 1 $EMPTY_WIDTH)
    printf "] $PROG/$TOTAL"
}

# Function for verbose logging, also shows progress bar update
log() {
    local msg="$1"
    local prog=$2
    local total=$3

    if [ "$VERBOSE" = true ]; then
        echo "$msg"
    fi

    # Always show the progress bar with the log message
    show_progress $prog $total
    printf " - %s\n" "$msg"
}

# Check for command line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --debug) DEBUG_MODE=true ;;
        --verbose) VERBOSE=true ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

log "Starting script..." 0 1

if [ "$COPY_PNG" = true ]; then
    log "Removing all .png files in the current directory..." 0 1
    find . -type f -name "*.png" -exec rm -f {} \;
fi

if [ -z "$(docker --version)" ]; then
	echo "Docker is not installed. Please install docker before running this script."
	exit 1
fi

log "Pulling necessary Docker images..." 0 1
docker pull spuder/stl2origin:latest || { echo "Error pulling spuder/stl2origin"; exit 1; }
docker pull linuxserver/ffmpeg:version-4.4-cli || { echo "Error pulling linuxserver/ffmpeg"; exit 1; }
docker pull openscad/openscad:2021.01 || { echo "Error pulling openscad"; exit 1; }

# Find all STL files and count them
stl_files=( $(find ~+ -type f -name "*.stl") )
total_files=${#stl_files[@]}

log "Found $total_files STL files to process." 0 $total_files

# Exit if no STL files are found
if [ $total_files -eq 0 ]; then
    echo "No STL files found. Exiting."
    exit 1
fi

# Counter to limit to a single STL file if DEBUG_MODE is enabled
file_counter=0

for file in "${stl_files[@]}"; do 

    # Process only one file if DEBUG_MODE is enabled
    if [ "$DEBUG_MODE" = true ] && [ "$file_counter" -ge 1 ]; then
        log "DEBUG_MODE is enabled. Processing only the first file." $file_counter $total_files
        break
    fi

    file_counter=$((file_counter + 1))

    filename=$(basename "$file" ".stl")
    dirname=$(dirname "$file")
    gif_path="${dirname}/${filename}.gif"
    mov_path="${dirname}/${filename}.mov"

    # Log the current file being processed
    log "Processing file $file ($file_counter/$total_files)" $file_counter $total_files

    # Generate random file name for temporary files
    RANDOM_FILENAME=$(mktemp -u "tempfile_XXXXXX")

    log "Reading $file" $file_counter $total_files
    MYTMPDIR="$(mktemp -d)"
    trap 'rm -rf -- "$MYTMPDIR"' EXIT || { echo "Failed to set cleanup trap"; exit 1; }
    log "Creating temp directory ${MYTMPDIR}" $file_counter $total_files

    # Create unique docker volumes for each file
    INPUT_VOLUME="stl2gif-input-${filename}"
    OUTPUT_VOLUME="stl2gif-output-${filename}"

    log "Creating temporary docker volumes ${INPUT_VOLUME} and ${OUTPUT_VOLUME}" $file_counter $total_files
    docker volume create --name ${INPUT_VOLUME} > /dev/null 2>&1 || { echo "Error creating input volume"; exit 1; }
    INPUT_ID=$(docker run -d -v ${INPUT_VOLUME}:/input busybox true 2>&1) || { echo "Error creating input container"; exit 1; }
    docker volume create --name ${OUTPUT_VOLUME} > /dev/null 2>&1 || { echo "Error creating output volume"; exit 1; }
    OUTPUT_ID=$(docker run -d -v ${OUTPUT_VOLUME}:/output busybox true 2>&1) || { echo "Error creating output container"; exit 1; }

    log "Copying ${filename}.stl to ${INPUT_VOLUME} docker volume" $file_counter $total_files
	docker cp "${dirname}/${filename}.stl" "${INPUT_ID}:/input/${filename}.stl" || { echo "Error copying STL file to Docker"; exit 1; }

    log "Detecting ${filename} offset from origin" $file_counter $total_files
    
    docker run \
        -e OUTPUT_STDOUT=true \
        -e OUTPUT_BASH_FILE=/output/foo.sh \
        -v ${INPUT_VOLUME}:/input \
        -v ${OUTPUT_VOLUME}:/output \
        --rm spuder/stl2origin:latest "/input/${filename}.stl" > /dev/null 2>&1 || { echo "Error running stl2origin container"; exit 1; }

    docker cp "${OUTPUT_ID}:/output/foo.sh" "${MYTMPDIR}/${RANDOM_FILENAME}.sh" || { echo "Error copying output from stl2origin"; exit 1; }

    source ${MYTMPDIR}/${RANDOM_FILENAME}.sh

    log "Duplicating ${filename} and centering object at origin" $file_counter $total_files
    docker run \
        --rm \
        -v ${INPUT_VOLUME}:/input \
        -v ${OUTPUT_VOLUME}:/output \
        openscad/openscad:2021.01 openscad /dev/null -D "translate([$XTRANS-$XMID,$YTRANS-$YMID,$ZTRANS-$ZMID])import(\"/input/${filename}.stl\");" -o "/output/${RANDOM_FILENAME}-centered.stl" > /dev/null 2>&1 || { echo "Error running OpenSCAD"; exit 1; }
    docker cp "${OUTPUT_ID}:/output/${RANDOM_FILENAME}-centered.stl" "${MYTMPDIR}/${RANDOM_FILENAME}-centered.stl" || { echo "Error copying centered STL file"; exit 1; }

    log "Converting ${filename} into 360 degree .png files" $file_counter $total_files
    openscad_path=$(which openscad || echo "/Applications/OpenSCAD.app/Contents/MacOS/OpenSCAD")
    
    openscad_version=$($openscad_path -v 2>&1 | grep -o '\d\d\d\d')
    if [ "$openscad_version" -lt "2021" ]; then
        echo "OpenSCAD 2021.01 or later is required to run this script. Please update openscad."
        exit 1
    fi

    if [ ! -f "$HOME/Documents/OpenSCAD/libraries/hsvtorgb.scad" ]; then
        log "hsvtorgb.scad is not installed. Installing" $file_counter $total_files
        mkdir -p "$HOME/Documents/OpenSCAD/libraries"
        cp lib/hsvtorgb.scad "$HOME/Documents/OpenSCAD/libraries/hsvtorgb.scad"
    fi

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
        --quiet > /dev/null 2>&1 || { echo "Error rendering PNG with OpenSCAD"; exit 1; }

    if [ "$COPY_PNG" = true ]; then
        log "Copying .PNG frames to host folder" $file_counter $total_files
        find ${MYTMPDIR} -type f -name "${RANDOM_FILENAME}*.png" -print0 | while read -d '' -r png_file; do 
            cp "${png_file}" "${dirname}/"
        done
    fi

    log "Copying .png files to docker volume" $file_counter $total_files
    find ${MYTMPDIR} -type f -name "${RANDOM_FILENAME}*.png" -print0 | while read -d '' -r file; do 
        docker cp "${file}" "${INPUT_ID}:/input/" || { echo "Error copying PNG files to Docker"; exit 1; }
    done

    log "Converting ${filename} .PNG files into .GIF" $file_counter $total_files
    docker run --rm \
        -v ${INPUT_VOLUME}:/input \
        -v ${OUTPUT_VOLUME}:/output \
        linuxserver/ffmpeg:version-4.4-cli -y -framerate 60 -pattern_type glob -i 'input/*.png' -vf "scale=1024:-1,transpose=1" "/output/${filename}.gif" > /dev/null 2>&1 || { echo "Error creating GIF with ffmpeg"; exit 1; }

    docker run --rm \
        -v ${OUTPUT_VOLUME}:/output \
        linuxserver/ffmpeg:version-4.4-cli -i "/output/${filename}.gif" -vf "select='lte(n\,60)',setpts=N/FRAME_RATE/TB" -r 30 "/output/${filename}_cropped.gif" > /dev/null 2>&1 || { echo "Error cropping GIF"; exit 1; }

    docker cp "${OUTPUT_ID}:/output/${filename}_cropped.gif" "${gif_path}" || { echo "Error copying cropped GIF"; exit 1; }

    if [ "$RENDER_MOV" = true ]; then
        log "Converting ${filename} .GIF to .MOV" $file_counter $total_files
        docker run --rm \
            -v ${INPUT_VOLUME}:/input \
            -v ${OUTPUT_VOLUME}:/output \
            linuxserver/ffmpeg:version-4.4-cli -y -i "/output/${filename}_cropped.gif" -movflags faststart -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" -pix_fmt yuv420p "/output/${filename}.mov" > /dev/null 2>&1 || { echo "Error converting GIF to MOV"; exit 1; }
        docker cp "${OUTPUT_ID}:/output/${filename}.mov" "${mov_path}" || { echo "Error copying MOV file"; exit 1; }
    fi

    log "Cleaning up temp directory and Docker resources for ${filename}" $file_counter $total_files
    rm -rf -- "${MYTMPDIR}" || { echo "Error cleaning up temp directory"; exit 1; }

    # Clean up Docker containers and volumes
    docker rm $INPUT_ID > /dev/null 2>&1 || { echo "Error removing Docker input container"; exit 1; }
    docker rm $OUTPUT_ID > /dev/null 2>&1 || { echo "Error removing Docker output container"; exit 1; }
    docker volume rm ${INPUT_VOLUME} > /dev/null 2>&1 || { echo "Error removing Docker input volume"; exit 1; }
    docker volume rm ${OUTPUT_VOLUME} > /dev/null 2>&1 || { echo "Error removing Docker output volume"; exit 1; }

    # Display progress bar
    show_progress $file_counter $total_files
done

log "Process completed!" $file_counter $total_files
