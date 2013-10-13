# Ames, IA Wardriving project data (2013)
## Compiled by Kevin Buchik (<kdbuchik@gmail.com>)

## About
This dataset contains 27,832 wireless networks collected from Ames, Iowa between August 12th, 2013 and September 30th, 2013. This directory was originally prepared for a talk I gave on wardriving at the Information Assurance Student Group (IASG) at Iowa State University on October 15th, 2013, and will not be updated afterward, except for error corrections and updates to this readme file.

The wireless data in this project was collected using [Kismet-newcore](https://kismetwireless.net/) release 2011-03-R2 running under a Backtrack 5 virtual machine, and using an ALFA AWUS036H USB wifi adapter with a 5 dB antenna. Parsing of raw Kismet XML files into the database (wireless.dbl), and generation of the KML maps, was done using [giskismet](https://trac.assembla.com/giskismet/) version 0.02. The "statistics.txt" file was generated using [kistat.pl](https://github.com/kbuchik/wardriving/blob/master/scripts/kistat.pl), a script I wrote specifically for this project, which can be found in the /scripts/ directory of this repository.

I have also included (in kismet-data.tar.gz) gpsxml and netxml data files from Kismet for each wardriving run that comprised the data from this project. The only major aspect of the project omitted from this repository was the .pcapdump (raw packet data) files, which could contain some personally identifying information [captured](http://googleblog.blogspot.com/2010/05/wifi-data-collection-update.html) from open networks. (I haven't yet analyzed them in depth, but a [cursory check](https://www.cookiecadger.com/) indicates they don't contain anything terribly interesting)

## Files
* wireless.dbl -> SQLite database containing the raw import of .netxml data from Kismet, using the giskismet script.
* statistics.txt -> Unformatted list of counts/percentages from various cross-sections of the dataset. Generated with the command `kistat.pl -m -r wireless.dbl`
* kismet-data.tar.gz -> Archive of raw .netxml (describes networks) and .gpsxml (describes packets) data from Kismet
* KMLs -> Map files; open with Google Earth or another GIS program (or generate your own with `giskismet -q "[query]" -o [output].kml`. The query used to generate each is given.
	+ Ames-all networks.kml
		- **"SELECT * FROM wireless"**
	+ Ames-hidden networks.kml
		- **"SELECT * FROM wireless WHERE Cloaked='true'"**
	+ Ames-ISU networks.kml
		- **"SELECT * FROM wireless WHERE ((ESSID='IASTATE' OR ESSID='ISU-CARDINAL') AND Encryption='None') OR ESSID='eduroam' OR ESSID='ISU-PRESS' OR ESSID='ISU-PREMIUM' OR ESSID LIKE 'CNDE'"**
	+ Ames-open networks.kml
		- **"SELECT * FROM wireless WHERE Encryption='None'"**
	+ Ames-WEP networks.kml
		- **"SELECT * FROM wireless WHERE Encryption='WEP'"**


