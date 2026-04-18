package Plugins::ResolutionDisplay::Plugin;

# ResolutionDisplay - Adds audio resolution title format tokens to LMS
#
# Title format tokens registered:
#   RESOLUTION        - "24/96 FLAC" or "DSD64" or "320kbps MP3"
#   BITDEPTH          - "24" (bit depth only)
#   SAMPLERATE_KHZ    - "96" or "44.1" (sample rate in kHz)
#   SOURCEFORMAT      - "FLAC" or "MP3" or "DSF" (codec name only)
#   DECODE_RESOLUTION - "24/96* FLAC" (bit-perfect) or "24/192>96 FLAC" (downsampled)
#   DECODE_RES_SHORT  - "96*" (bit-perfect) or "192>96" (downsampled) -- compact, SB3-friendly
#                       "24/44*" / "16/44*" at 44.1kHz (only rate where 16-bit is common)
#   SIGNAL_PCT        - "87%" or empty (wireless signal strength, 0-100)
#   SIGNAL_BARS       - single-char bar glyph or ASCII bucket for signal strength
#   BUFFER_PCT        - "95%" (decode buffer fullness)
#   HEALTH            - "●"/"◐"/"○" or "OK"/"!"/"!!" composite health indicator
#   HEALTH_LINE       - "W87 B95" two-metric combo for narrow overlays
#
# These tokens can be used in:
#   - Server Settings > Formatting > Title Format definitions
#   - MusicInfoSCR screensaver configuration
#   - Any other context that uses LMS title formats

use strict;
use warnings;

use base qw(Slim::Plugin::Base);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Slim::Music::TitleFormatter;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.resolutiondisplay',
	'defaultLevel' => 'WARN',
	'description'  => 'PLUGIN_RESOLUTION_DISPLAY',
});

my $prefs = preferences('plugin.resolutiondisplay');

# Codec display name mapping: internal content_type -> human-readable
# LMS uses short lowercase codes internally (e.g. 'flc' for FLAC)
my %CODEC_NAMES = (
	'flc'  => 'FLAC',
	'flac' => 'FLAC',
	'alc'  => 'ALAC',
	'aac'  => 'AAC',
	'mp3'  => 'MP3',
	'mp2'  => 'MP2',
	'ogg'  => 'OGG',
	'ops'  => 'Opus',
	'wav'  => 'WAV',
	'aif'  => 'AIFF',
	'wma'  => 'WMA',
	'wmap' => 'WMA',
	'wmal' => 'WMA-L',
	'ape'  => 'APE',
	'mpc'  => 'MPC',
	'wvp'  => 'WV',
	'dsf'  => 'DSF',
	'dff'  => 'DFF',
	'pcm'  => 'PCM',
);

# DSD base rate for multiplier calculation
use constant DSD_BASE_RATE => 2822400;


sub initPlugin {
	my $class = shift;

	$class->SUPER::initPlugin(@_);

	# Set preference defaults
	$prefs->init({
		showLossless  => 0,
		shortFormat   => 0,
		dsdStyle      => 'multiplier',  # 'multiplier' or 'raw'
		signalWarnPct => 40,
		signalGoodPct => 60,
		bufferWarnPct => 50,
		healthGlyphs  => 1,
	});

	# Ensure all our tokens appear in the server titleFormat list so they show
	# up in MusicInfoSCR's token picker (which reads that pref for its dropdown).
	my $serverPrefs = preferences('server');
	my $titleFormats = $serverPrefs->get('titleFormat') || [];
	my %existing = map { $_ => 1 } @$titleFormats;
	my @ours = qw(
		RESOLUTION BITDEPTH SAMPLERATE_KHZ SOURCEFORMAT
		DECODE_RESOLUTION DECODE_RES_SHORT
		SIGNAL_PCT SIGNAL_BARS BUFFER_PCT HEALTH HEALTH_LINE
	);
	my $added = 0;
	for my $token (@ours) {
		unless ($existing{$token}) {
			push @$titleFormats, $token;
			$added++;
		}
	}
	$serverPrefs->set('titleFormat', $titleFormats) if $added;

	# Register title format tokens
	# Each token maps to a subroutine that receives a track object
	# and returns a string for display.

	Slim::Music::TitleFormatter::addFormat('RESOLUTION', \&_formatResolution, 1);
	Slim::Music::TitleFormatter::addFormat('BITDEPTH', \&_formatBitDepth, 1);
	Slim::Music::TitleFormatter::addFormat('SAMPLERATE_KHZ', \&_formatSampleRateKHz, 1);
	Slim::Music::TitleFormatter::addFormat('SOURCEFORMAT', \&_formatSourceFormat, 1);
	Slim::Music::TitleFormatter::addFormat('DECODE_RESOLUTION', \&_formatDecodeResolution, 1);
	Slim::Music::TitleFormatter::addFormat('DECODE_RES_SHORT',  \&_formatDecodeResShort,  1);
	Slim::Music::TitleFormatter::addFormat('SIGNAL_PCT',   \&_formatSignalPct,   1);
	Slim::Music::TitleFormatter::addFormat('SIGNAL_BARS',  \&_formatSignalBars,  1);
	Slim::Music::TitleFormatter::addFormat('BUFFER_PCT',   \&_formatBufferPct,   1);
	Slim::Music::TitleFormatter::addFormat('HEALTH',       \&_formatHealth,       1);
	Slim::Music::TitleFormatter::addFormat('HEALTH_LINE',  \&_formatHealthLine,  1);

	$log->info("ResolutionDisplay plugin initialised - tokens: RESOLUTION, BITDEPTH, SAMPLERATE_KHZ, SOURCEFORMAT, DECODE_RESOLUTION, DECODE_RES_SHORT, SIGNAL_PCT, SIGNAL_BARS, BUFFER_PCT, HEALTH, HEALTH_LINE");
}

sub getDisplayName {
	return 'PLUGIN_RESOLUTION_DISPLAY';
}

sub shutdownPlugin {
	# Title formats persist until server restart; no explicit cleanup needed
}

# ============================================================================
# Title Format Handlers
#
# Each receives either a Slim::Schema::Track object (local files) or an
# unblessed hashref of metadata (remote streams such as Qobuz). Both cases
# must be handled -- use _getFields() to extract values uniformly.
# ============================================================================

# Extract the four fields we need from either a track object or a meta hashref.
# Returns: ($content_type, $samplerate_hz, $samplesize_bits, $bitrate_bps)
#
# Remote stream meta hashes (e.g. Qobuz) store bitrate as a pre-formatted
# string like "2351kbps"; we parse that back to bps here so the rest of the
# logic stays numeric.
sub _getFields {
	my $track = shift;

	if (ref $track eq 'HASH') {
		my $raw = $track->{bitrate} // 0;
		my $bps = ($raw =~ /^(\d+)\s*kbps$/i) ? $1 * 1000 : ($raw + 0);
		return (
			$track->{content_type} || $track->{type} || $track->{ct} || '',
			$track->{samplerate}   || 0,
			$track->{samplesize}   || 0,
			$bps,
		);
	}

	return (
		$track->content_type || '',
		$track->samplerate   || 0,
		$track->samplesize   || 0,
		$track->bitrate      || 0,
	);
}

sub _formatResolution {
	my $track = shift;
	return '' unless $track;

	my ($ct, $samplerate, $samplesize, $bitrate) = _getFields($track);

	# Handle DSD formats specially
	if (_isDSD($ct)) {
		return _formatDSD($ct, $samplerate);
	}

	my $codec = _codecName($ct);

	# For PCM-based formats: show bit_depth/sample_rate codec
	if ($samplerate && $samplesize) {
		my $rateStr = _rateToKHz($samplerate);
		return "${samplesize}/${rateStr} ${codec}";
	}

	# Lossy formats without sample size: show bitrate + codec
	if ($bitrate && !$samplesize) {
		my $brStr = _formatBitrate($bitrate);
		return "${brStr} ${codec}";
	}

	# Fallback: show bitrate/samplerate + codec if we have partial info
	if ($samplerate) {
		my $rateStr = _rateToKHz($samplerate);
		return "${rateStr}kHz ${codec}";
	}

	if ($bitrate) {
		my $brStr = _formatBitrate($bitrate);
		return "${brStr} ${codec}";
	}

	# Last resort: just the codec name
	return $codec if $codec;

	return '';
}

sub _formatBitDepth {
	my $track = shift;
	return '' unless $track;

	my ($ct, undef, $samplesize) = _getFields($track);
	return '' unless $samplesize;

	# DSD: report as 1-bit
	return '1' if _isDSD($ct);

	return "$samplesize";
}

sub _formatSampleRateKHz {
	my $track = shift;
	return '' unless $track;

	my (undef, $samplerate) = _getFields($track);
	return '' unless $samplerate;

	return _rateToKHz($samplerate);
}

sub _formatSourceFormat {
	my $track = shift;
	return '' unless $track;

	my ($ct) = _getFields($track);
	return _codecName($ct);
}

# DECODE_RESOLUTION token handler.
#
# For PCM lossless, appends a bit-perfect indicator (U+25CF ●) when the source
# rate fits within the playing player's hardware limit, or shows "src>decoded"
# (e.g. "24/192>96") when LMS is downsampling.
#
# For lossy and DSD, falls back to the same output as RESOLUTION -- decode
# rate is not meaningful for lossy, and DSD-to-PCM conversion is a separate
# concern.
#
# If no playing client can be matched to this track (e.g. token used in a
# non-playback context), falls back to plain RESOLUTION output with no symbol.
sub _formatDecodeResolution {
	my $track = shift;
	return '' unless $track;

	my ($ct, $samplerate, $samplesize, $bitrate) = _getFields($track);

	# DSD and lossy: no decode-rate concept, same as RESOLUTION
	if (_isDSD($ct)) {
		return _formatDSD($ct, $samplerate);
	}

	my $codec = _codecName($ct);

	if ($samplerate && $samplesize) {
		my $srcStr = _rateToKHz($samplerate);
		my $maxRate = _playerMaxRate($track, $samplerate);

		if (!defined $maxRate) {
			# No client found -- show plain source resolution, no symbol
			return "${samplesize}/${srcStr} ${codec}";
		}

		if ($maxRate < $samplerate) {
			# Downsampling: compute actual decoded rate, preserving frequency family.
			# 44.1kHz-family sources (44.1, 88.2, 176.4, 352.8) must be downsampled
			# to a 44.1kHz-family rate even when the player's limit is a 48kHz-family
			# value -- LMS applies the same ratio correction as CapabilitiesHelper.
			my $decodeRate = $maxRate;
			if (($maxRate % 12000) == 0 && ($samplerate % 11025) == 0) {
				$decodeRate = int($maxRate * 11025 / 12000);
			}
			my $decStr = _rateToKHz($decodeRate);
			return "${samplesize}/${srcStr}>${decStr} ${codec}";
		}

		# Bit-perfect
		return "${samplesize}/${srcStr}* ${codec}";
	}

	# Lossy: show bitrate + codec (same as RESOLUTION)
	if ($bitrate && !$samplesize) {
		return _formatBitrate($bitrate) . " ${codec}";
	}

	if ($samplerate) {
		return _rateToKHz($samplerate) . "kHz ${codec}";
	}

	if ($bitrate) {
		return _formatBitrate($bitrate) . " ${codec}";
	}

	return $codec if $codec;
	return '';
}

# DECODE_RES_SHORT token handler.
#
# Compact variant of DECODE_RESOLUTION for narrow displays (e.g. SB3 Classic).
# Rules:
#   - PCM 44.1kHz: show "{depth}/44" prefix -- the only rate where 16-bit is common
#       bit-perfect:  "24/44*"  "16/44*"
#       downsampled:  "24/44>XX" (unusual -- 44.1kHz fits any player)
#   - PCM other rates: rate only (implied 24-bit)
#       bit-perfect:  "96*"  "192*"
#       downsampled:  "192>96"
#   - DSD: compact multiplier -- "D64", "D128", "D256"
#   - Lossy: bitrate with k suffix -- "320k"
sub _formatDecodeResShort {
	my $track = shift;
	return '' unless $track;

	my ($ct, $samplerate, $samplesize, $bitrate) = _getFields($track);

	# DSD: compact multiplier format D64, D128, etc.
	if (_isDSD($ct)) {
		if ($samplerate) {
			my $multiplier = int(($samplerate / DSD_BASE_RATE) + 0.5);
			$multiplier = 64 * $multiplier if $multiplier > 0;
			return "D${multiplier}" if $multiplier >= 64 && $multiplier <= 1024;
		}
		return 'DSD';
	}

	if ($samplerate && $samplesize) {
		my $maxRate = _playerMaxRate($track, $samplerate);

		# 44.1kHz family (44.1, 88.2, 176.4, 352.8): truncate decimal to integer.
		# Only at exactly 44.1kHz show "{depth}/" prefix -- the one rate where 16-bit is common.
		my ($prefix, $srcStr);
		if ($samplerate == 44100) {
			$prefix = "${samplesize}/";
			$srcStr = "44";
		} elsif ($samplerate % 11025 == 0) {
			$prefix = "";
			$srcStr = int($samplerate / 1000);  # 88200->88, 176400->176, 352800->352
		} else {
			$prefix = "";
			$srcStr = _rateToKHz($samplerate);
		}

		if (!defined $maxRate) {
			return "${prefix}${srcStr}";
		}

		if ($maxRate < $samplerate) {
			my $decodeRate = $maxRate;
			if (($maxRate % 12000) == 0 && ($samplerate % 11025) == 0) {
				$decodeRate = int($maxRate * 11025 / 12000);
			}
			my $decStr = ($decodeRate % 11025 == 0)
				? int($decodeRate / 1000)
				: _rateToKHz($decodeRate);
			return "${prefix}${srcStr}>${decStr}";
		}

		# Bit-perfect
		return "${prefix}${srcStr}*";
	}

	# Lossy: compact bitrate with k suffix
	if ($bitrate) {
		my $k = ($bitrate >= 1000) ? int($bitrate / 1000) : $bitrate;
		return "${k}k";
	}

	if ($samplerate) {
		return _rateToKHz($samplerate);
	}

	return '';
}

# ============================================================================
# Internal helpers
# ============================================================================

sub _isDSD {
	my $ct = shift || '';
	return ($ct eq 'dsf' || $ct eq 'dff');
}

sub _formatDSD {
	my ($ct, $samplerate) = @_;

	my $codec = _codecName($ct);
	my $style = $prefs->get('dsdStyle') || 'multiplier';

	if ($style eq 'multiplier' && $samplerate) {
		# DSD64 = 2.8224 MHz, DSD128 = 5.6448 MHz, etc.
		my $multiplier = int(($samplerate / DSD_BASE_RATE) + 0.5);
		$multiplier = 64 * $multiplier if $multiplier > 0;

		# Sanity check: common values are 64, 128, 256, 512
		if ($multiplier >= 64 && $multiplier <= 1024) {
			return "DSD${multiplier}";
		}
	}

	# Fallback: show raw MHz rate
	if ($samplerate) {
		my $mhz = sprintf("%.1f", $samplerate / 1000000);
		$mhz =~ s/\.0$//;
		return "DSD ${mhz}MHz";
	}

	return $codec;
}

sub _codecName {
	my $ct = shift || '';
	$ct = lc($ct);

	return $CODEC_NAMES{$ct} || uc($ct) || '?';
}

sub _rateToKHz {
	my $rate = shift || 0;

	# Convert Hz to kHz with appropriate precision
	# 44100 -> "44.1", 48000 -> "48", 96000 -> "96", 192000 -> "192"
	my $khz = $rate / 1000;

	if ($khz == int($khz)) {
		return sprintf("%d", $khz);
	} else {
		# Show one decimal place (covers 44.1, 88.2, 176.4, 352.8)
		my $str = sprintf("%.1f", $khz);
		$str =~ s/0$//;  # trim trailing zero if any
		return $str;
	}
}

sub _formatBitrate {
	my $bitrate = shift || 0;

	# LMS stores bitrate in bits/sec; display as kbps
	# Some content already stores it as kbps (with 'kbps' suffix in display)
	if ($bitrate >= 1000) {
		return sprintf("%dkbps", int($bitrate / 1000));
	}
	return "${bitrate}kbps";
}

# Find the effective maximum sample rate for the player(s) currently playing
# this track.  Mirrors the logic in Slim::Player::CapabilitiesHelper::samplerateLimit
# but works from a track object/hashref rather than a song object, since title
# format handlers don't receive client context.
#
# Returns the minimum maxSupportedSamplerate() across all clients whose
# playingSong matches the track, or undef if no match is found.
#
# Matching strategy (in priority order):
#   1. Track object: match by database id
#   2. Any track: match by URL (currentTrack()->url eq track url)
#   3. Samplerate fallback: handles Qobuz streams where the CDN streaming URL
#      seen by this handler differs from currentTrack()->url
#
# For sync groups the minimum rate across members is the binding constraint,
# consistent with how CapabilitiesHelper treats them.
sub _playerMaxRate {
	my ($track, $source_rate) = @_;
	return undef unless $source_rate;

	my $track_id;
	my $track_url;
	if (ref $track eq 'HASH') {
		$track_url = $track->{url};
		$log->debug(sprintf("_playerMaxRate: hashref track  url=%s  source_rate=%d",
			$track_url // '(undef)', $source_rate));
	} else {
		eval { $track_id  = $track->id  };
		eval { $track_url = $track->url };
		$log->debug(sprintf("_playerMaxRate: Track object  id=%s  url=%s  source_rate=%d",
			$track_id // '(undef)', $track_url // '(undef)', $source_rate));
	}

	my $min_max    = undef;  # result from exact (id/url) match
	my $sr_min_max = undef;  # result from samplerate fallback match

	for my $client (Slim::Player::Client::clients()) {
		my $client_name = eval { $client->name } // $client->id;
		my $song = eval { $client->playingSong() };
		unless ($song) {
			$log->debug("_playerMaxRate:   client=$client_name  no playingSong, skip");
			next;
		}
		my $ct = eval { $song->currentTrack() };
		unless ($ct) {
			$log->debug("_playerMaxRate:   client=$client_name  no currentTrack, skip");
			next;
		}

		my $client_max = $client->maxSupportedSamplerate();
		my $ct_id  = eval { $ct->id  } // '';
		my $ct_url = eval { $ct->url } // '';
		my $ct_sr  = eval { $ct->samplerate } // 0;
		$log->debug(sprintf(
			"_playerMaxRate:   client=%s  maxRate=%d  ct.id=%s  ct.url=%s  ct.sr=%d",
			$client_name, $client_max, $ct_id, $ct_url, $ct_sr));

		# Exact match: by id (Track objects) or url
		my $exact = 0;
		if (defined $track_id && $ct_id eq $track_id) {
			$exact = 1;
			$log->debug("_playerMaxRate:     exact match by id");
		} elsif ($track_url && $ct_url eq $track_url) {
			$exact = 1;
			$log->debug("_playerMaxRate:     exact match by url");
		}

		if ($exact) {
			my @members = $client->syncGroupActiveMembers();
			@members = ($client) unless @members;
			for my $member (@members) {
				my $rate        = $member->maxSupportedSamplerate();
				my $member_name = eval { $member->name } // $member->id;
				$log->debug("_playerMaxRate:     sync member=$member_name  maxRate=$rate");
				$min_max = $rate if !defined $min_max || $rate < $min_max;
			}
			next;  # exact match found; skip samplerate fallback for this client
		}

		# Samplerate fallback: used when URL match fails (e.g. Qobuz CDN URL
		# differs from the qobuz:// URL stored in currentTrack).
		if ($ct_sr && $ct_sr == $source_rate) {
			$log->debug("_playerMaxRate:     samplerate fallback match  ct_sr=$ct_sr");
			my @members = $client->syncGroupActiveMembers();
			@members = ($client) unless @members;
			for my $member (@members) {
				my $rate        = $member->maxSupportedSamplerate();
				my $member_name = eval { $member->name } // $member->id;
				$log->debug("_playerMaxRate:     sr-fallback sync member=$member_name  maxRate=$rate");
				$sr_min_max = $rate if !defined $sr_min_max || $rate < $sr_min_max;
			}
		} elsif ($ct_url =~ m{^qobuz://} && $song) {
			# pluginData fallback: Qobuz stores samplerate in kHz in song pluginData;
			# $ct->samplerate is 0 for remote tracks so the check above short-circuits.
			my $pd_sr = eval { $song->pluginData('samplerate') };
			$log->debug(sprintf("_playerMaxRate:     pluginData sr check  pd_sr=%s",
				defined $pd_sr ? $pd_sr : '(undef)'));
			if ($pd_sr) {
				my $pd_sr_hz = int($pd_sr * 1000 + 0.5);  # kHz->Hz, round for 44.1 etc.
				if ($pd_sr_hz == $source_rate) {
					$log->debug("_playerMaxRate:     pluginData sr fallback match  pd_sr=${pd_sr}kHz");
					my @members = $client->syncGroupActiveMembers();
					@members = ($client) unless @members;
					for my $member (@members) {
						my $rate        = $member->maxSupportedSamplerate();
						my $member_name = eval { $member->name } // $member->id;
						$log->debug("_playerMaxRate:     pd-sr sync member=$member_name  maxRate=$rate");
						$sr_min_max = $rate if !defined $sr_min_max || $rate < $sr_min_max;
					}
				} else {
					$log->debug(sprintf("_playerMaxRate:     pluginData sr mismatch  pd_sr_hz=%d  source_rate=%d",
						$pd_sr_hz, $source_rate));
				}
			}
		} else {
			$log->debug(sprintf("_playerMaxRate:     no match  ct_sr=%d  source_rate=%d", $ct_sr, $source_rate));
		}
	}

	# Prefer exact match; use samplerate fallback if needed; undef means unknown
	my $result = defined $min_max ? $min_max : $sr_min_max;
	$log->debug(sprintf("_playerMaxRate: result=%s  (exact=%s  sr_fallback=%s)",
		$result // '(undef)', $min_max // '(undef)', $sr_min_max // '(undef)'));
	return $result;
}

# ============================================================================
# Player Health Token Handlers
#
# NOTE: When multiple players are playing the same track, _findPlayingClient
# returns the first match in client-iteration order. With all-wireless players
# that have meaningfully different signal strengths, each VFD may display the
# value for one player rather than its own. Per-VFD correctness requires
# MusicInfoSCR's custom-tag API (deferred to v0.3).
# For the common case (one player active, others idle) this returns correctly.
# ============================================================================

# Returns ($client, $song) for the first playing client matching this track,
# or (undef, undef) if none found. Uses id/url/samplerate match chain.
sub _findPlayingClient {
	my $track = shift;
	return (undef, undef) unless $track;

	my ($track_id, $track_url, $source_rate);
	if (ref $track eq 'HASH') {
		$track_url   = $track->{url};
		$source_rate = $track->{samplerate} || 0;
	} else {
		eval { $track_id    = $track->id };
		eval { $track_url   = $track->url };
		eval { $source_rate = $track->samplerate || 0 };
	}

	my ($sr_client, $sr_song);

	for my $client (Slim::Player::Client::clients()) {
		my $song = eval { $client->playingSong() };
		next unless $song;
		my $ct = eval { $song->currentTrack() };
		next unless $ct;

		my $ct_id  = eval { $ct->id  } // '';
		my $ct_url = eval { $ct->url } // '';

		# Exact match by id or url
		if ((defined $track_id && $ct_id eq $track_id) ||
			($track_url && $ct_url eq $track_url)) {
			return ($client, $song);
		}

		next if $sr_client;  # already have a fallback candidate

		# Samplerate fallback
		my $ct_sr = eval { $ct->samplerate } // 0;
		if ($source_rate && $ct_sr && $ct_sr == $source_rate) {
			$sr_client = $client;
			$sr_song   = $song;
		} elsif ($ct_url =~ m{^qobuz://} && $source_rate) {
			my $pd_sr = eval { $song->pluginData('samplerate') };
			if ($pd_sr && int($pd_sr * 1000 + 0.5) == $source_rate) {
				$sr_client = $client;
				$sr_song   = $song;
			}
		}
	}

	return ($sr_client, $sr_song);
}

# Returns a single-char indicator for the given 0-100 signal percentage.
sub _signalBucket {
	my ($pct, $glyphs) = @_;
	return '' unless defined $pct;
	my @bars = $glyphs
		? ("\x{2581}", "\x{2582}", "\x{2583}", "\x{2584}",
		   "\x{2585}", "\x{2586}", "\x{2587}", "\x{2588}")
		: ('.', ':', 'i', 'I', '#');
	my $n = int($pct / (100 / @bars));
	$n = $#bars if $n > $#bars;
	return $bars[$n];
}

# Returns 'good', 'warn', or 'bad' based on signal and buffer levels.
sub _healthLevel {
	my ($sig, $buf) = @_;
	my $sigWarn = $prefs->get('signalWarnPct') // 40;
	my $bufWarn = $prefs->get('bufferWarnPct') // 50;

	# Buffer-critical trumps signal
	return 'bad'  if defined $buf && $buf < ($bufWarn / 2);
	return 'warn' if defined $buf && $buf < $bufWarn;

	# Wired players have undef signal -- treat as good
	return 'good' unless defined $sig;
	return 'bad'  if $sig < ($sigWarn / 2);
	return 'warn' if $sig < $sigWarn;
	return 'good';
}

sub _formatSignalPct {
	my $track = shift;
	return '' unless $track;
	my ($client) = _findPlayingClient($track);
	return '' unless $client;
	my $sig = $client->signalStrength();
	return '' unless defined $sig;
	return "${sig}%";
}

sub _formatSignalBars {
	my $track = shift;
	return '' unless $track;
	my ($client) = _findPlayingClient($track);
	return '' unless $client;
	my $sig = $client->signalStrength();
	return '' unless defined $sig;
	return _signalBucket($sig, $prefs->get('healthGlyphs'));
}

sub _formatBufferPct {
	my $track = shift;
	return '' unless $track;
	my ($client) = _findPlayingClient($track);
	return '' unless $client;
	my $usage = Slim::Player::Player::usage($client);
	return sprintf("%d%%", int($usage * 100 + 0.5));
}

sub _formatHealth {
	my $track = shift;
	return '' unless $track;
	my ($client) = _findPlayingClient($track);
	return '' unless $client;

	my $sig  = $client->signalStrength();
	my $buf  = int(Slim::Player::Player::usage($client) * 100 + 0.5);
	my $level = _healthLevel($sig, $buf);

	if ($prefs->get('healthGlyphs')) {
		return { good => "\x{25CF}", warn => "\x{25D0}", bad => "\x{25CB}" }->{$level};
	}
	return { good => 'OK', warn => '!', bad => '!!' }->{$level};
}

sub _formatHealthLine {
	my $track = shift;
	return '' unless $track;
	my ($client) = _findPlayingClient($track);
	return '' unless $client;

	my $sig = $client->signalStrength();
	my $buf = int(Slim::Player::Player::usage($client) * 100 + 0.5);

	my @parts;
	push @parts, sprintf("W%d", $sig) if defined $sig;
	push @parts, sprintf("B%d", $buf);
	return join(' ', @parts);
}

1;

__END__

=head1 NAME

Plugins::ResolutionDisplay::Plugin - Audio resolution display for LMS

=head1 DESCRIPTION

Registers title format tokens that display audio source and decode resolution
information on player displays, screensavers, and the web interface.

Available tokens for use in Server Settings > Formatting > Title Format:

  RESOLUTION        - Combined format: "24/96 FLAC", "DSD128", "320kbps MP3"
  BITDEPTH          - Bit depth only: "24", "16", "1" (for DSD)
  SAMPLERATE_KHZ    - Sample rate in kHz: "44.1", "96", "192"
  SOURCEFORMAT      - Codec name: "FLAC", "MP3", "ALAC"
  DECODE_RESOLUTION - Source vs decode: "24/96* FLAC" (bit-perfect),
                      "24/192>96 FLAC" (downsampled by LMS for this player)
  DECODE_RES_SHORT  - Compact: "96*", "192>96", "D128", "320k"
  SIGNAL_PCT        - Wireless signal strength: "87%" or empty (wired)
  SIGNAL_BARS       - Single-char signal indicator: "▄" or ":" (ASCII mode)
  BUFFER_PCT        - Decode buffer fullness: "95%"
  HEALTH            - Composite: "●" good, "◐" degraded, "○" bad (or OK/!/!!)
  HEALTH_LINE       - Two-metric combo: "W87 B95" (signal + buffer)

Example title format definitions:

  TITLE - RESOLUTION
  ARTIST (DECODE_RESOLUTION)
  TITLE [BITDEPTH/SAMPLERATE_KHZ]
  ARTIST [HEALTH_LINE]

=cut
