#!/usr/bin/env bash

# Use libtcmalloc for better memory management
TCMALLOC="$(ldconfig -p | grep -Po "libtcmalloc.so.\d" | head -n 1)"
export LD_PRELOAD="${TCMALLOC}"

# Ensure ComfyUI-Manager runs in offline network mode inside the container
comfy-manager-set-mode offline || echo "worker-comfyui - Could not set ComfyUI-Manager network_mode" >&2

# ---------------------------------------------------------------------------
# Optional: link custom nodes from a RunPod network volume that contains a full
# ComfyUI directory (runpod-slim layout).
#
# Expected:
#   /runpod-volume/runpod-slim/ComfyUI/custom_nodes/<node_repo>
#
# We symlink each child into /comfyui/custom_nodes so that ComfyUI discovers it.
# ---------------------------------------------------------------------------
IMPORTED_COMFYUI_DIR="${IMPORTED_COMFYUI_DIR:-/runpod-volume/runpod-slim/ComfyUI}"

if [ -d "$IMPORTED_COMFYUI_DIR/custom_nodes" ]; then
    echo "worker-comfyui: Detected imported custom_nodes at: $IMPORTED_COMFYUI_DIR/custom_nodes"
    mkdir -p /comfyui/custom_nodes

    for node_path in "$IMPORTED_COMFYUI_DIR"/custom_nodes/*; do
        # Handle empty globs safely
        [ -e "$node_path" ] || continue

        node_name="$(basename "$node_path")"
        dest="/comfyui/custom_nodes/$node_name"

        # Don't overwrite anything baked into the image
        if [ -e "$dest" ]; then
            echo "worker-comfyui: custom node already exists, skipping: $dest" >&2
            continue
        fi

        ln -s "$node_path" "$dest"
        echo "worker-comfyui: linked custom node: $node_name"
    done
fi

echo "worker-comfyui: Starting ComfyUI"

# Allow operators to tweak verbosity; default is DEBUG.
: "${COMFY_LOG_LEVEL:=DEBUG}"

# Serve the API and don't shutdown the container
if [ "$SERVE_API_LOCALLY" == "true" ]; then
    python -u /comfyui/main.py --disable-auto-launch --disable-metadata --listen --verbose "${COMFY_LOG_LEVEL}" --log-stdout &

    echo "worker-comfyui: Starting RunPod Handler"
    python -u /handler.py --rp_serve_api --rp_api_host=0.0.0.0
else
    python -u /comfyui/main.py --disable-auto-launch --disable-metadata --verbose "${COMFY_LOG_LEVEL}" --log-stdout &

    echo "worker-comfyui: Starting RunPod Handler"
    python -u /handler.py
fi