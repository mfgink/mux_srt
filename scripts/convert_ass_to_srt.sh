#!/bin/bash
# Script: convert_ass_to_srt.sh 5.9
# Goal: Convert internal SSA/ASS to SRT.
# Update 5.9: LANGUAGE PRIORITY.
#   - Now prioritizes 'eng'/'en' tracks when selecting an ASS/SSA stream to convert.
#   - Fallback to first available ASS/SSA if no English track is found.
#   - Prevents accidental conversion of Korean/Foreign tracks when English exists.

# --- VERSION CHECK ---
SCRIPT_INFO=$(head -n 2 "$0" | tail -n 1 | sed 's/^# //')
echo "--- Starting Subtitle Conversion & Classification ---"
echo "--- Executing Version: $SCRIPT_INFO ---"

START_TIME=$(date +%s)
TOTAL_RUN_COUNT=0
RECONCILE_FAILED=1 

# Define the Log File Path
LOG_FILE="./subtitle_conversion_$(date +%Y%m%d_%H%M%S).log"
echo "--- Subtitle Conversion Log - $(date) ---" > "$LOG_FILE"
echo "Script Version: $SCRIPT_INFO" >> "$LOG_FILE"
echo "Log file created at: $LOG_FILE"

# --- MAIN RECONCILIATION LOOP ---
while [ "$RECONCILE_FAILED" -eq 1 ] && [ "$TOTAL_RUN_COUNT" -lt 10 ]; do
    
    TOTAL_RUN_COUNT=$((TOTAL_RUN_COUNT + 1))
    RECONCILE_FAILED=0 

    SUCCESS_COUNT=0
    ERROR_COUNT=0
    
    echo "" | tee -a "$LOG_FILE"
    echo "--- RUN $TOTAL_RUN_COUNT: Processing Files ---" | tee -a "$LOG_FILE"

    sync
    echo "Waiting 5 seconds for filesystem stabilization..." >> "$LOG_FILE"
    sleep 5 

    # --- RECURSIVE FIND LOOP ---
    find . -type f -name "*.mkv" | sed 's|^|./|g; s|^././|./|g' | while IFS= read -r FILE; do
        
        # 1. IMMUNITY CHECK (With Break Logic for Optimized files missing SRTs)
        SRT_OUTPUT="${FILE%.mkv}.srt"
        
        # If external SRT exists, skip
        if [ -f "$SRT_OUTPUT" ]; then continue; fi

        # 2. IDENTIFY TRACKS (Updated to fetch Tags)
        # We need 'tags' to check for language
        JSON_DATA=$(ffprobe -v error -select_streams s -show_entries stream=index,codec_name,tags -of json "$FILE")
        
        # A. Priority Search: Find ASS/SSA with English Language Tag
        SUBTITLE_STREAM_INDEX=$(echo "$JSON_DATA" | jq -r '.streams[] | select((.codec_name=="ass" or .codec_name=="ssa") and (.tags.language=="eng" or .tags.language=="en")) | .index' | head -n 1)
        
        # B. Fallback Search: If no English found, take the first ASS/SSA we see
        if [ -z "$SUBTITLE_STREAM_INDEX" ]; then
             SUBTITLE_STREAM_INDEX=$(echo "$JSON_DATA" | jq -r '.streams[] | select(.codec_name=="ass" or .codec_name=="ssa") | .index' | head -n 1)
             if [ -n "$SUBTITLE_STREAM_INDEX" ]; then
                 echo "   [WARN] No English-tagged ASS found. Falling back to Track Index $SUBTITLE_STREAM_INDEX." | tee -a "$LOG_FILE"
             fi
        else
             echo "   [INFO] English ASS/SSA detected at index $SUBTITLE_STREAM_INDEX." | tee -a "$LOG_FILE"
        fi

        # Check for other types (for immunity logic)
        SRT_INDEX=$(echo "$JSON_DATA" | jq -r '.streams[] | select(.codec_name=="subrip") | .index' | head -n 1)
        IMAGE_SUB_EXISTS=$(echo "$JSON_DATA" | jq -r '.streams[] | select(.codec_name=="hdmv_pgs_subtitle" or .codec_name=="dvd_subtitle") | .index' | head -n 1)

        # IMMUNITY BREAK CHECK
        if [[ "$FILE" == *".none_sub.mkv" ]] || [[ "$FILE" == *".optimized"*".mkv" ]]; then
            if [ -n "$SUBTITLE_STREAM_INDEX" ] && [ -z "$SRT_INDEX" ]; then
                 echo "   [NOTICE] Breaking Immunity for $FILE. (Hidden ASS found)." | tee -a "$LOG_FILE"
            else
                 continue
            fi
        fi

        # 3. LOGIC GATES
        
        # CASE A: ASS/SSA Found -> CONVERT
        if [ -n "$SUBTITLE_STREAM_INDEX" ]; then
            echo "Processing: $FILE" | tee -a "$LOG_FILE"
            echo "   [INFO] Converting Stream Index: $SUBTITLE_STREAM_INDEX..." | tee -a "$LOG_FILE"
            
            ffmpeg -nostdin -i "$FILE" -map 0:s:"$SUBTITLE_STREAM_INDEX"? -c:s srt -y "$SRT_OUTPUT" < /dev/null >> "$LOG_FILE" 2>&1
            
            if [ $? -eq 0 ] && [ -s "$SRT_OUTPUT" ]; then
                echo "   [SUCCESS] Created external SRT file." | tee -a "$LOG_FILE"
                SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            else
                echo "   [ERROR] Conversion failed." | tee -a "$LOG_FILE"
                rm "$SRT_OUTPUT" 2>/dev/null
                ERROR_COUNT=$((ERROR_COUNT + 1))
            fi

        # CASE B: Internal SRT Found -> PASS
        elif [ -n "$SRT_INDEX" ]; then
            continue
            
        # CASE C: Only Image Subs -> FAIL (Rename)
        elif [ -n "$IMAGE_SUB_EXISTS" ]; then
            if [[ "$FILE" == *".none_sub.mkv" ]]; then continue; fi
            NEW_FILENAME="${FILE%.mkv}.none_sub.mkv"
            CLEAN_BASE=$(echo "$FILE" | sed -E 's/(\.optimized|\.none_sub)+//g')
            NEW_FILENAME="${CLEAN_BASE%.mkv}.none_sub.mkv"
            
            if [ "$FILE" != "$NEW_FILENAME" ]; then
                mv "$FILE" "$NEW_FILENAME"
                echo "Processing: $FILE" | tee -a "$LOG_FILE"
                echo "   [ACTION] Image Subs only. Renamed to .none_sub.mkv." | tee -a "$LOG_FILE"
            fi

        # CASE D: No Subs -> FAIL (Rename)
        else
            if [[ "$FILE" == *".none_sub.mkv" ]]; then continue; fi
            NEW_FILENAME="${FILE%.mkv}.none_sub.mkv"
            CLEAN_BASE=$(echo "$FILE" | sed -E 's/(\.optimized|\.none_sub)+//g')
            NEW_FILENAME="${CLEAN_BASE%.mkv}.none_sub.mkv"

            if [ "$FILE" != "$NEW_FILENAME" ] && [ ! -f "$NEW_FILENAME" ]; then
                mv "$FILE" "$NEW_FILENAME"
                echo "Processing: $FILE" | tee -a "$LOG_FILE"
                echo "   [ACTION] No subtitles found. Renamed to .none_sub.mkv." | tee -a "$LOG_FILE"
            fi
        fi

    done
    
    # --- RECONCILIATION CHECK ---
    echo "" >> "$LOG_FILE"
    echo "--- RECONCILIATION CHECK ---" | tee -a "$LOG_FILE"
    
    find . -type f -name "*.mkv" | while IFS= read -r MKV_FILE; do
        if [[ "$MKV_FILE" == *".none_sub.mkv" ]] || [[ "$MKV_FILE" == *".optimized"*".mkv" ]]; then
            continue
        fi
        
        if [ ! -f "$MKV_FILE" ]; then continue; fi 

        SRT_COMPANION="${MKV_FILE%.mkv}.srt"
        HAS_INT_SRT=$(ffprobe -v error -select_streams s -show_entries stream=codec_name -of json "$MKV_FILE" | grep "subrip")
        
        if [ ! -f "$SRT_COMPANION" ] && [ -z "$HAS_INT_SRT" ]; then
             echo "   [FAILURE] File skipped but lacks Internal OR External SRT: $MKV_FILE" | tee -a "$LOG_FILE"
             RECONCILE_FAILED=1
        fi
    done
    
    if [ "$RECONCILE_FAILED" -eq 1 ]; then
        echo "RECONCILIATION FAILED. Rerunning script..." | tee -a "$LOG_FILE"
        sleep 5
    else
        echo "RECONCILIATION SUCCESSFUL. All files handled." | tee -a "$LOG_FILE"
    fi
    
    if [ "$TOTAL_RUN_COUNT" -ge 10 ] && [ "$RECONCILE_FAILED" -eq 1 ]; then
        echo "SAFETY BREAK: Reached maximum runs. Exiting." | tee -a "$LOG_FILE"
        break
    fi

done

# --- FINAL SUMMARY ---
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo "" | tee -a "$LOG_FILE"
echo "--- FINAL SUMMARY (Language Priority) ---" | tee -a "$LOG_FILE"
echo "Total Time: $(date -u -d @$DURATION +%T)" | tee -a "$LOG_FILE"
echo "----------------------------------------------------" | tee -a "$LOG_FILE"
echo "FULL LOG SAVED TO: $LOG_FILE"

# END OF DOCUMENT 20251130-1050
