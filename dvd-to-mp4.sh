#!/bin/bash

# --- CONFIGURATION ---
FFMPEG_BIN="ffmpeg"
FFPROBE_BIN="ffprobe"
# ---------------------

if [ -z "$1" ]; then
    echo "Usage: ./dvd-to-mp4.sh /d/VIDEO_TS"
    exit 1
fi

# Ensure path doesn't have a trailing slash
VIDEO_TS_DIR="${1%/}"
OUTPUT_DIR=$(pwd)

echo "Scanning $VIDEO_TS_DIR for video titles..."

# Loop through every Title Set's first file (VTS_01_1.VOB, VTS_02_1.VOB, etc.)
for FIRST_VOB in "$VIDEO_TS_DIR"/VTS_*_1.VOB; do
    [ -e "$FIRST_VOB" ] || continue
    
    # Extract the base title name (e.g., "VTS_01")
    FILENAME=$(basename "$FIRST_VOB")
    TITLE_PREFIX="${FILENAME%_1.VOB}"
    
    echo "=================================================="
    echo "Processing Title Set: $TITLE_PREFIX"

    # 1. Build the byte-level concat string
    # This automatically finds VTS_01_1.VOB, VTS_01_2.VOB, etc. and chains them.
    CONCAT_STRING="concat:"
    FIRST_FILE=true
    
    for VOB_PART in "$VIDEO_TS_DIR"/${TITLE_PREFIX}_[1-9].VOB; do
        [ -e "$VOB_PART" ] || continue
        
        # cygpath -m converts Git Bash paths to Windows paths with forward slashes (D:/VIDEO_TS/...)
        # This is REQUIRED for Windows FFmpeg to read concatenated strings properly.
        WIN_PATH=$(cygpath -m "$VOB_PART")
        
        if [ "$FIRST_FILE" = true ]; then
            CONCAT_STRING="${CONCAT_STRING}${WIN_PATH}"
            FIRST_FILE=false
        else
            CONCAT_STRING="${CONCAT_STRING}|${WIN_PATH}"
        fi
    done
    
    echo "Mapped sequence: $CONCAT_STRING"

    # 2. Extract chapters from the first VOB file before encoding
    CHAPTERS=$("$FFPROBE_BIN" -i "$FIRST_VOB" -print_format csv -show_chapters 2>/dev/null | cut -d ',' -f 4 | paste -sd "," -)
    
    FULL_MP4="${OUTPUT_DIR}/${TITLE_PREFIX}_Full.mp4"

    # 3. Merge and Encode to fix the broken DVD timeline
    # -fflags +genpts: Forces FFmpeg to generate fresh, unbroken timestamps
    echo "Step 1/2: Merging and encoding to a clean timeline (This takes time)..."
    "$FFMPEG_BIN" -fflags +genpts -analyzeduration 100M -probesize 100M \
        -i "$CONCAT_STRING" \
        -c:v libx264 -crf 22 -preset medium -vf yadif \
        -c:a aac -b:a 192k \
        "$FULL_MP4" -y

    if [ ! -s "$FULL_MP4" ]; then
        echo "Error: Encoding failed for $TITLE_PREFIX. Moving to next title."
        continue
    fi

    # 4. Split the newly repaired MP4 into chapters
    if [ -z "$CHAPTERS" ] || [ "$CHAPTERS" == "0.000000" ] || [ "$CHAPTERS" == "0" ]; then
        echo "Step 2/2: No multiple chapters found. Left as a single file: ${TITLE_PREFIX}_Full.mp4"
    else
        echo "Step 2/2: Chapters detected! Splitting the clean MP4..."
        
        # Notice we use "-c copy" here. Because the MP4 is already encoded and clean, 
        # this splitting process takes seconds and won't crash.
        "$FFMPEG_BIN" -i "$FULL_MP4" \
            -f segment \
            -segment_times "$CHAPTERS" \
            -reset_timestamps 1 \
            -map 0 \
            -c copy \
            "${OUTPUT_DIR}/${TITLE_PREFIX}_ch%03d.mp4" -y
            
        echo "Finished splitting chapters for $TITLE_PREFIX."
        
        # Optional: Delete the large "_Full.mp4" file if you ONLY want the chapters.
        # Remove the '#' from the line below to enable auto-cleanup.
        # rm "$FULL_MP4"
    fi
done

echo "=================================================="
echo "Complete! All processing successfully finished."