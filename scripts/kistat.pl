#!/usr/bin/perl

use DBI;
use DBD::SQLite;
use strict;
use warnings;

# Kistat.pl -- Statistics generator for kismet wardriving/netxml data
# Usage: kistat.pl [SQLite file] [OPTIONS]...

# Looks for wireless.dbl in the current directory by default
# Otherwise pass the name of an sqlite database (generated by kismet) on the command line
# WARNING: Not idiot-proof, no comprehensive error-checking

# Author: Kevin Buchik <kdbuchik@gmail.com>
# Feel free to bitch about bugs or suggest features...I may not implement them though

# "Global" config variables
my $time_str = localtime;
my $args = scalar(@ARGV);
my $dbfile = "wireless.dbl";
my $ap_tbl = "wireless";
my $client_tbl = "clients";
my $scan_flag = 0;
my(@scan_ssids);
my $ssid_flag = 0;
my $chan_flag = 0;
my $model_flag = 0;
my $vendor_flag = 0;
my $ip_flag = 0;
my $topranked = 15;

# Parameter parsing
for (my $i=0; $i<$args; $i++) {
	my $argI = $ARGV[$i];
	if ($argI =~ /^-/) {
		if ($argI =~ /^-(h|-help)$/) {
			&usage();
		} elsif ($argI =~ /^-(s|-search)$/) {
			if ($args<=$i) {
				&usage();
			} else {
				$i++;
				@scan_ssids = split(/,/, $ARGV[$i]);
				$scan_flag = 1;
			}
		} elsif ($argI =~ /^-m$/) {
			$model_flag = 1;
		} elsif ($argI =~ /^--ssids$/) {
			$ssid_flag = 1;
		} elsif ($argI =~ /^--channels$/) {
			$chan_flag = 1;
		} elsif ($argI =~ /^--vendors$/) {
			$vendor_flag = 1;
		} elsif ($argI =~ /^--ips$/) {
			$ip_flag = 1;
		} elsif ($argI =~ /^-(r|-ranks)$/) {
			$ssid_flag = 1;
			$chan_flag = 1;
			$vendor_flag = 1;
			$ip_flag = 1;
		} else {
			print "Unrecognized option $argI\n";
			&usage();
		}
	} else {
		$dbfile = $argI;
	}
}

# Sanity check on database filetype
my $filetype = `file $dbfile`;
if ($filetype !~ /SQLite/) {
	print "Error: $dbfile is not a valid SQLite database\n";
	exit(3);
}

# Connect to database file
our $dbh = DBI->connect(
	"dbi:SQLite:dbname=$dbfile",
	"",
	"",
	{ RaiseError => 1}
) or die $DBI::errstr;

my $sth = $dbh->prepare("SELECT SQLITE_VERSION()");
$sth->execute() or die $DBI::errstr;
my(@ver) = $sth->fetchrow_array();
my $query;
print "Kistat output generated on $time_str\n";
print "Connected to $dbfile...using SQLite version ".$ver[0]."\n\n";

# Get total number of APs
$query = "SELECT COUNT(*) FROM $ap_tbl";
my $nets_total = &count_query($query);
printf("Total networks:\t\t\t%d\n\n", $nets_total);

# Open networks
$query = "SELECT COUNT(*) FROM $ap_tbl WHERE Encryption='None'";
my $nets_open = &count_query($query);
my $pc_open = ($nets_open/$nets_total)*100;
printf("Open networks:\t\t\t%d \t[%.2f%%]\n", $nets_open, $pc_open);

# Get total number of IASTATE/ISU-CARDINAL networks
$query = "SELECT COUNT(*) FROM $ap_tbl WHERE ((ESSID='IASTATE' OR ESSID='ISU-CARDINAL') AND Encryption='None') OR ESSID='eduroam' OR ESSID='ISU-PRESS' OR ESSID='ISU-PREMIUM' OR ESSID LIKE 'CNDE'";
my $nets_isu = &count_query($query);
my $nets_open_isu = &count_query("SELECT COUNT(*) FROM $ap_tbl WHERE (ESSID='IASTATE' OR ESSID='ISU-CARDINAL') AND Encryption='None'");
my $pc_isu = ($nets_isu/$nets_total)*100;
my $pcopen_isu = ($nets_open_isu/$nets_open)*100;
printf("Total ISU networks:\t\t%d \t[%.2f%% of total]\n", $nets_isu, $pc_isu);
printf("Total open ISU networks:\t%d \t[%.2f%% of open]\n", $nets_open_isu, $pcopen_isu);

# Default guest networks
$query = "SELECT COUNT(*) FROM $ap_tbl WHERE Encryption='None' AND (ESSID LIKE \"%-guest\" OR ESSID LIKE \"%.guests\") AND ESSID<>\"AmesGuest\"";
my $nets_guest = &count_query($query);
my $pc_guest = ($nets_guest/$nets_total)*100;
my $pcopen_guest = ($nets_guest/$nets_open)*100;
printf("Default guest networks:\t\t%d \t[%.2f%% of open, %.2f%% of total]\n", $nets_guest, $pcopen_guest, $pc_guest);

# Open printers
$query = "SELECT COUNT(*) FROM $ap_tbl WHERE Encryption='None' AND ESSID LIKE \"%Print%\"";
my $nets_openprint = &count_query($query);
my $pc_openprint = ($nets_openprint/$nets_total)*100;
my $pcopen_print = ($nets_openprint/$nets_open)*100;
printf("Open printers:\t\t\t%d \t[%.2f%% of open, %.2f%% of total]\n", $nets_openprint, $pcopen_print, $pc_openprint);

my $other_open = $nets_open-($nets_open_isu+$nets_guest+$nets_openprint);
my $pcopen_other = ($other_open/$nets_open)*100;
my $pc_other = ($other_open/$nets_total)*100;
printf("Other open networks\t\t%d \t[%.2f%% of open, %.2f%% of total]\n\n", $other_open, $pcopen_other, $pc_other);

# WEP networks
$query = "SELECT COUNT(*) FROM $ap_tbl WHERE Encryption='WEP'";
my $nets_wep = &count_query($query);
my $pc_wep = ($nets_wep/$nets_total)*100;
printf("WEP networks:\t\t\t%d \t[%.2f%%]\n", $nets_wep, $pc_wep);

# All WPA networks
$query = "SELECT COUNT(*) FROM $ap_tbl WHERE Encryption LIKE \"%WPA%\"";
my $nets_wpa = &count_query($query);
my $pc_wpa = ($nets_wpa/$nets_total)*100;
printf("Total WPA networks:\t\t%d \t[%.2f%%]\n", $nets_wpa, $pc_wpa);

# WPA networks without AES
$query = "SELECT COUNT(*) FROM $ap_tbl WHERE (Encryption LIKE \"%WPA%\" AND Encryption NOT LIKE \"%AES%\")";
my $nets_noaes = &count_query($query);
my $pc_noaes = ($nets_noaes/$nets_total)*100;
my $pcwpa_noaes = ($nets_noaes/$nets_wpa)*100;
printf("WPA networks without AES:\t%d \t[%.2f%% of WPA, %.2f%% of total]\n", $nets_noaes, $pcwpa_noaes, $pc_noaes);

# WPA+AES networks (highest security)
$query = "SELECT COUNT(*) FROM $ap_tbl WHERE Encryption LIKE \"%AES%\"";
my $nets_aes = &count_query($query);
my $pc_aes = ($nets_aes/$nets_total)*100;
printf("WPA+AES networks:\t\t%d \t[%.2f%%]\n\n", $nets_aes, $pc_aes);

# Hidden networks (not broadcasting SSID)
$query = "SELECT COUNT(*) FROM $ap_tbl WHERE Cloaked='true'";
my $nets_cloaked = &count_query($query);
my $pc_cloaked = ($nets_cloaked/$nets_total)*100;
printf("\"Cloaked\" networks:\t\t%d \t[%.2f%%]\n", $nets_cloaked, $pc_cloaked);

# Known IP subnets
$query = "SELECT COUNT(*) FROM $ap_tbl WHERE IP<>'undefined'";
my $ident_ips = &count_query($query);
my $pc_ips = ($ident_ips/$nets_total)*100;
printf("Routers with known subnet IPs:\t%d \t[%.2f%%]\n", $ident_ips, $pc_ips);

# Printers
$query = "SELECT COUNT(*) FROM $ap_tbl WHERE ESSID LIKE \"%Print%\"";
my $nets_printers = &count_query($query);
my $pc_printers = ($nets_printers/$nets_total);
printf("Wireless printers:\t\t%d \t[%.2f%%]\n", $nets_printers, $pc_printers);

# Off-channel APs
$query = "SELECT COUNT(*) FROM $ap_tbl WHERE Channel<>'1' AND Channel<>'6' AND Channel<>'11'";
my $nets_offchan = &count_query($query);
my $pc_offchan = ($nets_offchan/$nets_total)*100;
printf("Networks on atypical channels:\t%d \t[%.2f%%]\n", $nets_offchan, $pc_offchan);

# Unique router manufacturers
$query = "SELECT COUNT(DISTINCT Manuf) FROM $ap_tbl";
my $uniq_man = &count_query($query);
printf("Unique vendors:\t\t\t%d\n", $uniq_man);

# Check for BSSID collisions
# Note: in theory, this should *never* happen...if it does, it most likely means someone is spoofing their MAC address
my $collisions = &bssid_clash($nets_total);
if ($collisions == 0) {
	print "No BSSID collisions detected\n";
} else {
	print ">>>>> $collisions BSSID COLLISIONS DETECTED!! <<<<<\n";
}

print "\n---Excluding all Iowa State networks for the following calculations---\n";
print "(includes the following SSIDs: IASTATE, ISU-CARDINAL, ISU-PRESS, ISU-PREMIUM, eduroam and CNDE)\n";
my $nets_nonisu = $nets_total-$nets_isu;
my $nets_open_nonisu = &count_query("SELECT COUNT(*) FROM $ap_tbl WHERE (ESSID<>'IASTATE' AND ESSID<>'ISU-CARDINAL') AND Encryption='None'");
my $pc_open_nonisu = ($nets_open_nonisu/$nets_nonisu)*100;
printf("Non-ISU open networks:\t%d \t[%.2f%%]\n", $nets_open_nonisu, $pc_open_nonisu);
my $pc_wep_nonisu = ($nets_wep/$nets_nonisu)*100;
printf("WEP networks:\t\t%d \t[%.2f%%]\n", $nets_wep, $pc_wep_nonisu);
my $pc_wpa_nonisu = ($nets_wpa/$nets_nonisu)*100;
printf("WPA networks:\t\t%d \t[%.2f%%]\n", $nets_wpa, $pc_wpa_nonisu);
my $pc_noaes_nonisu = ($nets_noaes/$nets_nonisu)*100;
printf("WPA+TKIP networks:\t%d \t[%.2f%%]\n", $nets_noaes, $pc_noaes_nonisu);
my $pc_aes_nonisu = ($nets_aes/$nets_nonisu)*100;
printf("WPA+AES networks:\t%d \t[%.2f%%]\n", $nets_aes, $pc_aes_nonisu);
print "---End of ISU network exclusion---\n\n";

if ($model_flag == 1) {
	print "---Manufacturer statistics---\n";
	my $counted_mods = 0;
	my $mod_cisco = &count_query("SELECT COUNT(*) FROM $ap_tbl WHERE Manuf LIKE \"%Cisco%\"");
	$counted_mods += $mod_cisco;
	my $pc_cisco = ($mod_cisco/$nets_total)*100;
	printf("Cisco:\t\t\t%d \t[%.2f%%]\n", $mod_cisco, $pc_cisco);
	my $mod_netgear = &count_query("SELECT COUNT(*) FROM $ap_tbl WHERE Manuf LIKE \"%NETGEAR%\"");
	$counted_mods += $mod_netgear;
	my $pc_netgear = ($mod_netgear/$nets_total)*100;
	printf("Netgear:\t\t%d \t[%.2f%%]\n", $mod_netgear, $pc_netgear);
	my $mod_actiontec = &count_query("SELECT COUNT(*) FROM $ap_tbl WHERE Manuf LIKE \"%Actionte%\"");
	$counted_mods += $mod_actiontec;
	my $pc_actiontec = ($mod_actiontec/$nets_total)*100;
	printf("Actiontec:\t\t%d \t[%.2f%%]\n", $mod_actiontec, $pc_actiontec);
	my $mod_belkin = &count_query("SELECT COUNT(*) FROM $ap_tbl WHERE Manuf LIKE \"%Belkin%\"");
	$counted_mods += $mod_belkin;
	my $pc_belkin = ($mod_belkin/$nets_total)*100;
	printf("Belkin:\t\t\t%d \t[%.2f%%]\n", $mod_belkin, $pc_belkin);
	my $mod_apple = &count_query("SELECT COUNT(*) FROM $ap_tbl WHERE Manuf LIKE \"%Apple%\"");
	$counted_mods += $mod_apple;
	my $pc_apple = ($mod_apple/$nets_total)*100;
	printf("Apple:\t\t\t%d \t[%.2f%%]\n", $mod_apple, $pc_apple);
	my $mod_dlink = &count_query("SELECT COUNT(*) FROM $ap_tbl WHERE Manuf LIKE \"%D-Link%\"");
	$counted_mods += $mod_dlink;
	my $pc_dlink = ($mod_dlink/$nets_total)*100;
	printf("D-Link:\t\t\t%d \t[%.2f%%]\n", $mod_dlink, $pc_dlink);	
	my $mod_unknown = &count_query("SELECT COUNT(*) FROM $ap_tbl WHERE Manuf=\"Unknown\"");
	$counted_mods += $mod_unknown;
	my $pc_unknown = ($mod_unknown/$nets_total)*100;
	printf("Unknown:\t\t%d \t[%.2f%%]\n", $mod_unknown, $pc_unknown);
	my $other_mods = $nets_total-$counted_mods;
	my $pc_othermods = ($other_mods/$nets_total)*100;
	printf("Others:\t\t\t%d \t[%.2f%%]\n\n", $other_mods, $pc_othermods);
}

# Search SSIDs for strings if -s flag is set
if ($scan_flag) {
	print "---SSID string search requested---\n";
	foreach my $str (@scan_ssids) {
		my $tally = &count_ssid($str);
		printf("Number of SSIDs containing the string \"%s\": %s\n", $str, $tally);
	}
	print "\n";
}

if ($ssid_flag == 1) {
	# Top SSIDs
	&rank_field("ESSID", $topranked, "Top $topranked most common SSIDs", $nets_total);
}

&list_chans($nets_total, $dbh);

if ($chan_flag == 1) {
	# Channel rankings
	&rank_field("Channel", 11, "802.11 channels by rank", $nets_total);
}

if ($vendor_flag == 1) {
	# Top manufacturers
	&rank_field("Manuf", $topranked, "Top $topranked router manufacturers", $nets_total);
}

if ($ip_flag == 1) {
	# Top router IPs
	&rank_field("IP", $topranked, "Top $topranked (local) router IP addresses", $nets_total);
}

# Cleanup
$sth->finish();
$dbh->disconnect();
exit 0;

# Returns the number of rows that match a given COUNT query (note: query *must* return an integer)
sub count_query #($query) returns int
{
	my $query = shift;
	my $sth = $dbh->prepare($query);
	$sth->execute() or die $!;
	my(@row) = $sth->fetchrow_array();
	die "Error: query passed to count_query() returned a non-integer" unless ($row[0] =~ /^[+-]?\d+$/);
	return $row[0];
}

# Prints a list of the top $num repeated entries for $field
# $headstr is a string printed before the list, $setsize is the divisor used to calculate percentages
# $dbh is the database handler object
sub rank_field #($field, $num, $headstr, $setsize) returns void
{
	my $field = shift;
	my $num = shift;
	my $headstr = shift;
	my $setsize = shift;
	my $query = "SELECT $field,COUNT(*) AS count FROM wireless GROUP BY $field ORDER BY count DESC";
	if ($field =~ /^ESSID$/) {
		$query = "SELECT ESSID,COUNT(*) AS count FROM wireless WHERE Cloaked='false' GROUP BY ESSID ORDER BY count DESC";
	}
	if ($field =~ /^Manuf$/) {
		$query = "SELECT Manuf,COUNT(*) AS count FROM wireless WHERE Manuf<>'Unknown' GROUP BY Manuf ORDER BY count DESC";
	}
	my $sth = $dbh->prepare($query);
	$sth->execute() or die $!;
	print "$headstr:\n";
	
	for (my $i=0; $i<$num; $i++) {
		my(@row) = $sth->fetchrow_array();
		if (!defined($row[0])) { last; }
		my $marker = '#'.($i+1).':';
		my $value;
		my $count = $row[1];
		my $percentage = ($count/$setsize)*100;
		if ($field =~ /^Channel$/) {
			$value = "Ch".$row[0];
		} else {
			$value = $row[0];
		}
		printf("%-6s%-20s%-7d[%.2f%%]\n", $marker, $value, $count, $percentage);
	}
	print "\n";
}

sub list_chans #($setsize) returns void
{
	my $setsize = shift;
	my $query = "SELECT Channel,COUNT(*) AS count FROM wireless GROUP BY Channel ORDER BY Channel ASC";
	my $sth = $dbh->prepare($query);
	$sth->execute() or die $!;	
	print "802.11 channels by channel ID:\n";
	while (my(@row) = $sth->fetchrow_array()) {
		my $val = "Ch".$row[0];
		my $percent = ($row[1]/$setsize)*100;
		printf("%-26s%-7d[%.2f%%]\n", $val, $row[1], $percent);
	}
	print "\n";
}

# Returns the number of rows/access points which have identical BSSIDs
sub bssid_clash #($nets_total) returns int
{
	my $nets_total = shift or die $!;
	my $sth = $dbh->prepare("SELECT COUNT(DISTINCT BSSID) FROM wireless");
	$sth->execute() or die $!;
	my(@row) = $sth->fetchrow_array();
	if (!defined($row[0])) { return 0; }
	return $nets_total-$row[0];
}

# Returns the number of rows which contain $str in their ESSID field
sub count_ssid #($str) returns int (number ESSIDs $str is found in)
{
	my $str = shift;
	my $sth = $dbh->prepare("SELECT COUNT(*) FROM wireless WHERE ESSID LIKE \"%$str%\"");
	$sth->execute() or die $!;
	my(@row) = $sth->fetchrow_array();
	if (!defined($row[0])) { return 0; }
	return $row[0];
}

# Returns a list of IP subnets in the form [ "n.n.n.*", count ]
sub rank_subnets
{
	my(@subnets)=();
	my $sth = $dbh->prepare("SELECT IP FROM wireless WHERE IP<>'undefined'");
	$sth->execute() or die $!;
	for (my $i=0; $i<$sth->rows; $i++) {
		my(@row) = $sth->fetchrow_array();
		my(@ip) = split(/./, $row[0]);
		my $subnet = $ip[0].'.'.$ip[1].'.'.$ip[2].'.*';
		push(@subnets, $subnet);
	}
}

# Prints help message and exits on signal 1
sub usage
{
	print "Usage: kistat.pl [SQLite file] [OPTIONS]...\n";
	print "Given an SQLite database output by giskismet, this script calculates and prints a mass of statistics for that data\n";
	print "If no DB filename is given, wireless.dbl is used by default\n\n";
	print "OPTIONS:\n";
	print "   -s, --search <STRING(S)>:\n";
	print "\tPrints a count of the number of SSIDs containing the given string(s).\n";
	print "\tArguments can be given as a comma-separated list, ex: kistat.pl -s net,print,home\n";
	print "\tNote: escape spaces by prefacing with a backslash; do not enclose strings with quotations\n";
	print "   -r, --ranks:\n";
	print "\tPrints a list of the top $topranked SSIDs, vendors, and router LAN IPs, and 11 channels\n";
	print "   -m\n";
	print "\tPrints list of aggregate router manufacturers, by percentage\n";
	print "\t(categories: Cisco, Belkin, Netgear, Actiontec, Apple, D-Link, Unknown and Other)\n";
	print "   --ssids, --vendors, --channels, --ips\n";
	print "\tPrints ranking list of each category individually (default is to print none)\n\n";
	exit 1;
}
