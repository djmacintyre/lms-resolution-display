# ResolutionDisplay — Audio Resolution for LMS Player Displays

An LMS plugin that adds title format tokens for displaying audio source resolution
and decode resolution on Squeezebox Classic, Transporter, Boom, and all other players.

## How it works

Rather than replacing the Now Playing screensaver, this plugin registers
**title format tokens** that integrate with the existing display system.
Resolution info works everywhere title formats are used:

- The built-in Now Playing screensaver
- MusicInfoSCR (Music Information Screen)
- The web interface
- Material Skin
- Any controller that renders title formats

## Available tokens

| Token              | Example output                                    | Notes |
|--------------------|---------------------------------------------------|-------|
| `RESOLUTION`       | `24/96 FLAC`, `DSD128`, `320kbps MP3`            | Source resolution — bit depth, rate, codec |
| `BITDEPTH`         | `24`, `16`, `1`                                   | Bit depth only (1 for DSD) |
| `SAMPLERATE_KHZ`   | `44.1`, `96`, `192`                               | Sample rate in kHz only |
| `SOURCEFORMAT`     | `FLAC`, `MP3`, `ALAC`, `DSF`                     | Codec name only |
| `DECODE_RESOLUTION`| `24/192>96 FLAC`, `24/96● FLAC`                  | What the DAC actually receives — see below |
| `DECODE_RES_SHORT` | `192>96`, `96`, `16/44.1`                         | Compact variant of DECODE_RESOLUTION for narrow displays |

**Important**: `RESOLUTION`, `BITDEPTH`, `SAMPLERATE_KHZ`, and `SOURCEFORMAT` show
**source file or stream metadata** — the resolution as reported by the file or streaming
service, not necessarily what the player's DAC receives. Use `DECODE_RESOLUTION` or
`DECODE_RES_SHORT` to see what is actually being decoded.

## Source vs. decode resolution

When a player's hardware cannot handle the source rate, LMS resamples before sending
to the player. For example, the Transporter's DAC has a hardware limit of **96kHz**
(`Slim::Player::Transporter::maxSupportedSamplerate()`). Playing a Qobuz 24/192 FLAC
stream causes LMS to downsample to 96kHz; the source reports 192kHz but the DAC
receives 96kHz.

`DECODE_RESOLUTION` shows this accurately:

| Situation | `RESOLUTION` | `DECODE_RESOLUTION` |
|-----------|-------------|---------------------|
| 24/192, player limit 96kHz | `24/192 FLAC` | `24/192>96 FLAC` |
| 24/96, player limit 96kHz | `24/96 FLAC` | `24/96● FLAC` |
| 24/44.1, any player | `24/44.1 FLAC` | `24/44.1● FLAC` |

The `●` symbol indicates bit-perfect delivery (source rate ≤ player limit). On VFD
displays that cannot render Unicode, it falls back to `*`.

### Frequency family correction

LMS preserves frequency family when downsampling. A 44.1kHz-family source (44.1, 88.2,
176.4, 352.8kHz) is never downsampled to a 48kHz-family rate. If a player's limit is
48kHz, a 176.4kHz source is decoded at 44.1kHz, not 48kHz. Both tokens reflect this:
`24/176.4>44.1 FLAC`.

## DECODE_RES_SHORT

A compact variant designed for narrow VFD overlays (e.g. SB3 Classic 40-char display).

| Source | Player limit | Output |
|--------|-------------|--------|
| 24/192 FLAC | 96kHz | `192>96` |
| 24/96 FLAC | 96kHz | `96` |
| 16/44.1 FLAC | any | `16/44.1` |
| 24/88.2 FLAC | 48kHz | `88.2>44.1` |
| DSD128 | — | `D128` |
| 320kbps MP3 | — | `320k` |

Format rules:
- PCM: rate in kHz; `>decoded` appended only when downsampling occurs
- `16/` prefix shown only for 16-bit content (flags CD-quality material)
- Bit-perfect delivery is indicated by **absence of `>`** — no symbol needed
- DSD: compact multiplier (`D64`, `D128`, `D256`)
- Lossy: bitrate with `k` suffix (`320k`, `128k`)

## Installation

### Manual installation

1. Copy the `ResolutionDisplay` directory to `/usr/share/squeezeboxserver/Plugins/`
   (on Debian/Raspbian — this path is in LMS's plugin scan list).

   Do **not** use `/var/lib/squeezeboxserver/cache/InstalledPlugins/Plugins/` —
   that directory is managed by LMS's Extension Downloader and will be overwritten.

2. Set ownership:
   ```bash
   sudo chown -R squeezeboxserver:nogroup /usr/share/squeezeboxserver/Plugins/ResolutionDisplay
   ```

3. Restart LMS:
   ```bash
   sudo systemctl restart lyrionmusicserver.service
   ```

4. Confirm it loaded:
   ```bash
   sudo grep -i resolutiondisplay /var/log/squeezeboxserver/server.log
   ```
   You should see:
   ```
   ResolutionDisplay plugin initialised - tokens: RESOLUTION, BITDEPTH, SAMPLERATE_KHZ, SOURCEFORMAT, DECODE_RESOLUTION, DECODE_RES_SHORT
   ```

5. Add the tokens you want to use to LMS's title format list:
   **Settings → Advanced → Formatting → Song Display Formats** — add entries like
   `DECODE_RESOLUTION` and `DECODE_RES_SHORT` so they appear in display element
   dropdowns in MusicInfoSCR and similar plugins.

## Usage

### With MusicInfoSCR (recommended)

Set a display element (e.g. `overlayB`) to one of the resolution tokens.
A recommended setup for Classic/Transporter:

```
Line A:  [Radiohead                  192>96]   ← overlayB: DECODE_RES_SHORT
Line B:  [The National Anthem ████ 4:12]       ← overlayA: PROGRESSBAR PLAYTIME_ALWAYS
```

Or with the full token if space allows:

```
overlayB: DECODE_RESOLUTION   →   24/192>96 FLAC
```

### Display width guide

| Player | Display | Recommended token |
|--------|---------|-------------------|
| Classic | 320×32, ~40 chars | `DECODE_RES_SHORT` as overlay |
| Transporter | 320×32, ~40 chars | `DECODE_RES_SHORT` or `DECODE_RESOLUTION` as overlay |
| Boom | 160×32, ~20 chars | `DECODE_RES_SHORT` |
| Squeezebox 1/2 | 280×16 | `SAMPLERATE_KHZ` or `BITDEPTH` |

### Direct title format use

Tokens can be combined in a title format string:
```
TITLE (DECODE_RESOLUTION)
TITLE [BITDEPTH/SAMPLERATE_KHZ]
ARTIST - TITLE - DECODE_RES_SHORT
```

## Streaming services (Qobuz, etc.)

The plugin handles both local file track objects (`Slim::Schema::Track`) and remote
stream metadata hashrefs. For Qobuz, resolution data is sourced from
`$song->pluginData('samplerate')` and `$song->pluginData('samplesize')`, populated
from the Qobuz API response (`sampling_rate` in kHz, `bit_depth` in bits) during
stream setup.

`DECODE_RESOLUTION` and `DECODE_RES_SHORT` match the playing track to its client by
checking `$song->pluginData('samplerate')` when `currentTrack()->url` is a `qobuz://`
URL (the DB track record does not store samplerate for remote streams).

## Settings

Accessible via **Settings → Plugins → Resolution Display**:

| Setting | Default | Description |
|---------|---------|-------------|
| DSD rate display style | Multiplier | Show DSD64/DSD128 or raw 2.8MHz/5.6MHz |

## Development

### File structure

```
ResolutionDisplay/
├── Plugin.pm          # Core logic: token registration and all handlers
├── Settings.pm        # Web settings page (Slim::Web::Settings subclass)
├── strings.txt        # LMS string table (tab-indented: KEY\n\tLANG\tValue)
├── install.xml        # Plugin metadata — must use <extension> root element
├── HTML/
│   └── EN/plugins/ResolutionDisplay/settings/basic.html
└── README.md
```

### Key LMS APIs used

**Token registration:**
```perl
Slim::Music::TitleFormatter::addFormat($name, \&handler, 1);
# $nocache = 1: re-evaluated on every display update, not cached per track
```

**Track handler inputs** — handlers receive either a `Slim::Schema::Track` object
(local files) or an unblessed metadata hashref (remote streams). Both must be handled.
See `_getFields()` in `Plugin.pm`.

**Relevant accessors:**

| Field | Local file | Qobuz stream hashref |
|-------|-----------|----------------------|
| Sample rate | `$track->samplerate` (Hz) | `$meta->{samplerate}` (Hz) |
| Bit depth | `$track->samplesize` | `$meta->{samplesize}` |
| Codec | `$track->content_type` | `$meta->{type}` or `$meta->{ct}` |
| Bitrate | `$track->bitrate` (bps) | `$meta->{bitrate}` (`"2351kbps"` string) |

**Player capabilities:**
```perl
$client->maxSupportedSamplerate()      # hardware DAC limit
$client->playingSong()                 # current Slim::Player::Song object
$song->currentTrack()                  # Slim::Schema::Track or hashref
$song->pluginData('samplerate')        # kHz value set by protocol handler
$client->syncGroupActiveMembers()      # all members of a sync group
```

### install.xml format

Must use the per-plugin `<extension>` root element:

```xml
<extension>
  <module>Plugins::ResolutionDisplay::Plugin</module>
  <targetApplication>
    <minVersion>9.0</minVersion>
    <maxVersion>*</maxVersion>
  </targetApplication>
  ...
</extension>
```

The repository manifest format (`<extensions><plugins><plugin .../>`) puts `module`
in a nested hash that LMS cannot find, resulting in `INSTALLERROR_NO_MODULE` and
silent skip at load time. `<targetApplication>` with `<minVersion>`/`<maxVersion>`
is required; omitting it causes `INSTALLERROR_INVALID_VERSION`.

### Debugging

```bash
# Enable debug logging at runtime (no restart needed):
printf "debug plugin.resolutiondisplay DEBUG\nexit\n" | nc -q1 localhost 9090

# Capture decode resolution matching for a session:
sudo tail -f /var/log/squeezeboxserver/server.log \
  | grep --line-buffered -i "playerMaxRate" > /tmp/resdisp_debug.log 2>&1 &
# play a track, then: kill %1 && cat /tmp/resdisp_debug.log

# Check raw track metadata for a playing track (replace MAC):
printf "aa:bb:cc:dd:ee:ff status 0 1 tags:ITro\nexit\n" | nc -q1 localhost 9090
# I=samplesize, T=samplerate(Hz), r=bitrate, o=content_type
```

## License

GPL v2 or later (consistent with LMS plugin ecosystem).
