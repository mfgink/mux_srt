#!/bin/bash
# Script: optimize_subs.sh 8.8
# Goal: Muxes video/audio/SRT.
# Update 8.8: FINAL CONSOLIDATED FIX.
#   - Re-implements 'track:s1' targeting (from v8.5) to prevent Audio/Sub mixups.
#   - Includes Audio Hierarchy (JPN > ENG) and Cleanup (wipes bad track names).
#   - Includes Image Handling (v8.6) and Deep Scan (v8.1).

# --- VERSION CHECK ---
SCRIPT_INFO=$(head -n 2 "$0" | tail -n 1 | sed 's/^# //')
echo "--- Starting Subtitle Optimization (v8.8 - Final Consolidated) ---"
echo "--- Executing Version: $SCRIPT_INFO ---"

START_TIME=$(date +%s)
TOTAL_RUN_COUNT=0
RECONCILE_FAILED=1 

LOG_FILE="./muxing_cleanup_$(date +%Y%m%d_%H%M%S).log"
echo "--- Muxing Cleanup Log - $(date) ---" > "$LOG_FILE"
echo "Script Version: $SCRIPT_INFO" >> "$LOG_FILE"

STAGING_DIR="optimized_mkv"

# --- HELPER FUNCTIONS ---
get_unique_filename() {
    local BASE="$1"; local OUT="$BASE"; local CNT=1
    while [ -f "$OUT" ]; do OUT="${BASE%.mkv}${CNT}.mkv"; CNT=$((CNT+1)); done
    echo "$OUT"
}

handle_images() {
    local BASE="$1"; local NEW="$2"
    # Search for images starting with the clean base name
    find "$(dirname "$BASE")" -maxdepth 1 -name "$(basename "$BASE")*" | while read IMG; do
        if [[ "$IMG" == *.jpg || "$IMG" == *.png || "$IMG" == *.jpeg ]]; then
            local EXT="${IMG##*.}"
            local TGT="${NEW}.${EXT}"
            if [[ "$IMG" == *"-thumb."* ]]; then TGT="${NEW}-thumb.${EXT}"; fi
            
            if [ "$IMG" != "$TGT" ]; then
                mv "$IMG" "$TGT"
                echo "   [IMG] $(basename "$IMG") -> $(basename "$TGT")" >> "$LOG_FILE"
            fi
        fi
    done
}

check_is_english() {
    local FILE="$1"; local TID="$2"
    local TMP="temp_scan_${TID}.srt"
    mkvextract tracks "$FILE" "${TID}:${TMP}" > /dev/null 2>&1
    if [ ! -f "$TMP" ]; then return 1; fi
    local HEAD=$(head -n 100 "$TMP")
    local SCORE=0
    # Count stop words
    for WORD in the and you that is; do
        CNT=$(echo "$HEAD" | grep -o -i "\b$WORD\b" | wc -l)
        SCORE=$((SCORE + CNT))
    done
    rm "$TMP"
    if [ "$SCORE" -ge 3 ]; then return 0; else return 1; fi
}

# --- CORE LOGIC ---
process_file() {
    local FILE="$1"
    local DIR=$(dirname "$FILE")
    local BASE=$(basename "$FILE")
    # Clean Basename
    local CLEAN_BASE=$(echo "$BASE" | sed -E 's/(\.optimized|\.none_sub)+//g')
    CLEAN_BASE="${CLEAN_BASE%.mkv}.mkv"
    
    local SRT_EXT="${FILE%.mkv}.srt"
    # Check for SRTs with clean names if current doesn't exist
    if [ ! -f "$SRT_EXT" ]; then
        local ALT="$DIR/${CLEAN_BASE%.mkv}.srt"
        [ -f "$ALT" ] && SRT_EXT="$ALT"
    fi

    PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
    echo "--- Processing: $FILE" | tee -a "$LOG_FILE"

    local INFO=$(mkvmerge -J "$FILE" 2>/dev/null)
    if [ -z "$INFO" ]; then echo "   [ERR] Bad File."; ERROR_COUNT=$((ERROR_COUNT+1)); return 0; fi

    local BAD_SUB=$(echo "$INFO" | jq '[.tracks[] | select(.properties.codec_id | test("PGS|ASS|SSA|VOBSUB"))] | length')
    local INT_SRT=$(echo "$INFO" | jq '[.tracks[] | select(.properties.codec_id | test("SRT|UTF8"))] | length')
    local HAS_EXT=0; [ -f "$SRT_EXT" ] && HAS_EXT=1

    # IMMUNITY / REPAIR CHECK
    if [[ "$FILE" == *".optimized.mkv" ]]; then
        # Check for Metadata Corruption (Bad Audio Name OR Undetermined Sub)
        local BAD_AUDIO=$(echo "$INFO" | jq -r '[.tracks[] | select(.type=="audio" and .properties.track_name=="English SRT")] | length')
        local SRT_LANG=$(echo "$INFO" | jq -r '[.tracks[] | select(.properties.codec_id | test("SRT|UTF8"))] | .[0].properties.language')
        
        if [ "$BAD_SUB" -eq 0 ] && [ "$INT_SRT" -eq 1 ] && [ "$BAD_AUDIO" -eq 0 ] && [ "$SRT_LANG" == "eng" ]; then
            # Clean. Just fix images.
            handle_images "$DIR/${CLEAN_BASE%.mkv}" "${FILE%.mkv}"
            return 0
        else
            echo "   [NOTICE] File is .optimized but 'Dirty' (Audio Tag or Lang). Repairing..." | tee -a "$LOG_FILE"
            # Proceed to Mux logic to repair
        fi
    fi

    # 1. NO SUBS (AUDIO ONLY FIX)
    if [ "$BAD_SUB" -eq 0 ] && [ "$HAS_EXT" -eq 0 ] && [ "$INT_SRT" -eq 0 ]; then
         echo "   [INFO] No subtitles. Running Audio-Only Optimization..." | tee -a "$LOG_FILE"
         local TGT="${FILE%.mkv}.optimized.mkv"
         if [[ "$FILE" == *".none_sub.mkv" ]]; then TGT="${FILE%.none_sub.mkv}.optimized.mkv"; fi
         
         if [ "$FILE" != "$TGT" ]; then mv "$FILE" "$TGT"; fi
         finalize_file "$TGT" "$FILE" "" "NO_SUBS"
         return 0
    fi

    # 2. MUX EXTERNAL
    if [ "$HAS_EXT" -eq 1 ]; then
        echo "   [INFO] External SRT found. Muxing..." | tee -a "$LOG_FILE"
        mkdir -p "$DIR/$STAGING_DIR"
        local TGT="$DIR/$STAGING_DIR/${CLEAN_BASE%.mkv}.optimized.mkv"
        TGT=$(get_unique_filename "$TGT")
        
        mkvmerge -o "$TGT" --no-subtitles "$FILE" "$SRT_EXT" >> "$LOG_FILE" 2>&1
        if [ $? -eq 0 ]; then finalize_file "$TGT" "$FILE" "$SRT_EXT" "HAS_SUBS"; else echo "   [ERR] Mux Failed"; rm "$TGT"; fi
        return 0
    fi

    # 3. INTERNAL PROCESSING (De-Dupe/Repair)
    local TID=""
    # Try finding English Tag
    TID=$(echo "$INFO" | jq -r '.tracks[] | select((.properties.codec_id | test("SRT|UTF8")) and (.properties.language | test("eng|en|english"))) | .id' | head -n 1)
    
    # Fallback: Deep Scan 'und' tracks
    if [ -z "$TID" ] && [ "$INT_SRT" -gt 0 ]; then
        echo "   [INFO] No ENG tag. Deep Scanning..." | tee -a "$LOG_FILE"
        local UNDS=$(echo "$INFO" | jq -r '.tracks[] | select((.properties.codec_id | test("SRT|UTF8")) and .properties.language=="und") | .id')
        for ID in $UNDS; do
            if check_is_english "$FILE" "$ID"; then TID="$ID"; echo "      > [HIT] Track $ID is English."; break; fi
        done
    fi
    
    # Fallback: First SRT
    if [ -z "$TID" ] && [ "$INT_SRT" -gt 0 ]; then TID=$(echo "$INFO" | jq -r '.tracks[] | select(.properties.codec_id | test("SRT|UTF8")) | .id' | head -n 1); fi

    if [ -n "$TID" ]; then
        if [ "$BAD_SUB" -eq 0 ] && [ "$INT_SRT" -eq 1 ] && [[ "$FILE" != *".optimized.mkv" ]]; then
             # Native Rename
             echo "   [INFO] Native Clean. Renaming..." | tee -a "$LOG_FILE"
             local TGT="${FILE%.mkv}.optimized.mkv"
             if [[ "$FILE" == *".none_sub.mkv" ]]; then TGT="${FILE%.none_sub.mkv}.optimized.mkv"; fi
             mv "$FILE" "$TGT"
             finalize_file "$TGT" "$FILE" "" "HAS_SUBS"
        else
             # Remux (Cleaning/Repairing)
             echo "   [ACTION] Cleaning/Repairing via Mux..." | tee -a "$LOG_FILE"
             mkdir -p "$DIR/$STAGING_DIR"
             local TGT="$DIR/$STAGING_DIR/${CLEAN_BASE%.mkv}.optimized.mkv"
             TGT=$(get_unique_filename "$TGT")
             
             mkvmerge -o "$TGT" --subtitle-tracks "$TID" "$FILE" >> "$LOG_FILE" 2>&1
             if [ $? -eq 0 ]; then finalize_file "$TGT" "$FILE" "" "HAS_SUBS"; else echo "   [ERR] Mux Failed"; rm "$TGT"; fi
        fi
    fi
}

finalize_file() {
    local NEW="$1"; local OLD="$2"; local SRT="$3"; local MODE="$4"
    local INFO=$(mkvmerge -J "$NEW")
    
    # --- FIX 1: TARGETING (track:s1) ---
    # We stripped all other subs, so our target is ALWAYS Subtitle Track 1.
    if [ "$MODE" == "HAS_SUBS" ]; then
        mkvpropedit "$NEW" --edit track:s1 --set language=eng --set name="English SRT" --set flag-default=1 --set flag-forced=0 >> "$LOG_FILE" 2>&1
    fi

    # --- FIX 2: AUDIO HIERARCHY ---
    local ALANGS=$(echo "$INFO" | jq -r '[.tracks[] | select(.type=="audio").properties.language]')
    # Priority: JPN > ENG > First
    local AIDX=$(echo "$ALANGS" | jq -r 'index("jpn")')
    if [ "$AIDX" == "null" ] && [ "$MODE" == "NO_SUBS" ]; then AIDX=$(echo "$ALANGS" | jq -r 'index("eng") // index("en")'); fi
    if [ "$AIDX" == "null" ]; then AIDX=$(echo "$ALANGS" | jq -r 'index("eng") // index("en")'); fi # Fallback for HAS_SUBS if no JPN
    
    if [ "$AIDX" != "null" ] && [ -n "$AIDX" ]; then
        local A_SEL="track:a$((AIDX+1))"
        # Set Default=1, Forced=0, and WIPE THE NAME (Fixes "English SRT" bug)
        mkvpropedit "$NEW" --edit "$A_SEL" --set flag-default=1 --set flag-forced=0 --set name="" >> "$LOG_FILE" 2>&1
    fi

    # Cleanup & Move
    [ -n "$SRT" ] && rm "$SRT"
    [ "$NEW" != "$OLD" ] && rm "$OLD"
    
    local FINAL_NAME=$(basename "$NEW")
    local FINAL_DIR=$(dirname "$OLD")
    local FINAL_PATH="$FINAL_DIR/$FINAL_NAME"
    
    if [ "$NEW" != "$FINAL_PATH" ]; then mv "$NEW" "$FINAL_PATH"; fi
    
    rmdir "$(dirname "$NEW")" 2>/dev/null
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    
    # Image Sync
    local CLEAN_BASE=$(echo "$(basename "$OLD")" | sed -E 's/(\.optimized|\.none_sub)+//g')
    CLEAN_BASE="${CLEAN_BASE%.mkv}"
    handle_images "$FINAL_DIR/$CLEAN_BASE" "${FINAL_PATH%.mkv}"
}

export -f get_unique_filename process_file handle_images check_is_english finalize_file
export LOG_FILE STAGING_DIR SUCCESS_COUNT ERROR_COUNT PROCESSED_COUNT

find . -type f -name "*.mkv" -exec bash -c 'process_file "$@"' sh {} \;

echo "--- DONE. Processed: $PROCESSED_COUNT | Success: $SUCCESS_COUNT ---" | tee -a "$LOG_FILE"
# END OF DOCUMENT 20251130-0700
