# Wardriving tools
Perl scripts I've written for analyzing/mapping wardriving data from Kismet-newcore XMLs and giskismet database. I will be supporting and updating the scripts in this directory as best I can, if at least one person (myself included) continues to find them useful. Feel free to clone/fork this repo and modify any of them to your liking. Any comments/questions/complaints (or if you find any of these useful) should be directed to kdbuchik@gmail.com

## DISCLAIMER
None of these tools have been extensively tested for bugs, nor have I gone to great lengths to idiot-proof the argument parsing code. Enough basic error-checked has been implemented so that they should work fine, if you follow the directions. Use at your own risk. Backing up database files before running scripts that modify them (such as parse\_gpsxml.pl) is highly recommended.

## Contents

### Kistat.pl
Kistat (the most creative name ever) is a statistics aggregator for giskismet databases, which I wrote mainly to automate analysis of data to go in my "Anatomy of a Wardrive" talk. Runs several dozen SQL queries on the database, calculates percentages, generates top ten lists/rankings for things like encryption, manufacturers, etc. Warning: hackish. No comprehensive error-checking. Will likely be updated and improved over the coming weeks.

Help message:

`kistat.pl [SQLite file] [OPTIONS]...
Given an SQLite database output by giskismet, this script calculates and prints a mass of statistics for that data
If no DB filename is given, wireless.dbl is used by default

OPTIONS:
   -s, --search <STRING(S)>:
	Prints a count of the number of SSIDs containing the given string(s).
	Arguments can be given as a comma-separated list, ex: kistat.pl -s net,print,home
	Note: escape spaces by prefacing with a backslash; do not enclose strings with quotations
   -r, --ranks:
	Prints a list of the top 15 SSIDs, vendors, and router LAN IPs, and 11 channels,
   -m
	Prints list of aggregate router manufacturers, by percentage
	(categories: Cisco, Belkin, Netgear, Actiontec, Apple, D-Link, Unknown and Other)
   --ssids, --vendors, --channels, --ips
	Prints ranking list of each category individually (default is to print none)`

### drivetimer.pl
Simple script to calculate the amount of time spent wardriving (more specifically, with Kismet capturing data) by extracting timestamps from Kismet's gpsxml files. Run on a single file for the number seconds and hr/min/sec total time from that file. Run without a file argument and it will calculate time over all gpsxml files in the current directory.

Help message:

`drivetimer.pl [OPTIONS] [.gpsxml file]
If no .gpsxml file is given, script will attempt to parse all XML files in the current directory

OPTIONS:
   -v:
	Verbose mode (print additional messages for each file parsed)`

### gps\_extractor.pl
Very simple script to extract gpscoordinate pairs from giskismet databases for GIS analysis, etc. Options allow switching from space-separated, comma-separated, or XML format.
May be replaced in the future with a more comprehensive script that runs full queries.

Help message:

`gps_extractor.pl [OPTIONS] <dbfile>
Extract GPS coordinates from a giskismet database
If no DB filename is given, "wireless.dbl" is used by default

OPTIONS:
   --csv, --xml
	By default, the coordinates are printed in the form "[lat] [lon]"
	--csv prints in the form: "[lat],[lon]"
	--xml prints in the form: <ap latitude="[lat]" longitude="[lon]" />`

### parse\_gpsxml.pl
Parses packet metadata from Kismet's gpsxml files and imports to an SQLite database (use the corresponding wireless.dbl from giskismet for compatibility with tools like packetmap.pl). gpsxml files contain information about every packet received during a wardriving run, including GPS coordinates, source BSSID and signal strength.

Help message:

`parse_gpsxml.pl [OPTIONS] <gpsxml file>
Parses gpsxml files from kismet-newcore and imports them into a database

OPTIONS:
   -d, --database [SQLite file]
	Use database file (default: wireless.dbl)`

### packetmap.pl
Generates KML maps showing all packets received from a given access point, and approximates the location of the AP using the centroid (geometric average) algorithm. Location estimatation using trilateration is under development. The packet with the highest signal strength is colored green (this is where Kismet places the access point by default); lowest signal strength is colored red; all other packets are colored yellow. This script requires a giskismet database which has been loaded with packet data using my parse\_gpsxml.pl script.
