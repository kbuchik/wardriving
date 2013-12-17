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
my $smallmap_flag = 0;

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
			elsif ($arg =~ /^--small$/) {
				$smallmap_flag = 1;
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
	$query = "SELECT BSSID FROM wireless WHERE ESSID='$ssid'";
	$sth = $dbh->prepare($query) or die $DBI::errstr;
	$sth->execute() or die $DBI::errstr;
	$bssid = $sth->fetchrow_array();
	if (!defined($bssid)) { &error_AP_not_found($ssid); }
}

# Get wireless router data
$query = "SELECT * FROM wireless WHERE BSSID='$bssid'";
$sth = $dbh->prepare($query) or die $DBI::errstr;
$sth->execute() or die $DBI::errstr;
my $router = $sth->fetchrow_hashref();
if (!defined($router)) { &error_AP_not_found($bssid); }

# Get relevant packet data
$query = "SELECT * FROM packets WHERE source='$bssid'";
$sth = $dbh->prepare($query) or die $DBI::errstr;
$sth->execute() or die $DBI::errstr;
my(@packets);	# Packets array contains hash references for all packet rows
while (my $ref = $sth->fetchrow_hashref()) {
	push(@packets, $ref);
}

# Get maximum/minimum signal values
$query = sprintf("SELECT MIN(signal),MAX(signal) FROM packets WHERE BSSID='%s'", $router->{'BSSID'});
$sth = $dbh->prepare($query) or die $DBI::errstr;
$sth->execute() or die $DBI::errstr;
my ($minsignal,$maxsignal) = $sth->fetchrow_array();

my $numPackets = scalar(@packets);
my(@centroidgps) = &centroid(\@packets);
my $clone_nets;
if ($SSID_query==1) {
	$query = sprintf("SELECT COUNT(*) FROM wireless WHERE ESSID='%s'", $router->{'ESSID'});
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
	print "Test of trilateration matrix algorithm:\n\n";
	&trilateration(\@packets, $bssid);
	print "\n";
	$sth->finish();
	$dbh->disconnect();
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
# Packets are yellow by default
if ($smallmap_flag == 1) {
	my $color = '7f00ffff';
	my(@fourpack) = &get_edge_packets(\@packets, $bssid);
	for (my $i=0; $i<4; $i++) {
		my $packet = $fourpack[$i];
		die "Error: edge packet #$i was undefined" unless defined($packet);
		if ($i==0) {
			#printf("Calling create_packet_KML on packet %d [bound A]\n", $$packet{'id'});
			$KML_output .= &create_packet_KML($packet, $color, $packet_icon, "Bound A");
		} elsif ($i==1) {
			#printf("Calling create_packet_KML on packet %d [bound B]\n", $$packet{'id'});
			$KML_output .= &create_packet_KML($packet, $color, $packet_icon, "Bound B");
		} elsif ($i==2) {
			#printf("Calling create_packet_KML on packet %d [bound C]\n", $$packet{'id'});
			$KML_output .= &create_packet_KML($packet, $color, $packet_icon, "Bound C");
		} elsif ($i==3) {
			#printf("Calling create_packet_KML on packet %d [bound D]\n", $$packet{'id'});
			$KML_output .= &create_packet_KML($packet, $color, $packet_icon, "Bound D");
		}
	}
	foreach my $packet (@packets) {
		if ($$packet{'signal'} == $minsignal) {
			$KML_output .= &create_packet_KML($packet, 'ff0000ff', $packet_icon, "Weakest packet");
		}
		if ($$packet{'signal'} == $maxsignal) {
			$KML_output .= &create_packet_KML($packet, 'ff00ff00', $packet_icon, "Strongest packet");
		}
	}
} else {
	foreach my $packet (@packets) {
		my $color = '7f00ffff';
		# Weakest packet is red
		if ($$packet{'signal'} == $minsignal) { $color = 'ff0000ff'; }
		# Strongest packet (aka where giskismet places the router) is green
		if ($$packet{'signal'} == $maxsignal) { $color = 'ff00ff00'; }
		$KML_output .= &create_packet_KML($packet, $color, $packet_icon, "");
	}
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

# Approximates the location of an 802.11 access point using trilateration
sub trilateration #(@packets, $bssid)
{
	my(@packets) = @{$_[0]} or die $!;
	my $sth = $dbh->prepare("SELECT AVG(gpslat) FROM packets");
	$sth->execute() or die $DBI::errstr;
	my $avglat = $sth->fetchrow_array();
	my $ellipsoid = 'WGS-84';
	
	# Find the edge packets
	my(@points) = &get_edge_packets(\@packets, $_[1]);
	
	# Calculate local earth radius values for coordinate transformations
	#my $rho = &geodetic_radius($avglat);
	my $rho = 6371000.0;
	
	# Extract coordinate values from edge packets and convert to UTM
	my ($latA, $lonA) = ($points[0]->{'gpslat'}, $points[0]->{'gpslon'});
	my ($Z_a, $X_a, $Y_a) = latlon_to_utm($ellipsoid, $latA, $lonA);
	my $R_a = &freespace_dist($points[0]->{'signal'});
	my ($latB, $lonB) = ($points[1]->{'gpslat'}, $points[1]->{'gpslon'});
	my ($Z_b, $X_b, $Y_b) = latlon_to_utm($ellipsoid, $latB, $lonB);
	my $R_b = &freespace_dist($points[1]->{'signal'});
	my ($latC, $lonC) = ($points[2]->{'gpslat'}, $points[2]->{'gpslon'});
	my ($Z_c, $X_c, $Y_c) = latlon_to_utm($ellipsoid, $latC, $lonC);
	my $R_c = &freespace_dist($points[2]->{'signal'});
	my ($latD, $lonD) = ($points[3]->{'gpslat'}, $points[3]->{'gpslon'});
	my ($Z_d, $X_d, $Y_d) = latlon_to_utm($ellipsoid, $latD, $lonD);
	my $R_d = &freespace_dist($points[3]->{'signal'});
	
	# Debug reports
	printf("UTM zone at %f N, %f W: %s\n", $points[0]->{'gpslat'}, $points[0]->{'gpslon'}, $Z_a);
	printf("Packet A: %f,%f (d=%d)\n", $X_a, $Y_a, $R_a);
	printf("Packet B: %f,%f (d=%d)\n", $X_b, $Y_b, $R_b);
	printf("Packet C: %f,%f (d=%d)\n", $X_c, $Y_c, $R_c);
	printf("Packet D: %f,%f (d=%d)\n", $X_d, $Y_d, $R_d);
	
	# Build matrices for the reduced system of arc-equations
	my $M = new Math::Matrix(
		[($X_b-$X_a), ($Y_b-$Y_a)],
		[($X_c-$X_a), ($Y_c-$Y_a)],
		[($X_d-$X_a), ($Y_d-$Y_a)]
	);
	my $rhs = new Math::Matrix(
		[(($R_b**2 - $R_a**2) + ($X_a**2 - $X_b**2) + ($Y_a**2 - $Y_b**2)),
		(($R_c**2 - $R_a**2) + ($X_a**2 - $X_c**2) + ($Y_a**2 - $Y_c**2)),
		(($R_d**2 - $R_a**2) + ($X_a**2 - $X_d**2) + ($Y_a**2 - $Y_d**2))]
	);
	#$M->print("\nCoordinate matrix:\n\n");
	#$rhs->print("\nRHS matrix:\n\n");
	my $eq_matrix = $M->concat($rhs->transpose);
	$eq_matrix->print("\nEquation matrix:\n\n");
	my $solution = $eq_matrix->solve;
	$solution->print("\nSolution matrix:\n\n");
	$sth->finish();
}

sub freespace_dist #($RSS)
{
	my $RSS = shift or die $!;
	my $MHz = 2400;
	my $exp = (27.55 - (20 * log($MHz)/log(10)) - $RSS) / 20;
	return (10.0**$exp);
}

# Returns an array of four packets from a given bssid
sub get_edge_packets #(@packets)
{	
	my(@packets) = @{$_[0]} or die "Error: get_edge_packets() called without packets array argument";
	my $bssid = $_[1] or die "Error: get_edge_packets() called without bssid argument";
	die "Error: BSSID variable passed to get_edge_packets differs from the source BSSID of the first packet in array argument" unless ($packets[0]->{'source'} =~ /^$bssid$/);
	my $minlat = 90.0;
	my $maxlat = -90.0;
	my $minlon = 180.0;
	my $maxlon = -180.0;
	foreach my $packet (@packets) {
		my $latitude = $packet->{'gpslat'};
		my $longitude = $packet->{'gpslon'};
		if ($latitude < $minlat) { $minlat = $latitude; }
		if ($latitude > $maxlat) { $maxlat = $latitude; }
		if ($longitude < $minlon) { $minlon = $longitude; }
		if ($longitude > $maxlon) { $maxlon = $longitude; }
	}	
	# Points -> { +lat, +lon, -lat, -lon } (or Northernmost, Easternmost, Southernmost and Westernmost)
	#printf("Min/max latitude: %f, %f\n", $minlat, $maxlat);
	#printf("Min/max longitude: %f, %f\n", $minlon, $maxlon);
	
	my(@points);	# Array of packet hashref objects
	for (my $i=1; $i<=4; $i++) {
		my $condition = "";
		if ($i==1) {
			$condition = " AND gpslat=\"$maxlat\"";
		} elsif ($i==2) {
			$condition = " AND gpslon=\"$maxlon\"";
		} elsif ($i==3) {
			$condition = " AND gpslat=\"$minlat\"";
		} elsif ($i==4) {
			$condition = " AND gpslon=\"$minlon\"";
		}
		my $sth = $dbh->prepare("SELECT * FROM packets WHERE source = '$bssid'$condition");
		$sth->execute() or die $DBI::errstr;
		push(@points, $sth->fetchrow_hashref());
	}
	$sth->finish();
	return @points;
}

# Uses the Haversine formula to calculate distance (in meters) between two latitude/longitude points on the Earth's surface ("great circle distance")
sub haversine #($lat1, $lon1, $lat2, $lon2)
{
	# Pull arguments
	my $lat1 = shift or die $!;
	my $lon1 = shift or die $!;
	my $lat2 = shift or die $!;
	my $lon2 = shift or die $!;
	my $rho = 6371000.0;
	
	# Convert to radians and calcuate deltas
	my $deltaLat = abs(deg2rad($lat1)-deg2rad($lat2));
	my $deltaLon = abs(deg2rad($lon1)-deg2rad($lon2));
	
	# Use haversine formula to calculate distance
	my $a = sin($deltaLat/2)**2 + cos(deg2rad($lat1))*cos(deg2rad($lat2))*sin($deltaLon/2)**2;
	my $c = 2*atan2(sqrt($a), sqrt(1-$a));
	my $dist = $rho*$c;
	return $dist;
}

# Calculates the radius (in meters) of the earth given a geodetic latitude. Broken.
sub geodetic_radius #($latitude)
{
	my $R_eq = 6378137.0;
	my $R_pol = 6356752.3;
	my $latitude = shift or die $!;
	my $lat = deg2rad($latitude);
	my $radius = (($R_eq**2 * cos($lat))**2 + ($R_pol**2 * sin($lat))**2)/(($R_eq * cos($lat))**2 + ($R_pol * sin($lat)**2));
	return sqrt($radius);
}

# Replaces certain special characters in $str with their equivalent HTML codes if $mode==0, or underscores otherwise
sub symbol_filter #($str, $mode)
{
	my $str = shift or die "symbol_filter() called without string argument";
	#my $mode = shift or die "symbol_filter() called without mode argument";
	my $mode = shift;
	if ($mode == 0) {
		$str =~ s/\&/&amp;/g;
		$str =~ s/\"/&quot;/g;
		$str =~ s/\</&lt;/g;
		$str =~ s/\>/&gt;/g;
		$str =~ s/\°/&deg;/g;
		$str =~ s/\¡/&iexcl;/g;
		$str =~ s/\¿/&iquest;/g;
	} else {
		$str =~ s/(\&|\"|\<|\>|\°|\¡|\¿)/_/g;
	}
	return $str;
}

# Returns the KML header string for the maps generated by this script
sub create_KML_header #($name, $desc)
{
	my $name = shift or die $!;
	my $desc = shift or die $!;
	$desc = &symbol_filter($desc, 0);
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
	my $scale = 1;
	my $essid = $$router{'ESSID'};
	my $stylemap_id = $essid;
	if ($essid eq "") {
		$stylemap_id = "hidden_net";
	} else {
		my $stylemap_id = &symbol_filter($$router{'ESSID'}, 1);
		my $essid = &symbol_filter($$router{'ESSID'}, 0);
	}
	
	my $CDATAstr = sprintf("BSSID: %s<br>Encryption %s<br>Channel: %s<br>Manufacturer: %s<br>", $$router{'BSSID'}, $$router{'Encryption'}, $$router{'Channel'}, $$router{'Manuf'});
	
	my $KML = sprintf("<Style id=\"%s_normal\">\n", $stylemap_id);
	$KML .= "\t<IconStyle>\n";
	$KML .= "\t\t<color>$color</color>\n";
	$KML .= "\t\t<scale>$scale</scale>\n";
	$KML .= "\t\t<Icon>\n\t\t<href>$iconurl</href>\n\t\t</Icon>\n";
	$KML .= "\t</IconStyle>\n</Style>";

	$KML .= sprintf("<Style id=\"%s_highlight\">\n", $stylemap_id);
	$KML .= "\t<IconStyle>\n";
	$KML .= "\t\t<color>$color</color>\n";
	$KML .= "\t\t<scale>$scale</scale>\n";
	$KML .= "\t\t<Icon>\n\t\t<href>$iconurl</href>\n\t\t</Icon>\n";
	$KML .= "\t</IconStyle>\n</Style>";
	
	$KML .= sprintf("<StyleMap id=\"%s_styleMap\">\n", $stylemap_id);
	$KML .= "\t<Pair>\n\t<key>normal</key>\n";
	$KML .= sprintf("\t<styleUrl>#%s_normal</styleUrl>\n", $stylemap_id);
	$KML .= "\t</Pair>\n\t<Pair>\n\t<key>highlight</key>\n";
	$KML .= sprintf("\t<styleUrl>%s_highlight</styleUrl>\n", $stylemap_id);
	$KML .= "\t</Pair>\n</StyleMap>\n";
	
	$KML .= sprintf("<Placemark>\n\t<name>%s</name>\n", $essid);
	$KML .= sprintf("\t<styleUrl>#%s_styleMap</styleUrl>\n", $stylemap_id);
	$KML .= "\t<description><![CDATA[$CDATAstr]]></description>\n";
	$KML .= "\t<Point>\n";
	$KML .= sprintf("\t\t<LookAt><longitude>%f</longitude><latitude>%f</latitude><altitude>%f</altitude><tilt>1</tilt><heading>1</heading></LookAt>\n", $lon, $lat, $alt);
	$KML .= sprintf("\t\t<coordinates>%f,%f,%f</coordinates>\n", $lon, $lat, $alt);
	$KML .= "\t</Point>\n</Placemark>\n";

	return $KML;
}

# Returns a KML string describing the placemark for a packet
sub create_packet_KML #($packet, $color, $iconurl, $packet_name)
{
	my $packet = shift or die "Error: create_packet_KML() called with no packet reference";
	my $color = shift or die $!;
	my $iconurl = shift or die $!;
	my $packet_name = shift;
	my $distance = &freespace_dist($$packet{'signal'});

	if(!defined($packet_name)) { my $packet_name = ""; }
	
	my $CDATAstr = sprintf("Packet ID: %d<br>BSSID: %s<br>Source: %s<br>Date: %s<br>Signal: %d<br>Noise: %d<br><br>Latitude: %s<br>Longitude: %s<br>Esimated distance: %s<br>", $$packet{'id'}, $$packet{'BSSID'}, $$packet{'source'}, $$packet{'date'}, $$packet{'signal'}, $$packet{'noise'}, $$packet{'gpslat'}, $$packet{'gpslon'}, $distance);
	
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
	
	$KML .= "<Placemark>\n\t<name>$packet_name</name>\n";
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
	print "\tPrints metadata/statistics about the network and packets instead of generating a map\n";
	print "   -O\n";
	print "\tPrints to standard out instead of to a file\n";
	print "   --small\n";
	print "\tCreates a map with only 6 packets: strongest, weakest, farthest north/east/south/west\n";
	print "\t(Useful for testing trilateration algorithm)\n\n";
	exit(1);
}
