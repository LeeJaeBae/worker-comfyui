#!/usr/bin/env bash

# Use libtcmalloc for better memory management
TCMALLOC="$(ldconfig -p | grep -Po "libtcmalloc.so.\d" | head -n 1)"
export LD_PRELOAD="${TCMALLOC}"

# ---------------------------------------------------------------------------
# Optional: use a Python virtualenv stored on the Network Volume (runpod-slim).
#
# Example: /runpod-volume/runpod-slim/ComfyUI/.venv-cu128
#
# Enabled by default:
#   USE_IMPORTED_VENV=true
# Optionally override:
#   IMPORTED_VENV_PATH=/runpod-volume/runpod-slim/ComfyUI/.venv-cu128
# ---------------------------------------------------------------------------
: "${USE_IMPORTED_VENV:=true}"
if [ "${USE_IMPORTED_VENV}" = "true" ]; then
    IMPORTED_VENV_PATH="${IMPORTED_VENV_PATH:-/runpod-volume/runpod-slim/ComfyUI/.venv-cu128}"
    if [ -x "$IMPORTED_VENV_PATH/bin/python" ]; then
        echo "worker-comfyui: Using imported venv: $IMPORTED_VENV_PATH"
        export VIRTUAL_ENV="$IMPORTED_VENV_PATH"
        export PATH="$IMPORTED_VENV_PATH/bin:${PATH}"
    else
        echo "worker-comfyui: WARNING - USE_IMPORTED_VENV=true but no executable python at: $IMPORTED_VENV_PATH/bin/python" >&2
    fi
fi

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

    # Optional: install Python deps for volume-provided custom nodes.
    # Enabled by default:
    #   INSTALL_CUSTOM_NODE_REQUIREMENTS=true
    : "${INSTALL_CUSTOM_NODE_REQUIREMENTS:=true}"
    if [ "${INSTALL_CUSTOM_NODE_REQUIREMENTS}" = "true" ]; then
        echo "worker-comfyui: INSTALL_CUSTOM_NODE_REQUIREMENTS=true (installing requirements.txt for linked custom nodes)"

        # Persistent marker directory (so we don't reinstall on every cold start).
        CUSTOM_NODE_STATE_DIR="${CUSTOM_NODE_STATE_DIR:-/runpod-volume/.runpod-worker-comfyui}"
        if ! mkdir -p "$CUSTOM_NODE_STATE_DIR" 2>/dev/null; then
            CUSTOM_NODE_STATE_DIR="/tmp/.runpod-worker-comfyui"
            mkdir -p "$CUSTOM_NODE_STATE_DIR" || true
        fi
        REQ_MARKER_DIR="$CUSTOM_NODE_STATE_DIR/custom_node_requirements"
        mkdir -p "$REQ_MARKER_DIR" || true

        for node_dir in /comfyui/custom_nodes/*; do
            [ -d "$node_dir" ] || continue
            req_file="$node_dir/requirements.txt"
            if [ -f "$req_file" ]; then
                node_name="$(basename "$node_dir")"
                marker_file="$REQ_MARKER_DIR/${node_name}.installed"
                if [ -f "$marker_file" ]; then
                    echo "worker-comfyui: requirements already installed for $node_name (marker found)"
                    continue
                fi
                echo "worker-comfyui: Installing custom node requirements: $req_file"
                # Don't hard-fail the container if a single node has bad requirements.
                if python -m pip install -r "$req_file"; then
                    touch "$marker_file" 2>/dev/null || true
                else
                    echo "worker-comfyui: WARNING - failed installing requirements for $node_dir" >&2
                fi
            fi
        done
    fi
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