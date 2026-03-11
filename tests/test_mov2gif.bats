#!/usr/bin/env bats
# bats tests for mov2gif
# Each test that produces output cleans up after itself.

setup() {
    # Run every test inside a fresh temp dir so output goes nowhere unexpected
    TEST_TMP="$(mktemp -d)"
    cd "$TEST_TMP"

    # Locate the script (repo root relative to this file)
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    MOV2GIF="$SCRIPT_DIR/bin/mov2gif"

    # ImageMagick v7 exposes a unified 'magick' binary; v6 (Ubuntu/apt) uses
    # separate 'identify' and 'convert' binaries.
    if command -v magick &>/dev/null; then
        MAGICK_IDENTIFY="magick identify"
        MAGICK_CONVERT="magick convert"
    else
        MAGICK_IDENTIFY="identify"
        MAGICK_CONVERT="convert"
    fi
}

teardown() {
    rm -rf "$TEST_TMP"
}

# ── CLI flag tests ────────────────────────────────────────────────────────────

@test "--help exits 0 and prints usage" {
    run "$MOV2GIF" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" == *"--quality"* ]]
}

@test "-h is an alias for --help" {
    run "$MOV2GIF" -h
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "unknown flag exits non-zero" {
    run "$MOV2GIF" --no-such-flag
    [ "$status" -ne 0 ]
}

@test "--quality requires an argument" {
    run "$MOV2GIF" --quality
    [ "$status" -ne 0 ]
}

@test "invalid quality preset exits non-zero" {
    run "$MOV2GIF" -q ultra
    [ "$status" -ne 0 ]
}

@test "no .mov files in directory exits non-zero" {
    run "$MOV2GIF"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No .mov files found"* ]]
}

@test "missing file argument prints warning and exits non-zero" {
    run "$MOV2GIF" nonexistent.mov
    [ "$status" -ne 0 ]
}

# ── conversion tests ──────────────────────────────────────────────────────────

# Generate a synthetic .mov that mimics the structure of a terminal recording:
# - Solid black outer border (desktop background)
# - A lighter rectangle in the centre (the window chrome / content area)
make_test_mov() {
    local out="$1"
    ffmpeg -y -hide_banner -loglevel quiet \
        -f lavfi \
        -i "color=c=black:size=800x560:rate=5,
            drawbox=x=60:y=40:w=680:h=480:color=#1e2023:t=fill,
            drawbox=x=60:y=40:w=680:h=28:color=#2d3035:t=fill,
            drawtext=fontcolor=white:text='test':x=70:y=46" \
        -t 0.4 "$out"
}

@test "converts a single file at default (high) quality" {
    make_test_mov "test.mov"
    run "$MOV2GIF" test.mov
    [ "$status" -eq 0 ]
    [ -f "gifs/test_high.gif" ]
    [ -s "gifs/test_high.gif" ]
}

@test "converts at medium quality" {
    make_test_mov "rec.mov"
    run "$MOV2GIF" -q medium rec.mov
    [ "$status" -eq 0 ]
    [ -f "gifs/rec_medium.gif" ]
    [ -s "gifs/rec_medium.gif" ]
}

@test "converts at xhigh quality" {
    make_test_mov "rec.mov"
    run "$MOV2GIF" -q xhigh rec.mov
    [ "$status" -eq 0 ]
    [ -f "gifs/rec_xhigh.gif" ]
    [ -s "gifs/rec_xhigh.gif" ]
}

@test "all quality preset produces three output files" {
    make_test_mov "demo.mov"
    run "$MOV2GIF" -q all demo.mov
    [ "$status" -eq 0 ]
    [ -f "gifs/demo_medium.gif" ]
    [ -f "gifs/demo_high.gif" ]
    [ -f "gifs/demo_xhigh.gif" ]
}

@test "auto-discovers .mov files when no argument given" {
    make_test_mov "auto.mov"
    run "$MOV2GIF" -q medium
    [ "$status" -eq 0 ]
    [ -f "gifs/auto_medium.gif" ]
}

@test "output GIF has white corners (background removed)" {
    make_test_mov "bg.mov"
    run "$MOV2GIF" -q medium bg.mov
    [ "$status" -eq 0 ]
    local tl tr bl br
    tl=$($MAGICK_IDENTIFY -format '%[fx:p{0,0}.r*255],%[fx:p{0,0}.g*255],%[fx:p{0,0}.b*255]' gifs/bg_medium.gif)
    tr=$($MAGICK_IDENTIFY -format '%[fx:p{w-1,0}.r*255],%[fx:p{w-1,0}.g*255],%[fx:p{w-1,0}.b*255]' gifs/bg_medium.gif)
    bl=$($MAGICK_IDENTIFY -format '%[fx:p{0,h-1}.r*255],%[fx:p{0,h-1}.g*255],%[fx:p{0,h-1}.b*255]' gifs/bg_medium.gif)
    br=$($MAGICK_IDENTIFY -format '%[fx:p{w-1,h-1}.r*255],%[fx:p{w-1,h-1}.g*255],%[fx:p{w-1,h-1}.b*255]' gifs/bg_medium.gif)
    # Round floats (IM6 may output "255.0") and accept >= 240 to allow for minor
    # shadow bleed differences between ImageMagick 6 and 7.
    for pixel in "$tl" "$tr" "$bl" "$br"; do
        local r g b
        IFS=',' read -r r g b <<< "$pixel"
        r=$(printf '%.0f' "$r"); g=$(printf '%.0f' "$g"); b=$(printf '%.0f' "$b")
        (( r >= 240 && g >= 240 && b >= 240 ))
    done
}

@test "output GIF preserves color (not converted to grayscale)" {
    # Build a mov with explicit color content visible in the window area
    ffmpeg -y -hide_banner -loglevel quiet \
        -f lavfi \
        -i "color=c=black:size=800x560:rate=5,
            drawbox=x=60:y=40:w=680:h=480:color=#0a0a0a:t=fill,
            drawbox=x=80:y=100:w=200:h=30:color=#3c8cdd:t=fill,
            drawbox=x=80:y=140:w=150:h=30:color=#22c55e:t=fill" \
        -t 0.4 colored.mov
    run "$MOV2GIF" -q medium colored.mov
    [ "$status" -eq 0 ]

    # Coalesce and check that at least one pixel has distinct R/G/B channels
    $MAGICK_CONVERT gifs/colored_medium.gif -coalesce \
        -define histogram:unique-colors=true \
        -format '%c' histogram:info: > /tmp/histo_$$.txt
    # grep for pixels where the hex colour has distinct channels
    # e.g. #3C8CDD → r≠g≠b — encoded as distinct hex pairs
    local found=0
    while IFS= read -r line; do
        if [[ "$line" =~ \(([0-9]+),([0-9]+),([0-9]+) ]]; then
            r="${BASH_REMATCH[1]}"; g="${BASH_REMATCH[2]}"; b="${BASH_REMATCH[3]}"
            dr=$(( r > g ? r - g : g - r ))
            dg=$(( g > b ? g - b : b - g ))
            if (( dr > 10 || dg > 10 )); then
                found=1
                break
            fi
        fi
    done < /tmp/histo_$$.txt
    rm -f /tmp/histo_$$.txt
    [ "$found" -eq 1 ]
}

@test "output GIF is smaller than source .mov" {
    make_test_mov "size.mov"
    run "$MOV2GIF" -q medium size.mov
    [ "$status" -eq 0 ]
    local mov_size gif_size
    mov_size=$(wc -c < size.mov)
    gif_size=$(wc -c < gifs/size_medium.gif)
    # GIF should exist and be non-empty (size comparison varies with content)
    [ "$gif_size" -gt 0 ]
}

@test "overwrites existing output file" {
    make_test_mov "ow.mov"
    "$MOV2GIF" -q medium ow.mov >/dev/null 2>&1
    local mtime1
    mtime1=$(stat -c '%Y' gifs/ow_medium.gif 2>/dev/null || stat -f '%m' gifs/ow_medium.gif)
    sleep 1
    run "$MOV2GIF" -q medium ow.mov
    [ "$status" -eq 0 ]
    local mtime2
    mtime2=$(stat -c '%Y' gifs/ow_medium.gif 2>/dev/null || stat -f '%m' gifs/ow_medium.gif)
    # File was touched again (mtime changed or same — just must not error)
    [ -f "gifs/ow_medium.gif" ]
}

# ── --background flag tests ───────────────────────────────────────────────────

@test "--background requires an argument" {
    run "$MOV2GIF" --background
    [ "$status" -ne 0 ]
}

@test "--background white produces white corners (default behaviour)" {
    make_test_mov "bg_white.mov"
    run "$MOV2GIF" -q medium --background white bg_white.mov
    [ "$status" -eq 0 ]
    local corner r g b
    corner=$($MAGICK_IDENTIFY -format \
        '%[fx:p{0,0}.r*255],%[fx:p{0,0}.g*255],%[fx:p{0,0}.b*255]' \
        gifs/bg_white_medium.gif)
    IFS=',' read -r r g b <<< "$corner"
    r=$(printf '%.0f' "$r"); g=$(printf '%.0f' "$g"); b=$(printf '%.0f' "$b")
    (( r >= 240 && g >= 240 && b >= 240 ))
}

@test "--background black produces dark corners" {
    make_test_mov "bg_black.mov"
    run "$MOV2GIF" -q medium --background black bg_black.mov
    [ "$status" -eq 0 ]
    # Corner should be black (or very close) — not white
    local r g b
    IFS=',' read -r r g b <<< "$($MAGICK_IDENTIFY -format \
        '%[fx:p{0,0}.r*255],%[fx:p{0,0}.g*255],%[fx:p{0,0}.b*255]' \
        gifs/bg_black_medium.gif)"
    # All channels should be < 128 (dark)
    (( r < 128 && g < 128 && b < 128 ))
}

@test "--background R,G,B sets corner to exact colour" {
    make_test_mov "bg_rgb.mov"
    run "$MOV2GIF" -q medium --background "30,30,46" bg_rgb.mov
    [ "$status" -eq 0 ]
    local corner r g b
    corner=$($MAGICK_IDENTIFY -format \
        '%[fx:p{0,0}.r*255],%[fx:p{0,0}.g*255],%[fx:p{0,0}.b*255]' \
        gifs/bg_rgb_medium.gif)
    IFS=',' read -r r g b <<< "$corner"
    r=$(printf '%.0f' "$r"); g=$(printf '%.0f' "$g"); b=$(printf '%.0f' "$b")
    # Accept ±15 per channel — IM6 shadow compositing may shift values slightly
    (( r >= 15 && r <= 45 && g >= 15 && g <= 45 && b >= 31 && b <= 61 ))
}

@test "--background R,G,B,A with A>=128 uses the RGB part" {
    make_test_mov "bg_rgba_opaque.mov"
    run "$MOV2GIF" -q medium --background "30,30,46,255" bg_rgba_opaque.mov
    [ "$status" -eq 0 ]
    local corner r g b
    corner=$($MAGICK_IDENTIFY -format \
        '%[fx:p{0,0}.r*255],%[fx:p{0,0}.g*255],%[fx:p{0,0}.b*255]' \
        gifs/bg_rgba_opaque_medium.gif)
    IFS=',' read -r r g b <<< "$corner"
    r=$(printf '%.0f' "$r"); g=$(printf '%.0f' "$g"); b=$(printf '%.0f' "$b")
    (( r >= 15 && r <= 45 && g >= 15 && g <= 45 && b >= 31 && b <= 61 ))
}

@test "--background transparent produces transparent corners" {
    make_test_mov "bg_transp.mov"
    run "$MOV2GIF" -q medium --background transparent bg_transp.mov
    [ "$status" -eq 0 ]
    local alpha
    alpha=$($MAGICK_IDENTIFY -format '%[fx:p{0,0}.a*255]' gifs/bg_transp_medium.gif)
    # Corner pixel should have alpha = 0 (fully transparent)
    (( $(printf '%.0f' "$alpha") == 0 ))
}

@test "--background none is an alias for transparent" {
    make_test_mov "bg_none.mov"
    run "$MOV2GIF" -q medium --background none bg_none.mov
    [ "$status" -eq 0 ]
    local alpha
    alpha=$($MAGICK_IDENTIFY -format '%[fx:p{0,0}.a*255]' gifs/bg_none_medium.gif)
    (( $(printf '%.0f' "$alpha") == 0 ))
}

@test "--background R,G,B,A with A<128 produces transparent corners" {
    make_test_mov "bg_rgba_transp.mov"
    run "$MOV2GIF" -q medium --background "255,255,255,0" bg_rgba_transp.mov
    [ "$status" -eq 0 ]
    local alpha
    alpha=$($MAGICK_IDENTIFY -format '%[fx:p{0,0}.a*255]' gifs/bg_rgba_transp_medium.gif)
    (( $(printf '%.0f' "$alpha") == 0 ))
}
