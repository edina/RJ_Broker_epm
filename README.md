RJ_Broker_epm
=============

This is the SWORD importer to receive deposit packages from the Repository Junction Broker. 

This is the EPrints Bazaar package that is compatible with EPrints 3.3
For EPrints 3.2, use https://github.com/edina/RJ_Broker_Importer_3.2

It has been tested with 3.3.5 (the first released version) and 3.3.12 (the current version at the time of release)

INSTALLATION
----------------------

1) Install the SWORD v1.3 (legacy) plugin from the Bazaar

2) Download & unpack the .zip file, or clone the .git repository

3) Use the "Choose File" at the bottom of the "Available packages" list to upload & install the RJ_Broker.epm file

You can check that the new configuration has been loaded by getting the SWORD servicedocument & looking for the sword:acceptPackaging with a value of "http://opendepot.org/broker/1.0"

For deposits to go direct into the live archive (rather than going into the 
review queue), you need to enable that facility within the local SWORD 
configuration.

Edit the file /<path_to_eprints_root>/archives/<archive_id>/cfg/cfg.d/sword13.pl
and un-comment the section that starts 
	"archive" => {
			title => "Live Repository",


When arranging registration details with Repository Junction Broker, the 
"collection" part will be one of:
   /sword-app/deposit/inbox   (which goes into the users personal workspace)
   /sword-app/deposit/review  (which goes into the review queue for the repo)
   /sword-app/deposit/archive (which goes directly into the live repository)


Finally, we need to fix a flaw in the core EPrints code, so that SWORD deposits return the URI for the deposited item, not just the ID number.
The code is on the file ~~/eprints/lib/plugins/EPrints/Sword/Utils.pm, and you need to edit just one line - find the line:

	$uid->appendChild( $session->make_text( $eprint->get_id ) );

And edit it to read:

	$uid->appendChild( $session->make_text( 
                                        $session->get_repository->get_conf( "base_url" )
                                      . '/id/eprint/'
                                      . $eprint->get_id 
                                        )
                            );

TESTING
-------------
The directory "example export files" contains some sample records, along with instructions
for testing the raw deposit process.
