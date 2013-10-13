#!/usr/bin/perl

use strict;
use warnings;
use POSIX;
use DBI;
use DBD::SQLite;
use Geo::Coordinates::UTM;
use Math::Matrix;
use Math::Trig;
use Math::Trig ':radial';
use Data::Dumper;

# packetmap.pl -- Given the BSSID or ESSID of a access point, produces a KML map with points marking each
# packet received from that access point, along with several predictions of the access point/router location
# This program requires a giskismet-generated sqlite database loaded with packet data from one (or any) relevant gpsxml files containing data about that network.
# (use my parse_gpsxml.pl script to load gpsxml files into giskismet databases)

# Author: Kevin Buchik <kdbuchik@gmail.com>
# Usage: packetmap.pl [OPTIONS...] <BSSID|ESSID>

# Global vars
my $KML_file = "";
my $dbfile = "wireless-master.dbl";
my $packet_icon = 'http://maps.google.com/mapfiles/kml/shapes/placemark_circle.png';
my $router_icon = 'http://maps.google.com/mapfiles/kml/shapes/target.png';
my $ssid = "snafubar";

my $stdout_flag = 0;
my $kmlset_flag = 0;
my $SSID_query = 0;
my $allssids_flag = 0;
my $metadata_flag = 0;

# Parameter parse
my $ARGS = scalar(@ARGV);
if ($ARGS == 0) { print "Error: packetmap.pl requires at least an SSID/BSSID\n"; &usage(); }

for (my $i=0; $i<$ARGS; $i++) {
	my $arg = $ARGV[$i];
	if ($i+1==$ARGS) {
		if ($arg =~ /^--?([a-z]*[A-Z]*)*$/) {
			print "Unrecognized option $arg\n" unless ($arg =~ /^-(h|-help)$/);
			&usage();
		} else {
			$ssid = $arg;
			if ($ssid !~ /^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/) {
				$SSID_query = 1;
			}
		}
	} else {
		if ($arg =~ /^-/) {
			# This is a shell argument; parse it
			if ($arg =~ /^-(h|-help)$/) {
				&usage();
			}
			elsif ($arg =~ /^-a(-all)$/) {
				$allssids_flag = 1;
			}
			elsif ($arg =~ /^-(d|-db)$/) {
				$i++;
				$dbfile = $ARGV[$i] or die "Error: -d switch requires an argument";
			}
			elsif ($arg =~ /^-(k|-kml)$/) {
				$i++;
				$KML_file = $ARGV[$i] or die "Error: -k switch requires an argument";
				$kmlset_flag = 1;
			}
			elsif ($arg =~ /^-(m|-meta)$/) {
				$metadata_flag = 1;
			}
			elsif ($arg =~ /^-O$/) {
				$stdout_flag = 1;
			}
		} else {
			print "Unrecognized parameter $arg\n";
			&usage();
		}
	}

}

if ($kmlset_flag==0 and $stdout_flag==0) {
	$KML_file = "$ssid-packetmap.kml";
	$kmlset_flag = 1;
}

# Sanity check on database file type
my $filetype = `file $dbfile`;
if ($filetype !~ /SQLite/) {
	print "Error: $dbfile is not a valid SQLite database\n";
	exit(3);
}

our $dbh = DBI->connect("dbi:SQLite:dbname=$dbfile",
	"",
	"",
	{ RaiseError => 1}
) or die $DBI::errstr;

my $query;
my $sth;
my $bssid;
if ($SSID_query==1) {
	$query = "SELECT BSSID FROM wireless WHERE ESSID=\"$ssid\"";
	$sth = $dbh->prepare($query) or die $DBI::errstr;
	$sth->execute() or die $DBI::errstr;
	$bssid = $sth->fetchrow_array();
	if (!defined($bssid)) { &error_AP_not_found($ssid); }
}

# Get wireless router data
$query = "SELECT * FROM wireless WHERE BSSID=\"$bssid\"";
$sth = $dbh->prepare($query) or die $DBI::errstr;
$sth->execute() or die $DBI::errstr;
my $router = $sth->fetchrow_hashref();
if (!defined($router)) { &error_AP_not_found($bssid); }

# Get relevant packet data
$query = "SELECT * FROM packets WHERE BSSID=\"$bssid\"";
$sth = $dbh->prepare($query) or die $DBI::errstr;
$sth->execute or die $DBI::errstr;
my(@packets);	# Packets array contains hash references for all packet rows
while (my $ref = $sth->fetchrow_hashref()) {
	push(@packets, $ref);
}

# Get maximum/minimum signal values
$query = sprintf("SELECT MIN(signal),MAX(signal) FROM packets WHERE BSSID=\"%s\"", $router->{'BSSID'});
$sth = $dbh->prepare($query) or die $DBI::errstr;
$sth->execute or die $DBI::errstr;
my ($minsignal,$maxsignal) = $sth->fetchrow_array();

my $numPackets = scalar(@packets);
my(@centroidgps) = &centroid(\@packets);
my $clone_nets;
if ($SSID_query==1) {
	$query = sprintf("SELECT COUNT(*) FROM wireless WHERE ESSID=\"%s\"", $router->{'ESSID'});
	$sth = $dbh->prepare($query);
	$sth->execute() or die $DBI::errstr;
	$clone_nets = $sth->fetchrow_array();
}

# Metadata/debug block
if ($metadata_flag==1) {
	if ($clone_nets > 1) {
		printf("%d networks with identical SSIDs to \"%s\" [%s]\n", $clone_nets, $router->{'ESSID'}, $router->{'BSSID'});
	} else {
		printf("Network \"%s\" [%s] is unique in this dataset\n", $router->{'ESSID'}, $router->{'BSSID'});
	}
	printf("%d packets collected from this access point\n", $numPackets);
	printf("Centroid algorithm places radio source at %f N, %f W\n", $centroidgps[1], $centroidgps[0]);
	printf("Min RSS: %d, Max RSS: %d\n", $minsignal, $maxsignal);
	print "\n";
	exit(0);
}

my $KMLname = sprintf("Packet map for network \"%s\"", $router->{'ESSID'});
if ($SSID_query==0) {
	$KMLname = sprintf("Packet map for network %s", $router->{'BSSID'});
}
my $KMLdesc = sprintf("Packets received: %d; using centroid algorithm for access point localization", $numPackets);
# Generate KML header
my $KML_output = &create_KML_header($KMLname, $KMLdesc);

# Generate router placemarker
$KML_output .= &create_router_KML($router, 'ffff0000', $router_icon, $centroidgps[1], $centroidgps[0], $centroidgps[2])."\n";

# Generate packet placemarkers
foreach my $packet (@packets) {
	# Packets are yellow by default
	my $color = '7f00ffff';
	# Weakest packet is red
	if ($$packet{'signal'} == $minsignal) { $color = 'ff0000ff'; }
	# Strongest packet (aka where giskismet places the router) is green
	if ($$packet{'signal'} == $maxsignal) { $color = 'ff00ff00'; }
	$KML_output .= &create_packet_KML($packet, $color, $packet_icon);
}
# Append KML footer
$KML_output .= "\n</Document>\n</kml>\n";

# Output the KML data
if ($stdout_flag==1) {
	print $KML_output;
} else {
	open(KMLOUT, ">$KML_file");
	print KMLOUT $KML_output;
	close(KMLOUT);
}

$sth->finish();
$dbh->disconnect();
exit(0);
### ========== END OF MAIN PROGRAM ========== ###

# Approximates the location of an 802.11 access point using the centroid algorithm
sub centroid #(@packets)
{
	my(@packets) = @{$_[0]} or die $!;
	my $N = scalar(@packets);
	my $centroidX = 0;
	my $centroidY = 0;
	my $centroidAlt = 0;
	foreach my $packet (@packets) {
		$centroidX += (1/$N)*($packet->{'gpslon'});
		$centroidY += (1/$N)*($packet->{'gpslat'});
		$centroidAlt += (1/$N)*($packet->{'altitude'});
	}
	my(@centroid) = ($centroidX, $centroidY, $centroidAlt);
	return @centroid;
}

# Returns the KML header string for the maps generated by this script
sub create_KML_header #($name, $desc)
{
	my $name = shift or die $!;
	my $desc = shift or die $!;
	my $KML = '<?xml version="1.0" encoding="UTF-8"?>'."\n";
	$KML .= '<kml xmlns="http://earth.google.com/kml/2.2">'."\n";
	$KML .= "<Document>\n";
	$KML .= "\t<name>$name</name>\n";
	$KML .= "\t<description>$desc</description>\n";
	return $KML;
}

# Returns a KML string describing the placemark for a router
sub create_router_KML #($router, $color, $iconurl, $lat, $lon, $alt)
{
	my $router = shift or die "Error: create_router_KML() called with no router hashref argument";
	my $color = shift or die $!;
	my $iconurl = shift or die $!;
	my $lat = shift or die $!;
	my $lon = shift or die $!;
	my $alt = shift or die $!;
	
	my $CDATAstr = sprintf("BSSID: %s<br>Encryption %s<br>Channel: %s<br>Manufacturer: %s<br>", $$router{'BSSID'}, $$router{'Encryption'}, $$router{'Channel'}, $$router{'Manuf'});
	
	my $KML = sprintf("<Style id=\"%s_normal\">\n", $$router{'ESSID'});
	$KML .= "\t<IconStyle>\n";
	$KML .= "\t\t<color>$color</color>\n";
	$KML .= "\t\t<scale>2</scale>\n";
	$KML .= "\t\t<Icon>\n\t\t<href>$iconurl</href>\n\t\t</Icon>\n";
	$KML .= "\t</IconStyle>\n</Style>";

	$KML .= sprintf("<Style id=\"%s_highlight\">\n", $$router{'ESSID'});
	$KML .= "\t<IconStyle>\n";
	$KML .= "\t\t<color>$color</color>\n";
	$KML .= "\t\t<scale>2</scale>\n";
	$KML .= "\t\t<Icon>\n\t\t<href>$iconurl</href>\n\t\t</Icon>\n";
	$KML .= "\t</IconStyle>\n</Style>";
	
	$KML .= sprintf("<StyleMap id=\"%s_styleMap\">\n", $$router{'ESSID'});
	$KML .= "\t<Pair>\n\t<key>normal</key>\n";
	$KML .= sprintf("\t<styleUrl>#%s_normal</styleUrl>\n", $$router{'ESSID'});
	$KML .= "\t</Pair>\n\t<Pair>\n\t<key>highlight</key>\n";
	$KML .= sprintf("\t<styleUrl>%s_highlight</styleUrl>\n", $$router{'ESSID'});
	$KML .= "\t</Pair>\n</StyleMap>\n";
	
	$KML .= sprintf("<Placemark>\n\t<name>%s</name>\n", $$router{'ESSID'});
	$KML .= sprintf("\t<styleUrl>#%s_styleMap</styleUrl>\n", $$router{'ESSID'});
	$KML .= "\t<description><![CDATA[$CDATAstr]]></description>\n";
	$KML .= "\t<Point>\n";
	$KML .= sprintf("\t\t<LookAt><longitude>%f</longitude><latitude>%f</latitude><altitude>%f</altitude><tilt>1</tilt><heading>1</heading></LookAt>\n", $lon, $lat, $alt);
	$KML .= sprintf("\t\t<coordinates>%f,%f,%f</coordinates>\n", $lon, $lat, $alt);
	$KML .= "\t</Point>\n</Placemark>\n";

	return $KML;
}

# Returns a KML string describing the placemark for a packet
sub create_packet_KML #($packet, $color, $iconurl)
{
	my $packet = shift or die "Error: create_packet_KML() called with no packet reference";
	my $color = shift or die $!;
	my $iconurl = shift or die $!;
	
	my $CDATAstr = sprintf("BSSID: %s<br>Source: %s<br>Date: %s<br>Signal: %d<br>Noise: %d<br>", $$packet{'BSSID'}, $$packet{'source'}, $$packet{'date'}, $$packet{'signal'}, $$packet{'noise'});
	
	my $KML = sprintf("<Style id=\"Packet%d_normal\">\n", $$packet{'id'});
	$KML .= "\t<IconStyle>\n";
	$KML .= "\t\t<color>$color</color>\n";
	$KML .= "\t\t<scale>1</scale>\n";
	$KML .= "\t\t<Icon>\n\t\t<href>$iconurl</href>\n\t\t</Icon>\n";
	$KML .= "\t</IconStyle>\n</Style>";
	
	$KML .= sprintf("<Style id=\"Packet%d_highlight\">\n", $$packet{'id'});
	$KML .= "\t<IconStyle>\n";
	$KML .= "\t\t<color>$color</color>\n";
	$KML .= "\t\t<scale>1</scale>\n";
	$KML .= "\t\t<Icon>\n\t\t<href>$iconurl</href>\n\t\t</Icon>\n";
	$KML .= "\t</IconStyle>\n</Style>";
	
	$KML .= sprintf("<StyleMap id=\"Packet%d_styleMap\">\n", $$packet{'id'});
	$KML .= "\t<Pair>\n\t<key>normal</key>\">\n";
	$KML .= sprintf("\t<styleUrl>#Packet%d_normal</styleUrl>\n", $$packet{'id'});
	$KML .= "\t</Pair>\n\t<Pair>\n\t<key>highlight</key>\n";
	$KML .= sprintf("\t<styleUrl>Packet%d_highlight</styleUrl>\n", $$packet{'id'});
	$KML .= "\t</Pair>\n</StyleMap>\n";
	
	$KML .= "<Placemark>\n\t<name></name>\n";
	$KML .= sprintf("\t<styleUrl>#Packet%d_styleMap</styleUrl>\n", $$packet{'id'});
	$KML .= "\t<description><![CDATA[$CDATAstr]]></description>\n";
	$KML .= "\t<Point>\n";
	$KML .= sprintf("\t\t<LookAt><longitude>%f</longitude><latitude>%f</latitude><altitude>%f</altitude><tilt>1</tilt><heading>1</heading></LookAt>\n",
		$$packet{'gpslon'}, $$packet{'gpslat'}, $$packet{'altitude'});
	$KML .= sprintf("\t\t<coordinates>%f,%f,%f</coordinates>\n", $$packet{'gpslon'}, $$packet{'gpslat'}, $$packet{'altitude'});
	$KML .= "\t</Point>\n</Placemark>\n";

	return $KML;
}

sub error_AP_not_found #($ssid)
{
	my $ssid = shift or die "Error: YOU BROKE THE ERROR FUNCTION RETARD";
	print "Error: no access points in database matching \"$ssid\" were found\n";
	exit(2);
}

sub usage
{
	print "Usage: packetmap.pl [OPTIONS...] <BSSID|ESSID>\n";
	print "If the first arguments looks (regex) like a BSSID it will be parsed as such. Otherwise, it will be treated as an ESSID and the first matching ESSID in the database will be used.\n\n";
	print "OPTIONS:\n";
	print "   -d, --db <database name>\n";
	print "\tSelect a database for packetmap to use (on not found or no argument, defaults to \"wireless-master.dbl\"\n";
	print "   -k, --kml <output kml name>\n";
	print "\tDirects where to save the KML file to. .kml suffix appended automatically, so don't add it.\n";
	print "\tIf no -k option is given, saves to \"[SSID]-packetmap.kml\"\n";
	print "   -m, --meta\n";
	print "\tPrints metadata/statistics about the network and packets instead of generating a map";
	print "   -o\n";
	print "\tPrints to standard out instead of to a file\n\n";
	exit(1);
}
