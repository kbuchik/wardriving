#!/usr/bin/perl

use strict;
use warnings;
use XML::Simple;
use DBI;
use DBD::SQLite;

# parse_gpsxml.pl -- A script for parsing Kismet-newcore .gpsxml files into an sqlite database
# Author: Kevin Buchik <kdbuchik@gmail.com>

# Usage: parse_gpsxml.pl [OPTIONS] <gpsxml file> 

# Parameter parse
our $gpsxml = "";
our $dbfile = "wireless.dbl";
if(scalar(@ARGV) < 1) { die &usage(); }
for (my $i=0; $i<scalar(@ARGV); $i++) {
	my $arg = $ARGV[$i];
	if ($arg =~ /^-(h|-help)$/) {
		die &usage();
	} elsif ($arg =~ /^-(d|-database)$/) {
		$i++;
		$arg = $ARGV[$i];
		if ($arg =~ /^$/) { die &usage(); }
		$dbfile = $arg;
	} elsif ($i+1 == scalar(@ARGV)) {
		$gpsxml = $arg;
	} else { die &usage(); }
}
my(@arr) = split(/-/, $gpsxml);
our $datestr = $arr[1];
our $sth;
our $bssid_regex = '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$';

# Connect to database file
our $dbh = DBI->connect("dbi:SQLite:dbname=$dbfile",
	"",
	"",
	{ RaiseError => 1}
) or die $DBI::errstr;
# Call function to create packets table if it doesn't exist
&create_table();
print "Successfully connected to database $dbfile\n";

# Load XML file
print "Loading XML file $gpsxml...\n";
my $xml = new XML::Simple;
my $packet_data = $xml->XMLin($gpsxml) or die $!;
my(@gps_points) = @{ $packet_data->{'gps-point'} };

# Loop through gps-point entries (packet logs)
my $total = 0;
my $valid = 0;
my $pcount = scalar(@gps_points);
print "Counted $pcount packet entries; adding non-zero packets to database...\n";

foreach my $packet (@gps_points) {
	my $bssid = $packet->{'bssid'};
	if ($bssid =~ /$bssid_regex/ and $bssid !~ /^00:00:00:00:00:00$/) {
		my $query = &pack_query($packet);
		#printf("Query %d: %s\n", $valid, $query);
		$sth = $dbh->prepare($query);
		$sth->execute() or die "Error inserting row into database";
		$valid++;
	}
	$total++;
}
my $percent = ($valid/$total)*100;
printf("Inserted %d packet entries to database (%.1f%% of total packets)\n", $valid, $percent);
$sth->finish();
$dbh->disconnect();
exit(0);

# Returns an SQL INSERT query string given a gpsxml gps-point XML object
sub pack_query #($packet)
{
	my $packet = shift or die "Error: pack_query() called without packet object argument";
	
	my $bssid = $packet->{'bssid'};
	my $source = $packet->{'source'};
	if ($source =~ /^$/) { $source = $bssid; }
	my $time_sec = $packet->{'time-sec'};
	my $time_usec = $packet->{'time-usec'};
	my $lat = $packet->{'lat'};
	my $lon = $packet->{'lon'};
	my $speed = $packet->{'spd'};
	my $heading = $packet->{'heading'};
	my $fix = $packet->{'fix'};
	my $alt = $packet->{'alt'};
	my $signal = $packet->{'signal_dbm'};
	my $noise = $packet->{'noise_dbm'};
	
	my $query = "INSERT INTO packets (BSSID, source, date, time_sec, time_usec, gpslat, gpslon, speed, heading, fix, altitude, signal, noise) VALUES (\"$bssid\", \"$source\", \"$datestr\", $time_sec, $time_usec, $lat, $lon, $speed, $heading, $fix, $alt, $signal, $noise)";
	return $query;
}

sub create_table
{
	eval {
		$dbh->do('CREATE TABLE IF NOT EXISTS packets (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			BSSID text default NULL,
			source text default NULL,
			date text default NULL,
			time_sec INTEGER NULL,
			time_usec INTEGER NULL,
			gpslat float NULL,
			gpslon float NULL,
			speed float NULL,
			heading float NULL,
			fix INTEGER NULL,
			altitude float NULL,
			signal INTEGER NULL,
			noise INTEGER NULL)');
	};
	if ($@) { return 0; } else { return 1; }
}

sub usage
{
	print "Usage: parse_gpsxml.pl [OPTIONS] <gpsxml file>\n";
	print "Parses gpsxml files from kismet-newcore and imports them into a database\n\n";
	print "OPTIONS:\n   -d, --database [SQLite file]\n";
	print "\tUse database file (default: wireless.dbl)\n";
	exit(1);
}
