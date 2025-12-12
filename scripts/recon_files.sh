#!/bin/bash
# Script: recon_files.sh 8.2
# Goal: Perform a comprehensive audit of the entire library.
# Update 8.2: SPLIT VIDEO TABLES.
#   - Separates Videos into "Failures" (Top) and "Success" (Bottom) for better readability.
#   - Retains No-Sub Exception and UTF8 logic.

# --- VERSION CHECK ---
SCRIPT_INFO=$(head -n 2 "$0" | tail -n 1 | sed 's/^# //')
echo "--- Starting Full Library Reconciliation (v8.2 - Split Fail/Pass) ---"
echo "--- Executing Version: $SCRIPT_INFO ---"

START_TIME=$(date +%s)
TOTAL_SCANNED=0
PASS_COUNT=0
FAIL_COUNT=0

# Define Output Files
TIMESTAMP=$(date +%Y%m%d-%H%M)
REPORT_FILE="./reconciliation_report ${TIMESTAMP}.md"
VIDEO_FAIL_TMP="./video_fail.tmp"
VIDEO_PASS_TMP="./video_pass.tmp"
OTHER_TMP="./other_rows.tmp"

# Initialize Temp Files
> "$VIDEO_FAIL_TMP"
> "$VIDEO_PASS_TMP"
> "$OTHER_TMP"

# --- RECONCILIATION REPORT HEADER ---
echo "# Automation Reconciliation Report" > "$REPORT_FILE"
echo "Generated: $(date)" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
echo "## Audit Criteria" >> "$REPORT_FILE"
echo "1. **Videos:** Must be .optimized.mkv OR .none_sub.mkv." >> "$REPORT_FILE"
echo "   - If Subs exist: Must have ENG SRT Default." >> "$REPORT_FILE"
echo "   - If No Subs: Must have Audio Default." >> "$REPORT_FILE"
echo "2. **Images:** Must share the exact basename of the video." >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

# --- MAIN AUDIT LOOP ---
find . -type f \( -name "*.mkv" -o -name "*.jpg" -o -name "*.jpeg" -o -name "*.png" \) | while IFS= read -r FILE; do
    
    TOTAL_SCANNED=$((TOTAL_SCANNED + 1))
    
    BASE_NAME=$(basename "$FILE")
    EXTENSION="${BASE_NAME##*.}"
    DIR_NAME=$(dirname "$FILE")
    NAME_NO_EXT="${BASE_NAME%.*}"
    
    AUDIT_STATUS="FAIL"
    DETAILS="N/A"
    ASSET_TYPE="UNKNOWN"

    # === 1. IMAGE AUDIT ===
    if [[ "$EXTENSION" == "jpg" || "$EXTENSION" == "jpeg" || "$EXTENSION" == "png" ]]; then
        ASSET_TYPE="Image"
        
        MATCHING_MKV="$DIR_NAME/$NAME_NO_EXT.mkv"
        if [ ! -f "$MATCHING_MKV" ]; then
             if [[ "$BASE_NAME" =~ ^(poster|backdrop|folder|logo|fanart|banner|landscape) ]]; then
                 AUDIT_STATUS="SKIP"
                 DETAILS="System Image (Ignored)."
             else
                 CLEAN_ROOT=$(echo "$NAME_NO_EXT" | sed -E 's/(\.optimized|\.none_sub)+//g')
                 if ls "$DIR_NAME/$CLEAN_ROOT"*.mkv 1> /dev/null 2>&1; then
                     if [[ "$BASE_NAME" == *".none_sub."* ]] || [[ "$BASE_NAME" == *".optimized"* ]]; then
                        AUDIT_STATUS="PASS"
                        DETAILS="Naming OK."
                     else
                        AUDIT_STATUS="FAIL"
                        DETAILS="**Renaming Failed:** Video exists but image not renamed."
                     fi
                 else
                     AUDIT_STATUS="SKIP"
                     DETAILS="Orphan (No matching video)."
                 fi
             fi
        else
             if [[ "$BASE_NAME" == *".none_sub."* ]] || [[ "$BASE_NAME" == *".optimized"* ]]; then
                AUDIT_STATUS="PASS"
                DETAILS="Naming OK."
             else
                AUDIT_STATUS="FAIL"
                DETAILS="**Renaming Failed:** Filename mismatch."
             fi
        fi
        
        echo "| $BASE_NAME | $ASSET_TYPE | **$AUDIT_STATUS** | $DETAILS |" >> "$OTHER_TMP"

    # === 2. VIDEO (MKV) AUDIT ===
    elif [[ "$EXTENSION" == "mkv" ]]; then
        ASSET_TYPE="Video"
        
        # CASE A: END STATE (.none_sub.mkv)
        if [[ "$BASE_NAME" == *".none_sub.mkv" ]]; then
            AUDIT_STATUS="PASS"
            DETAILS="Classified Unusable (Clean)."
            
        # CASE B: OPTIMIZED (.optimized*.mkv)
        elif [[ "$BASE_NAME" == *".optimized"*".mkv" ]]; then
            
            INFO_JSON=$(mkvmerge -J "$FILE" 2>/dev/null)
            
            if [ -z "$INFO_JSON" ]; then
                 AUDIT_STATUS="FAIL"
                 DETAILS="**CRITICAL:** mkvmerge could not read file."
            else
                # METADATA EXTRACTION
                TOTAL_SUBS=$(echo "$INFO_JSON" | jq '[.tracks[] | select(.type=="subtitles")] | length')
                
                # Check 1: English SRT Default?
                HAS_VALID_SRT="SKIP"
                if [ "$TOTAL_SUBS" -gt 0 ]; then
                    HAS_VALID_SRT=$(echo "$INFO_JSON" | jq -r '.tracks[] | select(.type=="subtitles" and (.properties.codec_id=="S_TEXT/SRT" or .properties.codec_id=="S_TEXT/UTF8") and .properties.language=="eng" and .properties.default_track==true) | .id')
                fi
                
                # Check 2: Audio Default Set?
                HAS_DEFAULT_AUDIO=$(echo "$INFO_JSON" | jq -r '.tracks[] | select(.type=="audio" and .properties.default_track==true) | .id')

                # Check 3: No Complex Subs?
                COMPLEX_SUBS=$(echo "$INFO_JSON" | jq -r '.tracks[] | select(.properties.codec_id=="S_HDMV/PGS" or .properties.codec_id=="S_TEXT/ASS" or .properties.codec_id=="S_TEXT/SSA" or .properties.codec_id=="S_VOBSUB") | .id')

                # EVALUATE
                FLAG_ERRORS=""
                
                if [ "$TOTAL_SUBS" -gt 0 ]; then
                    if [ -z "$HAS_VALID_SRT" ]; then FLAG_ERRORS+="SRT not ENG+Default; "; fi
                fi
                
                if [ -z "$HAS_DEFAULT_AUDIO" ]; then FLAG_ERRORS+="No Default Audio; "; fi
                if [ -n "$COMPLEX_SUBS" ]; then FLAG_ERRORS+="Complex Subs Remain; "; fi
                
                if [ -z "$FLAG_ERRORS" ]; then
                    AUDIT_STATUS="PASS"
                    if [ "$TOTAL_SUBS" -eq 0 ]; then DETAILS="Audio Only (Clean)."; else DETAILS="Flags Verified."; fi
                else
                    AUDIT_STATUS="FAIL"
                    DETAILS="Flags: $FLAG_ERRORS"
                fi
            fi
            
        else
            AUDIT_STATUS="FAIL"
            DETAILS="**Unprocessed:** File not optimized/classified."
        fi
        
        # Log to correct VIDEO table (Fail vs Pass)
        if [ "$AUDIT_STATUS" == "PASS" ]; then
            echo "| $BASE_NAME | $ASSET_TYPE | **$AUDIT_STATUS** | $DETAILS |" >> "$VIDEO_PASS_TMP"
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            echo "| $BASE_NAME | $ASSET_TYPE | **$AUDIT_STATUS** | $DETAILS |" >> "$VIDEO_FAIL_TMP"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    fi

done

# --- ASSEMBLE REPORT ---

echo "## 🔴 Video Validation - FAILURES (Action Required)" >> "$REPORT_FILE"
echo "| File Name | Type | Status | Issues / Details |" >> "$REPORT_FILE"
echo "| :--- | :---: | :---: | :--- |" >> "$REPORT_FILE"
cat "$VIDEO_FAIL_TMP" >> "$REPORT_FILE"

echo "" >> "$REPORT_FILE"
echo "## 🟢 Video Validation - SUCCESS" >> "$REPORT_FILE"
echo "| File Name | Type | Status | Issues / Details |" >> "$REPORT_FILE"
echo "| :--- | :---: | :---: | :--- |" >> "$REPORT_FILE"
cat "$VIDEO_PASS_TMP" >> "$REPORT_FILE"

echo "" >> "$REPORT_FILE"
echo "## Companion Assets (Images)" >> "$REPORT_FILE"
echo "| File Name | Type | Status | Issues / Details |" >> "$REPORT_FILE"
echo "| :--- | :---: | :---: | :--- |" >> "$REPORT_FILE"
cat "$OTHER_TMP" >> "$REPORT_FILE"

# --- FINAL SUMMARY FOOTER ---
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo "" >> "$REPORT_FILE"
echo "## Execution Summary" >> "$REPORT_FILE"
echo "* **Total Assets Scanned:** $TOTAL_SCANNED" >> "$REPORT_FILE"
echo "* **PASS:** $PASS_COUNT" >> "$REPORT_FILE"
echo "* **FAIL:** $FAIL_COUNT" >> "$REPORT_FILE"
echo "* **Time Taken:** $(date -u -d @$DURATION +%T)" >> "$REPORT_FILE"

rm "$VIDEO_FAIL_TMP" "$VIDEO_PASS_TMP" "$OTHER_TMP"

echo ""
echo "--- RECONCILIATION AUDIT COMPLETED ---"
echo "Report: $REPORT_FILE"
echo "Pass: $PASS_COUNT | Fail: $FAIL_COUNT"

# END OF DOCUMENT 20251130-0630
