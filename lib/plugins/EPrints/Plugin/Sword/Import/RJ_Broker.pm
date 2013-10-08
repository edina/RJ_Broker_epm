package EPrints::Plugin::Sword::Import::RJ_Broker;

use strict;

use XML::LibXML 1.63;

#use Data::Dumper;
use EPrints::Plugin::Sword::Import;
our @ISA = qw/ EPrints::Plugin::Sword::Import /;

our %SUPPORTED_MIME_TYPES = ( "application/zip" => 1, );

our %UNPACK_MIME_TYPES = ( "application/zip" => "Sword::Unpack::Sub_Zip", );

sub new {
  my ( $class, %params ) = @_;
  my $self = $class->SUPER::new(%params);
  $self->{name}
      = "SWORD Importer - Repository Junction Broker (Default EPrints)";

  # Make it visible on the import menu and elsewhere
  $self->{visible} = "all";
  $self->{produce} = [ 'dataobj/eprint' ];
       
  return $self;
} ## end sub new

###        $opts{file} = $file;
###        $opts{mime_type} = $headers->{content_type};
###        $opts{dataset_id} = $target_collection;
###        $opts{owner_id} = $owner->get_id;
###        $opts{depositor_id} = $depositor->get_id if(defined $depositor);
###        $opts{no_op}   = is this a No-op?
###        $opts{verbose} = is this verbosed?
sub input_file {
  my ( $plugin, %opts ) = @_;

  my $session = $plugin->{session};

  my $dir  = $opts{dir};
  my $mime = $opts{mime_type};
  my $file = $opts{file};

  my $NO_OP = $opts{no_op};

  my $log_dir = $session->config('archiveroot');
  my $LOGDIR  = "$log_dir/var";
  my $logging = "|Broker_Sword_Import";

  # barf unless we have been given a .zip file
  unless ( defined $SUPPORTED_MIME_TYPES{$mime} ) {
    $plugin->add_verbose("[ERROR] unknown MIME TYPE '$mime'.");
    $plugin->set_status_code(415);
    return undef;
  }

  my $unpacker = $UNPACK_MIME_TYPES{$mime};

  my $tmp_dir;

  # This is localised simply so we can have a bunch of variables to deduce the
  # METS file I want (I know the file will be called mets.xml, and I know it
  # will be at the top of the tree.
  # It also barfs if we can't unzip the file given.
  {
    $tmp_dir = EPrints::TempDir->new( "swordXXXX", UNLINK => 1 );

    if ( !defined $tmp_dir ) {
      print STDERR
          "\n[SWORD-DEPOSIT] [INTERNAL-ERROR] Failed to create the temp directory!";
      $plugin->add_verbose("[ERROR] failed to create the temp directory.");
      $plugin->set_status_code(500);
      return undef;
    } ## end if ( !defined $tmp_dir)

    my $files = $plugin->unpack_files( $unpacker, $file, $tmp_dir );

    unless ( defined $files ) {
      $plugin->add_verbose("[ERROR] failed to unpack the files");
      return undef;
    }

    my $candidates = $plugin->get_files_to_import( $files, "text/xml" );

    if ( scalar(@$candidates) == 0 ) {
      $plugin->add_verbose("[ERROR] could not find the XML file");
      $plugin->set_status_code(400);
      return undef;
    }
    elsif ( scalar(@$candidates) > 1 ) {

      # We have more than one possible xml file. Take 'mets.xml' if it exists,
      # otherwise just take the one with the 'highest' name, alphabetic-wise
      my @mets = grep /\bmets\.xml$/, @$candidates;

      if ( scalar(@mets) == 1 ) {
        $$candidates[0] = $mets[0];
        $plugin->add_verbose(
          "[WARNING] there were more than one XML file in this archive, however I'm using the one called 'mets.xml'"
        );
      }
      elsif ( scalar(@mets) > 1 ) {
        @$candidates = sort { length($a) cmp length($b) } @mets;
        $plugin->add_verbose(
          "[WARNING] there were more than one mets.XML file in this archive, however I'm using the one closest to the top of the 'tree'"
        );
      }
      else {
        @mets = sort @$candidates;
        $$candidates[0] = $mets[0];
        $plugin->add_verbose(
          "[WARNING] there were more than one XML file in this archive. I am using the one with the 'highest' name, alphabetic-wise (closer to 'z' than 'A')"
        );
      } ## end else [ if ( scalar(@mets) == ...)]
    } ## end elsif ( scalar(@$candidates...))

    $file = $$candidates[0];

  } ## end if ( defined $unpacker)

# OK - so $file now contains the path & filenamne of the mets.xml file we're importing
# $tmp_dir is the directory that the .zip file has been unpacked into.

  my $dataset_id   = $opts{dataset_id};
  my $owner_id     = $opts{owner_id};
  my $depositor_id = $opts{depositor_id};

  my $fh;
  if ( !open( $fh, $file ) ) {
    $plugin->add_verbose(
      "[ERROR] couldnt open the file: '$file' because '$!'");
    $plugin->set_status_code(500);
    return;
  } ## end if ( !open( $fh, $file...))

  # next problem: sometimes we end up with an extra directory in the stack
  # (as in $tmp_dir/content/stuff)
  # we need to pull "content/" off the file names
  my $unpack_dir;
  my $fntmp;

  $fntmp = $file;

  if ( $fntmp =~ /^(.*)\/(.*)$/ ) {
    $unpack_dir = $1;
    $fntmp      = $2;
  }

# $tmp_dir is the temporary directory
# $file is the name of the mets.xml file in that directory
# $unpack_dir is whatever 'content/' actually turns out to be (if anything)
# $fntmp is the mets.xml file we're going to import (under $tmp_dir/$unpack_dir)

  # Finally, we can read the xml from the file:
  my $xml;
  while ( my $d = <$fh> ) {
    $xml .= $d;
  }
  close $fh;

  # $dataset is the EPrints object for where we're putting the deposit
  my $dataset = $session->get_archive()->get_dataset($dataset_id);

# again, barf if the dataset is not provided (though as this is through SWORD,
# this shouldn't happen
  if ( !defined $dataset ) {
    print STDERR
        "\n[SWORD-METS] [INTERNAL-ERROR] Failed to open the dataset '$dataset_id'.";
    $plugin->add_verbose(
      "[INTERNAL ERROR] failed to open the dataset '$dataset_id'");
    $plugin->set_status_code(500);
    return;
  } ## end if ( !defined $dataset)

# convert the xml text to a LibXML dom-object
# What EPrints doesn't do is validate, it just checks for well-formed-ness
# We have it in an eval block in case the xml is not well-formed, as the parser
# throws an exception if the document is invalid
  my $dom_doc;
  eval { $dom_doc = EPrints::XML::parse_xml_string($xml); };

  # No dom? barf
  if ( $@ || !defined $dom_doc ) {
    $plugin->add_verbose("[ERROR] failed to parse the xml: '$@'");
    $plugin->set_status_code(400);
    return;
  }

  if ( !defined $dom_doc ) {
    $plugin->{status_code} = 400;
    $plugin->add_verbose("[ERROR] failed to parse the xml.");
    return;
  }

  # If the top element is not mets, barf
  # This is just in case someone sends us a non METS xml file
  my $dom_top = $dom_doc->getDocumentElement;

  if ( lc $dom_top->tagName ne 'mets' ) {
    $plugin->set_status_code(400);
    $plugin->add_verbose(
      "[ERROR] failed to parse the xml: no <mets> tag found.");
    return;
  } ## end if ( lc $dom_top->tagName...)

  #####
  # Now we dig down to get the xmldata from the METS dmdSec section
  #####

  # METS Headers (ignored)
  my $mets_hdr = ( $dom_top->getElementsByTagName("metsHdr") )[0];

  # METS Descriptive Metadata (main section for us)

  # need to loop on dmdSec:
  my @dmd_sections = $dom_top->getElementsByTagName("dmdSec");
  my $dmd_id;

  my $md_wrap;
  my $found_wrapper = 0;

  # METS can have more than one dmdSec, and we can't assume that what's
  # pushed in conforms to what we want, so we want to find the stuff
  # formally idendtified as containing epdcx
  # (I know it doesn't guarentee anything, but its a start!)
  foreach my $dmd_sec (@dmd_sections) {

    # need to extract xmlData from here
    $md_wrap = ( $dmd_sec->getElementsByTagName("mdWrap") )[0];

    next if ( !defined $md_wrap );

    next
        if (
      !(   lc $md_wrap->getAttribute("MDTYPE") eq 'other'
        && defined $md_wrap->getAttribute("OTHERMDTYPE")
        && lc $md_wrap->getAttribute("OTHERMDTYPE") eq 'epdcx'
      )
        );

    $found_wrapper = 1;
    $dmd_id        = $dmd_sec->getAttribute("ID");
    last;
  } ## end foreach my $dmd_sec (@dmd_sections)

  unless ($found_wrapper) {
    $plugin->set_status_code(400);
    $plugin->add_verbose(
      "[ERROR] failed to parse the xml: could not find epdcx <mdWrap> section."
    );
    return;
  } ## end unless ($found_wrapper)

  #########
  # Now we get the (hopefully epdcx) xml from the xmlData section
  ########
  my $xml_data = ( $md_wrap->getElementsByTagName("xmlData") )[0];

  if ( !defined $xml_data ) {
    $plugin->set_status_code(400);
    $plugin->add_verbose(
      "[ERROR] failed to parse the xml: no <xmlData> tag found.");
    return;
  } ## end if ( !defined $xml_data)

  ########
  # and parse it into a hash
  ########
  my $epdata = $plugin->parse_epdcx_xml_data($xml_data);
  return unless ( defined $epdata );

  # Add some useful (SWORD) info
  if ( defined $depositor_id ) {
    $epdata->{userid}          = $owner_id;
    $epdata->{sword_depositor} = $depositor_id;
  }
  else {
    $epdata->{userid} = $owner_id;
  }

  $epdata->{eprint_status} = $dataset_id;

  # We now want to deal with the associated files (if any).
  # This is not a straight "every file is a document" import: EPrints has this
  # weird thing where a "document" can have multiple files. The Broker deals
  # with this by having defining the structure in <structMap>, and putting
  # each document into a <div>. If there are multiple files, the main file is
  # the first file in the set

  # The first thing to do is create a list of all the files & their IDs

  # File Section which will contain optional info about files to import:
  my %files;
  my $file_counter = 0;
  foreach my $file_sec ( $dom_top->getElementsByTagName("fileSec") ) {
    my $file_grp = ( $file_sec->getElementsByTagName("fileGrp") )[0];

    $file_sec = $file_grp
        if ( defined $file_grp )
        ;    # this is because the <fileGrp> tag is optional

    foreach my $file_div ( $file_sec->getElementsByTagName("file") ) {
      my $file_id  = $file_div->getAttribute("ID");
      my $file_loc = ( $file_div->getElementsByTagName("FLocat") )[0];
      if ( defined $file_loc ) {    # yeepee we have a file (maybe)

        my $fn = $file_loc->getAttribute("href");

        unless ( defined $fn ) {

          # to accommodate the gdome XML library:
          $fn = $file_loc->getAttribute("xlink:href");
        }

        next unless ( defined $fn );

        $files{$file_id} = $fn;     # list files to get locally
      } ## end if ( defined $file_loc)
    } ## end foreach my $file_div ( $file_sec...)
  } ## end foreach my $file_sec ( $dom_top...)

  unless ( scalar keys %files ) {
    $plugin->add_verbose(
      "[WARNING] no <fileSec> tag found: no files will be imported.");
  }

  # we also need to hang onto details about where the importer unpacked stuff.
  # I know it's nothing to do with files in the METS manifest, however this is
  # probably the best place to keep them :)
  $files{unpack_dir} = $unpack_dir;
  $files{fntmp}      = $fntmp;

  # Oh - if the SWORD conenction has specified NO-OP, then don't actually
  # go any further
  if ($NO_OP) {

    # need to send 200 Successful (the deposit handler will generate
    # the XML response)
    $plugin->add_verbose(
      "[OK] Plugin - import successful (but in No-Op mode).");
    $plugin->set_status_code(200);
    return;
  } ## end if ($NO_OP)
  my $eprint = $dataset->create_object( $plugin->{session}, $epdata );

  unless ( defined $eprint ) {
    $plugin->set_status_code(500);
    $plugin->add_verbose("[ERROR] failed to create the EPrint object.");
    return;
  }

  $logging .= "|" . $eprint->get_id;

 # Having created a base EPrint, and determined what files we have to add
 # to it, and we're actually going to deposit it, we need to create a "map"
 # of what files go where from the <structMap> element.
 # $dmd_id contains the ID for the div we're looking for
 #
 # Oh, and a complication: the embargo information is kept in the
 # amdSec, so we need to find any embargo dates.
 # There will be two options: ClosedAccess and RestrictedAccess (RJB doesn't
 # record OpenAccess dated)
 # The system needs to map the resourceId of the epdcx:description to both the
 # rightsAccess and the date
  $xml_data = "";
  my $amdSec = ( $dom_top->getElementsByTagName("amdSec") )[0];
  $xml_data = ( $amdSec->getElementsByTagName("xmlData") )[0];
  $files{'embargo_hash'} = $plugin->parse_rights_data($xml_data) if $xml_data;

  my ( $embargo, $security );
  foreach my $structMap ( $dom_top->getElementsByTagName("structMap") ) {

    # we want the [first] div that has a dmdid that matches $dmd_id
    my $div;
    my @divs = $structMap->getElementsByTagName("div");    #childNodes;
    foreach my $d (@divs) {
      next unless $d->hasAttribute('DMDID');
      my $v = $d->getAttribute('DMDID');
      next unless $v eq $dmd_id;
      $div = $d;
    } ## end foreach my $d (@divs)

    if ($div) {

      my $doc_data_ref = {};
      my @nodes        = $div->getElementsByTagName("div");    #childNodes;

      # As we need the embargo details later on, we have our own
      # process_struct_elements routine that adds embargos and returns
      # the embargo date and the security restriction.
      my $document;
      ( $document, $embargo, $security )
          = process_struct_elements( \@nodes, \%files, $doc_data_ref, $eprint,
        $session );

      if ( !defined $document ) {
        $plugin->add_verbose("[WARNING] Failed to create Document object.");
      }
    } ## end if ($div)
  } ## end foreach my $structMap ( $dom_top...)

  if ( $plugin->keep_deposited_file() ) {
    if (
      $plugin->attach_deposited_file(
        $eprint, $opts{file}, $opts{mime_type}, $embargo, $security
      )
        )
    {
      $plugin->add_verbose("[OK] attached deposited file.");
    }
    else {
      $plugin->add_verbose("[WARNING] failed to attach the deposited file.");
    }
  } ## end if ( $plugin->keep_deposited_file...)

  $plugin->add_verbose("[OK] EPrint object created.");

  # Keep a track of the logging
  my $log_string = scalar(CORE::localtime) . "$logging";
  open( LOG, ">>$LOGDIR/transfer_log" )
      or warn("could not open log file $LOGDIR/transfer_log");
  print LOG "$log_string\n";
  close(LOG);

  # and let's put it in the error_log too since it's dead useful
  $plugin->{session}->log("logging|$log_string");

  return $eprint;

} ## end sub input_file

# This is where we actually track & build the stuff that
# adds the files. It also sets any embargo period.
# As we need the embargo details later on, it returns the
# embargo date and the security restriction.
sub process_struct_elements {
  my ( $nodes_ref, $files_hashref, $doc_data_ref, $eprint, $session ) = @_;

  my $hash_ref = {};

  my $document;

  my $unpack_dir   = $files_hashref->{unpack_dir};
  my $embargo_hash = $files_hashref->{embargo_hash};

  my ( $embargo, $security );
  $security = 'staffonly';

  # Go through all the children
  foreach my $element ( @{$nodes_ref} ) {
    my $ID = $element->getAttribute("ID");

    if ( exists $embargo_hash->{$ID} ) {
      $embargo = $embargo_hash->{$ID}->{'date'};
    }
    my @fptrs = $element->getElementsByTagName("fptr");    #childNodes;

    # check to see what element it is
    if ( scalar @fptrs ) {
      my $doc_data = {};
      foreach my $fptr (@fptrs) {
        my $fileid = $fptr->getAttribute("FILEID");
        my $file   = $files_hashref->{$fileid};
        $file =~ m/^(\w+)/;
        my $prot = $1 if $1;
        $file =~ m/\/([^\/]+)$/;    # find everything after the last slash
        my $filename = $1 if $1;

       # if the file is not a web reference, add 'file://' and the unpack path
       # to the filename
        for ($prot) {
          /http/ && do { last; };    # $filename stays unchanged

          {                          # default option
            $file =~ s#^#file://$unpack_dir/#;
            last;
          };
        } ## end for ($prot)

        $doc_data->{_parent} = $eprint
            unless defined $doc_data->{_parent};
        $doc_data->{eprintid} = $eprint->get_id
            unless defined $doc_data->{eprintid};
        $doc_data->{main} = $filename unless $doc_data->{main};
        $doc_data->{format}
            = $session->get_repository->call( 'guess_doc_type', $session,
          $filename )
            unless exists $doc_data->{format};
        if ($embargo) {
          $doc_data->{date_embargo} = $embargo;
          $doc_data->{security}     = $security;
        }

        my %file_data;
        $file_data{filename} = $filename;
        $file_data{url}      = $file;

        $doc_data->{files} = [] unless exists $doc_data->{files};
        push @{ $doc_data->{files} }, \%file_data;
      } ## end foreach my $fptr (@fptrs)

      my $doc_dataset = $session->get_repository->get_dataset("document");
      local $session->get_repository->{config}->{enable_web_imports}  = 1;
      local $session->get_repository->{config}->{enable_file_imports} = 1;
      $document
          = EPrints::DataObj::Document->create_from_data( $session, $doc_data,
        $doc_dataset );
    } ## end if ( scalar @fptrs )

  } ## end foreach my $element ( @{$nodes_ref...})

  return ( $document, $embargo, $security );

} ## end sub process_struct_elements

sub add_file {
  my ( $eprint, $hash_ref, $unpack_dir ) = @_;

  my $prot;

  my $file = $hash_ref->{'file'};
  $file =~ m/^(\w+)/;
  $prot = $1 if $1;
  $file =~ m/\/([^\/]+)$/;    # find everything after the last slash
  my $filename = $1 if $1;

  return undef unless $filename;
  $filename =~ s# #\ #g;      # replace spaces with '\ '
    # if the file is not a web reference, add 'file://' and the unpack path to the
    # filename
  for ($prot) {
    /http/ && do {

      # $filename stays unchanged
      last;
    };
    {
      $file =~ s#^#file://$unpack_dir/# if $file;
      last;
    };
  } ## end for ($prot)

  my $session = $hash_ref->{'session'};

  # Setup: we return a doc_data hash.
  # If one is passed in, we update & return that, else create a new one.
  my $doc_data = {};

  $doc_data->{_parent} = $eprint unless defined $doc_data->{_parent};
  $doc_data->{eprintid} = $eprint->get_id
      unless defined $doc_data->{eprintid};
  $doc_data->{main} = $filename unless $doc_data->{main};
  $doc_data->{format}
      = $session->get_repository->call( 'guess_doc_type', $session,
    $filename )
      unless exists $doc_data->{format};

  my %file_data;
  $file_data{filename} = $filename;
  $file_data{url}      = "$file";

  $doc_data->{files} = [ \%file_data ];

  return $doc_data;

} ## end sub add_file

sub keep_deposited_file {
  return 1;
}

sub parse_epdcx_xml_data {
  my ( $plugin, $xml ) = @_;

  my $set = ( $xml->getElementsByTagName("descriptionSet") )[0];

  unless ( defined $set ) {
    $plugin->set_status_code(400);
    $plugin->add_verbose("ERROR: no <descriptionSet> tag found.");
    return;
  }

  my $epdata         = {};
  my @creators_array = ();

  foreach my $desc ( $set->getElementsByTagName("description") ) {

    my $att = $desc->getAttribute("epdcx:resourceId");

    for ($att) {

      #  title; abstract; identifer (publisherID);
      #  creator; affilitated institution (from authors)
      # Note: we need to pass in the full $set so we can find
      # creator info
      m#^sword-mets-epdcx# && do {
        $plugin->_parse_epdcx( $desc, $epdata, $set );
        last;
      };

      # type; doi; date (yyyy-mm-dd); status; publisher; copyright_holder;
      m#^sword-mets-expr# && do {
        $plugin->_parse_expr( $desc, $epdata );
        last;
      };

      # publication; issn; isbn; volume; issue; pages;
      m#^sword-mets-manif# && do {
        $plugin->_parse_manif( $desc, $epdata, $set );
        last;
      };
    }
  } ## end foreach my $desc ( $set->getElementsByTagName...)

  return $epdata;
} ## end sub parse_epdcx_xml_data

# Parser for the "work" level
#  item type; title; abstract; identifer (publisherID);
#  creator; affilitated institution (from authors)
#  Funder (a ';' seperated list); Grant codes (also a ';' seperated list)
# epdata is passed in, therefore the routine modifies the actual hash
sub _parse_epdcx {
  my ( $plugin, $desc, $epdata, $set ) = @_;

  foreach my $stat ( $desc->getElementsByTagName("statement") ) {
    my ( $field, $value ) = _parse_statement($stat);

    for ($field) {

      # Note - for creators, we have two resources of information
      # 1) There is the name string here in the 'work' section
      # 2) The broker also stores an extended record in a seperate
      #    description with a known resourceId... a resourceId that
      #    matches the $attr value returned here.
      m#creator# && do {
        my ( $name, $attr ) = split /\t/, $value;

        my ( $family, $given, $email, $inst );

        # can we get the information from Person description?
        if ($attr) {
          foreach my $d ( $set->getElementsByTagName("description") ) {
            next unless $d->getAttribute('epdcx:resourceId') eq $attr;

            foreach my $stat2 ( $d->getElementsByTagName("statement") ) {
              my ( $field2, $value2 ) = _parse_statement($stat2);

              for ($field2) {

                m#givenname#  && do { $given  = $value2; last; };
                m#familyname# && do { $family = $value2; last; };
                m#email#      && do { $email  = $value2; last; };
              }
            }
          }
        }

        # if not, deduce it from the text here
        unless ($family) {
          if ( $name =~ /(\w+)\,\s?(.*)$/ ) {
            $family = $1, $given = $2;
          }
          else {
            $family = $value;
          }
        }

        # now add the information to the eprint
        # NOTE: eprints uses the index into arrays to syncronise
        # names, email addresses and other fields, so we have to
        # add something, even if its NULL
        push @{ $epdata->{creators_name} },
            { family => $family, given => $given };
        push @{ $epdata->{creators_id} }, $email;

        last;
      };

      m#title# && do {
        $epdata->{'title'} = $value;
        last;
      };

      m#abstract# && do {
        $epdata->{'abstract'} = $value;
        last;
      };

      m#identifier# && do {
        $epdata->{'id_number'} = $value;
        last;
      };

      # In EPrints, there is a "Funders" field, but no grant.
      # This is a repeating field, so we can push the items onto an array
      # To note grant codes, we are bodging the string:
      # <funder>: <grant>, <grant>, <grant>
      # ... it makes it human readable, and computer-parseable
      m#funders# && do {

        if ($value) {
          my ( $funder, $gcode );
          $funder = $value;
          $funder =~ s/^funder //;
          my @grants = ();
          foreach my $d ( $set->getElementsByTagName("description") ) {
            next unless $d->getAttribute('epdcx:resourceId') eq $value;

            foreach my $stat2 ( $d->getElementsByTagName("statement") ) {
              my ( $field2, $value2 ) = _parse_statement($stat2);
              if ( $field2 eq 'grant_code' ) {
                push @grants, $value2;
              }
            }
            if ( scalar @grants ) {
              $funder .= ': ';
              $funder .= join '; ', @grants;
            }
          }
          push @{ $epdata->{'funders'} }, $funder;
        }
        last;
      };

      # This becomes a pseudo-list (as EPrints doesn't have this
      # as a multiple field
      m#affiliatedInstitution# && do {
        my $i;
        $i = $epdata->{'institution'} if exists $epdata->{'institution'};
        if ($i) {
          my @i = split /; /, $i;
          push @i, $value;
          $value = join '; ', @i;
        }
        $epdata->{'institution'} = $value;
        last;
      };
    }

  } ## end foreach my $stat ( $desc->getElementsByTagName...)

} ## end if($att =~ /^sword-mets-/)...

# Parser for the "expression" level
# genre, citation, doi, status, publisher, editor (provenance for
# opendepot), date published
# epdata is passed in, therefore the routine modifies the actual hash
sub _parse_expr {
  my ( $plugin, $desc, $epdata ) = @_;
  foreach my $stat ( $desc->getElementsByTagName("statement") ) {
    my ( $field, $value ) = _parse_statement($stat);

    for ($field) {

      # This gets used once we have built the full record...
      m#type# && do {
        $epdata->{'type'} = $value;
        last;
      };

      # date (published)
      m#date# && do {
        $epdata->{ispublished} = 'pub';
        $epdata->{date}        = $value;
        $epdata->{date_type}   = 'published';
        last;
      };

      # This could be either a local identifier
      # a local identifier code, or a URI into the broker
      # We definitely don't want the latter.
      # Of the first two, take a doi in preference to a simple identifier
      m#identifier# && do {
        last
            if ( $value =~ /edina\.ac\.uk/ )
            ;    # skip anything that refers to edina
        my $i;
        $i = $epdata->{identifier} if exists $epdata->{identifier};
        last if ( $i =~ /doi\.org/ );    # skip if we already have a doi
        $epdata->{identifier} = $value;
        last;
      };

      # peer reviewed
      m#refereed# && do {
        $epdata->{'refereed'} = $value;
        last;
      };

      # we need to come back to this: for a thesis, the broker
      # understands that thesis are "institution; department"
      # whereas everything else is just "publisher"
      # stuff it in publisher for now, and sort it later
      m#publisher# && do {
        $epdata->{'publisher'} = $value;
        last;
      };

      m#provenance# && do {
        $epdata->{'provenance'} = $value;    # copyright_holder?
        last;
      };

    } ## end if ( defined $field )

  } ## end foreach my $stat ( $desc->getElementsByTagName...)

} ## end if($att =~ /^sword-mets-/)...

# Parser for the "manifest" level
# epdata is passed in, therefore the routine modifies the actual hash
sub _parse_manif {
  my ( $plugin, $desc, $epdata, $set ) = @_;
  foreach my $stat ( $desc->getElementsByTagName("statement") ) {
    my ( $field, $value ) = _parse_statement($stat);

    for ($field) {

      m#cite# && do {

        my $cite = clean_text($value);

        # now we need to decode the citation
        # $publication [$vol[($num)]][, $pps|$pgs]
        my ( $pub, $vol, $num, $pps, $pgs );

        # Start by pulling the page range or number of pages off the end
        if ( $cite =~ /\, (\d+(:?\-\d+))$/ ) {
          $cite =~ s/\, (\d+(:?\-\d+))$//;
          $num = $1 if $1;
          if   ( $num =~ /\-/ ) { $pps = $num }
          else                  { $pgs = $num }
          $num = undef;
        } ## end if ( $cite =~ /\, (\d+(:?\-\d+))$/)

        # Do we have volume number ?
        if ( $cite =~ /\((.+)\)$/ ) {
          $cite =~ s/\((.+)\)$//;
          $num = $1 if $1;
        }

        # Get the volume number
        if ( $cite =~ /\s+(\d+)$/ ) {
          $cite =~ s/\s+(\d+)$//;
          $vol = $1 if $1;
        }

        $pub = $cite;
        $epdata->{publication} = $pub
            if ( $pub && not exists $epdata->{publication} );
        $epdata->{volume} = $vol if ( $vol && not exists $epdata->{volume} );
        $epdata->{number} = $num if ( $num && not exists $epdata->{number} );
        $epdata->{pagerange} = $pps
            if ( $pps && not exists $epdata->{pagerange} );

        #          $epdata->{pages}       = $pgs if $pgs;
        last;
      };

      # issn & isbn
      m#issn# && do {
        $epdata->{'issn'} = $value;
        last;
      };
      m#isbn# && do {
        $epdata->{'isbn'} = $value;
        last;
      };

      # publication,volume, issue, pages
      # these trump anything from the citation
      m#publication# && do {
        $epdata->{'publication'} = $value;
        last;
      };
      m#volume# && do {
        $epdata->{'volume'} = $value;
        last;
      };
      m#issue# && do {
        $epdata->{'issue'} = $value;
        last;
      };
      m#pagerange# && do {
        $epdata->{'pagerange'} = $value;
        last;
      };
      m#pages# && do {

        # Pages has to be a numeric value!
        $epdata->{'pages'} = $value + 0;
        last;
      };

      # Available URLS (DOI, official_url, related urls)
      m#available_url# && do {
        # available-doi-1; available-official_url-1; available-related_url-4; ...
        # can we get the information from Person description?
        if ($value) {
          foreach my $d ( $set->getElementsByTagName("description") ) {
            next unless $d->getAttribute('epdcx:resourceId') eq $value;

            my $uri;
            $uri = $d->getAttribute('epdcx:resourceUrl');
            if ($value =~ /official/) {
              $epdata->{'official_url'} = $uri;
            } elsif ($value =~ /doi/) {
              $epdata->{'id_number'} = $uri;
            } else {
              push @{$epdata->{'related_url'}}, {url => $uri, type=>'pub'} if $uri
            }
          }
        };

        last;
      };
    } ## end if ( defined $field )

  } ## end foreach my $stat ( $desc->getElementsByTagName...)

} ## end if($att =~ /^sword-mets-/)...

# Parser for the unknown level
# This is where we try to find the author/creator information
# epdata is passed in, therefore the routine modifies the actual hash
sub _parse_unknown {
  my ( $plugin, $desc, $epdata ) = @_;
  $epdata->{unknown} = {} unless exists $epdata->{unknown};
  my $resourceId;
  $resourceId = $desc->getAttribute("resourceId");

  # we only parse if we have a resourceId: creators have them
  if ($resourceId) {
    $epdata->{unknown}->{$resourceId} = {};
    foreach my $stat ( $desc->getElementsByTagName("statement") ) {
      my ( $field, $value ) = _parse_statement($stat);

      for ($field) {
        m#givenname# && do {
          $epdata->{'pages'} = $value;
          last;
        };

        #familyname
        #institution
        #email
      }
    } ## end foreach my $stat ( $desc->getElementsByTagName...)
  }
} ## end if($att =~ /^sword-mets-/)...

sub _parse_statement {
  my ($stat) = @_;

  my $property = $stat->getAttribute("propertyURI");

  unless ( defined $property ) {
    $property = $stat->getAttribute("epdcx:propertyURI");
  }

  for ($property) {
    m#http://purl.org/dc/elements/1.1/type# && do {
      return _get_type($stat);
      last;
    };    ## end if ($property eq 'http://purl.org/dc/elements/1.1/type'...)

    m#http://purl.org/dc/elements/1.1/title# && do {
      my $value = ( $stat->getElementsByTagName("valueString") )[0];
      my $title
          = EPrints::XML::to_string( EPrints::XML::contents_of($value) );
      return ( "title", clean_text($title) );
      last;
    };  ## end elsif ($property eq 'http://purl.org/dc/elements/1.1/title'...)

    m#http://purl.org/dc/terms/abstract# && do {
      my $value = ( $stat->getElementsByTagName("valueString") )[0];
      my $abstract
          = EPrints::XML::to_string( EPrints::XML::contents_of($value) );
      return ( "abstract", clean_text($abstract) );
      last;
    };    ## end elsif ($property eq 'http://purl.org/dc/terms/abstract'...)

    m#http://purl.org/dc/elements/1.1/creator# && do {

      my $value = ( $stat->getElementsByTagName("valueString") )[0];
      $value .= "\t"
          . $stat->getAttribute("epdcx:valueRef")
          ;    # add the value of the attribute to the creators list

      return ( "creator", $value );
      last;
    }; ## end elsif ($property eq 'http://purl.org/dc/elements/1.1/creator'...)

    m#http://purl.org/dc/elements/1.1/identifier# && do {
      my $value = ( $stat->getElementsByTagName("valueString") )[0];
      my $id = EPrints::XML::to_string( EPrints::XML::contents_of($value) );
      return ( "id_number", clean_text($id) );
      last;
    }; ## end elsif ($property eq 'http://purl.org/dc/elements/1.1/identifier'...)

    m#http://purl.org/eprint/terms/status# && do {
      if ( $stat->getAttribute("valueURI") =~ /status\/(.*)$/ ) {
        my $status = $1;
        if ( $status eq 'PeerReviewed' ) {
          $status = 'TRUE';
        }
        elsif ( $status eq 'NonPeerReviewed' ) {
          $status = 'FALSE';
        }
        else {
          return;
        }

        return ( 'refereed', $status );    # is this the proper field?

      } ## end if ( $stat->getAttribute...)

      return;
      last;
    };    ## end elsif ($property eq 'http://purl.org/eprint/terms/status'...)

    m#http://purl.org/dc/elements/1.1/language# && do {

      # LANGUAGE (not parsed)
      last;
    };

    m#http://purl.org/dc/terms/available# && do {
      my $value = ( $stat->getElementsByTagName("valueString") )[0];
      my $id = EPrints::XML::to_string( EPrints::XML::contents_of($value) );
      return ( "date", clean_text($id) );
      last;
    };

    m#http://purl.org/eprint/terms/copyrightHolder# && do {

      # COPYRIGHT HOLDER (not parsed)
      last;
    };

    m#http://purl.org/dc/terms/bibliographicCitation# && do {
      my $value = ( $stat->getElementsByTagName("valueString") )[0];
      my $cite = EPrints::XML::to_string( EPrints::XML::contents_of($value) );
      return ( 'cite', $cite );
      last;
    };

    m#http://purl.org/dc/elements/1.1/publisher# && do {
      my $value = ( $stat->getElementsByTagName("valueString") )[0];
      $value = EPrints::XML::to_string( EPrints::XML::contents_of($value) );
      return ( 'publisher', $value );
      last;
    };

    # This lot are OA-RJ extensions to cover blantently missing fields
    m#http://opendepot.org/broker/elements/1.0/publication# && do {
      my $value = ( $stat->getElementsByTagName("valueString") )[0];
      $value = EPrints::XML::to_string( EPrints::XML::contents_of($value) );
      return ( 'publication', $value );
      last;
    };

    m#http://opendepot.org/broker/elements/1.0/issn# && do {
      my $value = ( $stat->getElementsByTagName("valueString") )[0];
      $value = EPrints::XML::to_string( EPrints::XML::contents_of($value) );
      return ( 'issn', $value );
      last;
    };

    m#http://opendepot.org/broker/elements/1.0/isbn# && do {
      my $value = ( $stat->getElementsByTagName("valueString") )[0];
      $value = EPrints::XML::to_string( EPrints::XML::contents_of($value) );
      return ( 'isbn', $value );
      last;
    };

    m#http://opendepot.org/broker/elements/1.0/volume# && do {
      my $value = ( $stat->getElementsByTagName("valueString") )[0];
      $value = EPrints::XML::to_string( EPrints::XML::contents_of($value) );
      return ( 'volume', $value );
      last;
    };

    m#http://opendepot.org/broker/elements/1.0/issue# && do {
      my $value = ( $stat->getElementsByTagName("valueString") )[0];
      $value = EPrints::XML::to_string( EPrints::XML::contents_of($value) );
      return ( 'issue', $value );
      last;
    };

    m#http://opendepot.org/broker/elements/1.0/pages# && do {
      my $value = ( $stat->getElementsByTagName("valueString") )[0];
      $value = EPrints::XML::to_string( EPrints::XML::contents_of($value) );
      return ( 'pagerange', $value ) if $value =~ /\-/;
      return ( 'pages', $value );
      last;
    };

## new record metadata
    m#http://purl.org/dc/elements/1.1/givenname# && do {
      my $value = ( $stat->getElementsByTagName("valueString") )[0];
      $value = EPrints::XML::to_string( EPrints::XML::contents_of($value) );
      return ( 'givenname', $value );
      last;
    };

    m#http://purl.org/dc/elements/1.1/familyname# && do {
      my $value = ( $stat->getElementsByTagName("valueString") )[0];
      $value = EPrints::XML::to_string( EPrints::XML::contents_of($value) );
      return ( 'familyname', $value );
      last;
    };

    m#http://xmlns.com/foaf/0.1/mbox# && do {
      my $value = ( $stat->getElementsByTagName("valueString") )[0];
      $value = EPrints::XML::to_string( EPrints::XML::contents_of($value) );
      return ( 'email', $value );
      last;
    };

    m#http://purl.org/eprint/terms/affiliatedInstitution# && do {
      my $value = ( $stat->getElementsByTagName("valueString") )[0];
      $value = EPrints::XML::to_string( EPrints::XML::contents_of($value) );
      return ( 'institution', $value );
      last;
    };

    m#http://www.loc.gov/loc.terms/relators/EDT# && do {
      my $value = ( $stat->getElementsByTagName("valueString") )[0];
      $value = EPrints::XML::to_string( EPrints::XML::contents_of($value) );
      return ( 'provenance', $value );    # editor?
      last;
    };

    m#http://www.loc.gov/loc.terms/relators/FND# && do {
      my $value = $stat->getAttribute("epdcx:valueRef")
          ;    # add the value of the attribute to the creators list
      return ( "funders", $value );

      last;
    };
    m#http://purl.org/eprint/terms/grantNumber# && do {
      my $value;

      if ($stat->hasAttribute("epdcx:valueRef")) {
        $value = $stat->getAttribute("epdcx:valueRef");
      } else {
        my @vs = $stat->getElementsByTagName("valueString");
        if (scalar @vs) {
          $value = $vs[0];
          $value = EPrints::XML::to_string( EPrints::XML::contents_of($value) );
        }
      }
      return ( "grant_code", $value );
      last;
    };

## end new data

## Alternate sources
    m#http://purl.org/eprint/terms/isAvailableAs# && do {
      my $value = $stat->getAttribute("epdcx:valueRef") ;
      return ( "available_url", $value );
      last;
    };

## Data for embargoes
    m#http://purl.org/dc/terms/accessRights# && do {
      my $value = $stat->getAttribute("epdcx:valueRef")
          ;    # add the value of the attribute to the creators list
      $value =~ /([^\/]+)$/;
      $value = $1 if $1;
      return ( "access", $value );

      last;
    };
  } ## end for ($property)
  return;

} ## end sub _parse_statement

sub _get_type {
  my ($stat) = @_;

  if ( $stat->getAttribute("valueURI") =~ /type\/(.*)$/ ) {   # then $1 = type

# reference for these mappings is:
# "http://www.ukoln.ac.uk/repositories/digirep/index/Eprints_Type_Vocabulary_Encoding_Scheme"

    my $type = $1;    # no need to clean_text( $1 ) here

    if ( $type eq 'JournalArticle'
      || $type eq 'JournalItem'
      || $type eq 'SubmittedJournalArticle'
      || $type eq 'WorkingPaper' )
    {
      $type = 'article';
    } ## end if ( $type eq 'JournalArticle'...)
    elsif ( $type eq 'Book' ) {
      $type = 'book';
    }
    elsif ( $type eq 'BookItem' ) {
      $type = 'book_section';
    }
    elsif ( $type eq 'ConferenceItem'
      || $type eq 'ConferencePoster'
      || $type eq 'ConferencePaper' )
    {
      $type = 'conference_item';
    } ## end elsif ( $type eq 'ConferenceItem'...)
    elsif ( $type eq 'Patent' ) {
      $type = 'patent';
    }
    elsif ( $type eq 'Report' ) {
      $type = 'monograph';    # I think?
    }
    elsif ( $type eq 'Thesis' ) {
      $type = 'thesis';
    }
    else {
      return
          ; # problem there! But the user can still correct this piece of data...
    }

    return ( "type", $type );
  } ## end if ( $stat->getAttribute...)
  return;
} ## end sub _get_type

sub clean_text {
  my ($text) = @_;

  my @lines = split( "\n", $text );

  foreach (@lines) {
    $_ =~ s/\s+$//;

    $_ =~ s/^\s+//;
  }

  return join( " ", @lines );
} ## end sub clean_text

################
#
# We need to replace the default routine so we can apply
# an embargo to the deposited file.
sub attach_deposited_file {
  my ( $self, $eprint, $file, $mime, $embargo, $security ) = @_;
  my $fn = $file;
  if ( $file =~ /^.*\/(.*)$/ ) {
    $fn = $1;
  }

  my %doc_data;
  $doc_data{eprintid} = $eprint->get_id;
  $doc_data{format}   = $mime;
  $doc_data{formatdesc}
      = $self->{session}->phrase("Sword/Deposit:document_formatdesc");
  $doc_data{main} = $fn;
  if ( $embargo && $security ) {
    $doc_data{date_embargo} = $embargo;
    $doc_data{security}     = $security;
  }

  local $self->{session}->get_repository->{config}->{enable_file_imports} = 1;

  my %file_data;
  $file_data{filename} = $fn;
  $file_data{url}      = "file://$file";

  $doc_data{files} = [ \%file_data ];

  $doc_data{_parent} = $eprint;

  my $doc_dataset = $self->{session}->get_repository->get_dataset("document");

  my $document
      = EPrints::DataObj::Document->create_from_data( $self->{session},
    \%doc_data, $doc_dataset );

  return 0 unless ( defined $document );

  $document->make_thumbnails;
  $eprint->generate_static;
  $self->set_deposited_file_docid( $document->get_id );

  return 1;

}

sub parse_rights_data {
  my ( $plugin, $xml ) = @_;

  my $set = ( $xml->getElementsByTagName("descriptionSet") )[0];

  unless ( defined $set ) {
    $plugin->set_status_code(400);
    $plugin->add_verbose("ERROR: no <descriptionSet> tag found.");
    return;
  }

  my $data = {};

  foreach my $desc ( $set->getElementsByTagName("description") ) {

    # This is the ID that ties the description to the structMap record
    my $att = $desc->getAttribute("epdcx:resourceId");

    foreach my $stat ( $desc->getElementsByTagName("statement") ) {
      my ( $field, $value ) = _parse_statement($stat);
      $data->{$att} = {} unless exists $data->{$att};
      $data->{$att}->{$field} = $value;
    }
  }

  return $data;
}

1;

