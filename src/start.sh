#!/usr/bin/env bash

# Use libtcmalloc for better memory management
TCMALLOC="$(ldconfig -p | grep -Po "libtcmalloc.so.\d" | head -n 1)"
export LD_PRELOAD="${TCMALLOC}"

# Ensure ComfyUI-Manager runs in offline network mode inside the container
comfy-manager-set-mode offline || echo "worker-comfyui - Could not set ComfyUI-Manager network_mode" >&2

echo "worker-comfyui: Starting ComfyUI"

# Allow operators to tweak verbosity; default is DEBUG.
: "${COMFY_LOG_LEVEL:=DEBUG}"

# Check if Network Volume ComfyUI exists and use it instead of container ComfyUI
echo "worker-comfyui: Starting container..."
COMFYUI_PATH="/comfyui"
if [ -f "/runpod-volume/runpod-slim/ComfyUI/main.py" ]; then
    echo "worker-comfyui: Network Volume ComfyUI found, using it instead of container ComfyUI"
    COMFYUI_PATH="/runpod-volume/runpod-slim/ComfyUI"

    # Copy extra_model_paths.yaml to Network Volume ComfyUI if it doesn't exist
    if [ ! -f "${COMFYUI_PATH}/extra_model_paths.yaml" ]; then
        cp /comfyui/extra_model_paths.yaml ${COMFYUI_PATH}/
        echo "worker-comfyui: Copied extra_model_paths.yaml to Network Volume ComfyUI"
    fi
else
    echo "worker-comfyui: Network Volume ComfyUI not found, using container ComfyUI"
fi

echo "worker-comfyui: ComfyUI path set to: $COMFYUI_PATH"
echo "worker-comfyui: Checking if ComfyUI exists..."
if [ -f "${COMFYUI_PATH}/main.py" ]; then
    echo "worker-comfyui: ComfyUI main.py found"
else
    echo "worker-comfyui: ERROR - ComfyUI main.py not found at ${COMFYUI_PATH}/main.py"
    ls -la ${COMFYUI_PATH}/
fi

# Serve the API and don't shutdown the container
if [ "$SERVE_API_LOCALLY" == "true" ]; then
    python -u ${COMFYUI_PATH}/main.py --disable-auto-launch --disable-metadata --listen --verbose "${COMFY_LOG_LEVEL}" --log-stdout &

    echo "worker-comfyui: Starting RunPod Handler"
    python -u /handler.py --rp_serve_api --rp_api_host=0.0.0.0
else
    echo "worker-comfyui: Starting ComfyUI..."
    python -u ${COMFYUI_PATH}/main.py --disable-auto-launch --disable-metadata --verbose "${COMFY_LOG_LEVEL}" --log-stdout &

    echo "worker-comfyui: Waiting 10 seconds for ComfyUI to start..."
    sleep 10

    # Check if ComfyUI process is still running
    if ps aux | grep -v grep | grep "main.py" > /dev/null; then
        echo "worker-comfyui: ComfyUI process is running"
    else
        echo "worker-comfyui: ERROR - ComfyUI process died!"
        echo "worker-comfyui: Checking ComfyUI logs..."
        # Try to show any error logs
        ls -la ${COMFYUI_PATH}/
        exit 1
    fi

    echo "worker-comfyui: Starting RunPod Handler"
    python -u /handler.py
fi