#!/usr/bin/perl

# drivetimer.pl -- Calculates the total amount of time Kismet was collecting data based on its gpsxml files
# Author: Kevin Buchik <kdbuchik@gmail.com>

# Usage: drivetimer.pl [.gpsxml file]
# If no .gpsxml file is given, script will attempt to parse all XML files in the current directory

use strict;
use warnings;
use XML::Simple;
use POSIX;

my $xml = new XML::Simple;
my $totalsecs = 0;
my $runs = 0;
my $verbose_flag = 0;
my $gpsxml_declared = 0;
my $path = "";

# Parameter parse
foreach my $arg (@ARGV) {
	if ($arg =~ /^-(h|-help)$/) {
		&usage();
	} elsif ($arg =~ /^-v$/) {
		$verbose_flag = 1;
	} else {
		$path = shift;
		$gpsxml_declared = 1;
	}
}

if ($gpsxml_declared == 0) {
	my(@files) = <*>;
	foreach my $doc (@files) {
		# if the file is an XML file, count the seconds
		if (`file $doc` =~ /XML/) {
			if ($verbose_flag == 1) {
				print "Parsing XML file $doc...\n";
			}
			my $packet_data = $xml->XMLin($doc) or die "Error parsing XML file $doc";
			my(@packets) = @{ $packet_data->{'gps-point'} } or next;
			my $start = $packets[0]->{'time-sec'} or next;
			my $end = $packets[scalar(@packets)-1]->{'time-sec'};
			$totalsecs += $end-$start;
			$runs++;
			if ($verbose_flag == 1) {
				my $timestr = &calc_timestr($end-$start);
				printf("Counted %d seconds (%s) in %s (total %s)\n", ($end-$start), $timestr, $doc, $totalsecs);
			}
		}
	}
	if ($runs == 0) { die "Error: no valid XML files found in directory"; }
	my $avgtime = floor($totalsecs/$runs);
	my $timestr = &calc_timestr($totalsecs);
	my $avgstr = &calc_timestr($avgtime);
	print "Total time: $timestr ($totalsecs seconds total)\n";
	print "Average per gpsxml file: $avgstr ($avgtime seconds)\n";
} else {
	my $filetype = `file $path`;
	if ($filetype =~ /XML/) {
		my $packet_data = $xml->XMLin($path) or die $!;
		my(@packets) = @{ $packet_data->{'gps-point'} } or die "Error: XML file isn't valid .gpsxml format";
		my $startsec = $packets[0]->{'time-sec'};
		my $endsec = $packets[scalar(@packets)-1]->{'time-sec'};
		$totalsecs = $endsec-$startsec;
		my $time = &calc_timestr($totalsecs);
		print "Total time: $time ($totalsecs seconds total)\n";
	} else {
		print "Error: unrecognized file type\n";
		exit(1);
	}
}
exit(0);

sub usage
{
	print "Usage: drivetimer.pl [OPTIONS] [.gpsxml file]\n";
	print "If no .gpsxml file is given, script will attempt to parse all XML files in the current directory\n";
	print "OPTIONS:\n";
	print "   -v:\n";
	print "\tVerbose mode (print additional messages for each file parsed)\n";
	exit(1);
}

sub calc_timestr
{
	my $seconds = shift or die "Error: calc_timestr() function called with no arguments";
	my $s = $seconds%60;
	my $m = $seconds/60;
	my $h = $m/60;
	$m = $m%60;
	my $timestr = "";
	if ($h == 0 or !defined($h) or $h =~ /^0$/) {
		$timestr = sprintf("%dmin %dsec", $m, $s);
	} else {
		$timestr = sprintf("%dhr %dmin %dsec", $h, $m, $s);
	}
	return $timestr;
}
