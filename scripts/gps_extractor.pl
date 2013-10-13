#!/usr/bin/perl

# gps_extractor.pl -- Extracts GPS coordinate pairs from SQLite database (designed for giskismet, but could be used on any database)
# Author: Kevin Buchik <kdbuchik@gmail.com>

# Usage: gps_extractor.pl [database file]
# If no database is given, "wireless.dbl" is used as the default

use DBI;
use DBD::SQLite;
use strict;
use warnings;

# Config variables
my $dbfile = "wireless.dbl";
my $ap_tbl = "wireless";
my $gpslat_field = "GPSBestLat";
my $gpslon_field = "GPSBestLon";

my $sep = " ";
my $xmlmode = 0;

foreach my $arg (@ARGV) {
	if ($arg =~ /^(-h)|(--help)$/) {
		&usage();
	} elsif ($arg =~ /^--csv$/) {
		$sep = ",";
	} elsif ($arg  =~ /^--xml$/) {
		$xmlmode = 1;
	} else {
		$dbfile = $arg;
	}
}

# Sanity check on database file type
my $filetype = `file $dbfile`;
if ($filetype !~ /SQLite/) {
	print "Error: $dbfile is not a valid SQLite database\n";
	exit(3);
}

# Connect to database
my $dbh = DBI->connect(
	"dbi:SQLite:dbname=$dbfile",
	"",
	"",
	{ RaiseError => 1}
) or die $DBI::errstr;

# Run query to get GPS coordinates for all APs
my $sth = $dbh->prepare("SELECT $gpslat_field,$gpslon_field FROM $ap_tbl");
$sth->execute() or die $DBI::errstr;
# Print loop
while (my(@row) = $sth->fetchrow_array()) {
	#my(@row) = $sth->fetchrow_array();
	if ($xmlmode == 1) {
		printf("<ap latitude=\"%f\" longitude=\"%f\" />", $row[0], $row[1]);
	} else {
		printf("%f%s%f\n", $row[0], $sep, $row[1]);
	}
}
$sth->finish();
$dbh->disconnect();
exit 0;

sub usage
{
	print "gps_extractor.pl <dbfile> [--csv]\n";
	exit 1;
}
