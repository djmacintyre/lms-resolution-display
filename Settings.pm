package Plugins::ResolutionDisplay::Settings;

use strict;
use warnings;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.resolutiondisplay');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_RESOLUTION_DISPLAY_SETTINGS');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/ResolutionDisplay/settings/basic.html');
}

sub prefs {
	return ($prefs, qw(showLossless shortFormat dsdStyle signalWarnPct signalGoodPct bufferWarnPct healthGlyphs));
}

1;
