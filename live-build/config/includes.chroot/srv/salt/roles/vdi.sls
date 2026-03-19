# roles/vdi.sls — VDI streaming node (Wayland + FFmpeg/SRT + mediamtx)
# NVIDIA GPU acceleration enabled when grain nvidia: true is set
include:
  - roles.common

vdi_packages:
  pkg.installed:
    - pkgs:
      - ffmpeg
      - libsrt1.5
      - pipewire
      - wireplumber
      - mutter
      - gnome-session
      - xdotool
      - xclip
      - python3-websockets
      - evemu-tools
      - nginx
      - wf-recorder

{% if grains.get('nvidia', False) %}
nvidia_packages:
  pkg.installed:
    - pkgs:
      - nvidia-driver
      - nvidia-cuda-toolkit
      - libnvidia-encode1

nvidia-persistenced:
  service.running:
    - enable: True
    - require:
      - pkg: nvidia_packages
{% endif %}

mediamtx_binary:
  cmd.run:
    - name: |
        DL=$(curl -sL https://api.github.com/repos/bluenviron/mediamtx/releases/latest \
          | grep -o '"browser_download_url":"[^"]*linux_amd64\.tar\.gz"' \
          | cut -d'"' -f4)
        curl -sL "${DL}" | tar -xz -C /usr/local/bin mediamtx
        chmod +x /usr/local/bin/mediamtx
    - unless: test -x /usr/local/bin/mediamtx
    - require:
      - pkg: vdi_packages

mediamtx:
  service.running:
    - enable: True
    - require:
      - cmd: mediamtx_binary

nginx:
  service.running:
    - enable: True
    - require:
      - pkg: vdi_packages
