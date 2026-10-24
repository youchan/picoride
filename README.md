# PicoRuby/FemtoRuby IDE for ESP32 / Raspberry Pi Pico

This is PicoRuby/FemtoRuby development environment for ESP32 and Raspberry Pi Pico
(R2P2-ESP32 / R2P2).
This IDE can do as following

- Edit source codes(.c .h .rb) for mrbgem as a project
- Build image
- Install image to your device

## Setup

The app itself runs natively on your machine (Ruby). Docker is only used to run
the firmware builds, so you need Docker installed and running.

```bash
gem install picoride   # or: bundle install (when working from a clone)
```

The builder images are published on Docker Hub, one per target family:

| Target (Settings dialog)                | Image                                       |
|-----------------------------------------|---------------------------------------------|
| `esp32*`                                | `youchan/picoride-builder-esp32:<version>`  |
| `pico` / `pico_w` / `pico2` / `pico2_w` | `youchan/picoride-builder-pico:<version>`   |

`<version>` is the picoride gem version, so a given gem always uses the image it
was tested with. You don't need to do anything up front: the first build pulls
the image automatically (progress shows up in the build log; it's a few GB).
To fetch it ahead of time:

```bash
docker pull youchan/picoride-builder-pico:0.1.0
docker pull youchan/picoride-builder-esp32:0.1.0
```

(`rake docker:images` prints the exact names for your version.)

To use a locally built image instead, set `PICORIDE_ESP32_BUILDER_IMAGE` /
`PICORIDE_PICO_BUILDER_IMAGE` to its name. If the pull fails (offline, or an
unreleased version), the build log tells you the `docker build` command to run;
the Dockerfiles live in `docker/esp32` and `docker/pico` (also inside the
installed gem).

If PicoRuby bumps its required pico-sdk version, the Pico build stops with
"pico-sdk X is not checked out!". Until a new picoride release ships an updated
image, build one yourself with
`docker build --build-arg PICO_SDK_VERSION=X -t my-pico-builder docker/pico`
and point `PICORIDE_PICO_BUILDER_IMAGE=my-pico-builder` at it.

### Publishing the builder images (maintainers)

Pushing a `v*` tag runs `.github/workflows/docker.yml`, which builds both
images for `linux/amd64` and `linux/arm64` and pushes `:<version>` and
`:latest`. The tag must match `Picoride::VERSION`. It needs the repository
secrets `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` (a Docker Hub access token
with Read & Write). It can also be run by hand from the Actions tab.

To publish from your own machine instead:

```bash
docker login
rake docker:push            # both families, multi-arch
rake docker:push[pico]      # just one
rake docker:build           # local build only (current architecture)
```

`PICORIDE_DOCKER_NAMESPACE` changes the Docker Hub namespace (default
`youchan`) for both the server and these tasks.

### Raspberry Pi Pico notes

- A Pico build produces a `.uf2`. Use "UF2をダウンロード" in the menu bar, then
  hold BOOTSEL while plugging in the Pico and copy the file to the drive that
  appears (`RPI-RP2` / `RP2350`).
- Unlike ESP32, `app/` is not baked into the firmware. Transfer it with
  "app/ をアップロード" on the Terminal tab.
- `pico` / `pico_w` (RP2040) support only FemtoRuby (mruby/c);
  `pico2` / `pico2_w` support both FemtoRuby and PicoRuby (mruby).

## Run

```bash
./bin/server
```

Open http://localhost:4567 . On first load, open a project via File > Open
Project (or the dropdown in the menu bar) and browse to, or create, a
directory on disk — it gets an `app/` and `build_config.rb` automatically.
Opened projects are remembered in `~/.picoride/project.toml`, so the last one
you had open reopens automatically on the next server start.

## Troubleshooting

### `Failed to execute 'open' on 'SerialPort': Failed to open serial port.`

This happens when connecting to the device from the Terminal tab (Web Serial
API). On Linux, check `chrome://device-log` right after the failed attempt to
see the actual OS-level error:

- **`FILE_ERROR_ACCESS_DENIED`**: your user isn't (yet) in the `dialout` group
  with an active session, so the browser process can't open `/dev/ttyACM*` /
  `/dev/ttyUSB*`.
  ```bash
  sudo usermod -aG dialout $USER
  ```
  Adding yourself to the group is not enough by itself — an already-running
  login session (and any browser already open in it) still has the old group
  list. **Log out and back in (or reboot)** so the new group membership takes
  effect, then try connecting again.
- If the port isn't held by anything and permissions look right but it still
  fails, check whether another process/service is holding the port open:
  `sudo lsof /dev/ttyACM0` (or `/dev/ttyUSB0`), and whether `ModemManager` or
  `brltty` is running and probing it (`systemctl status ModemManager brltty`).

