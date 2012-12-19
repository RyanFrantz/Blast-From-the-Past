#!/usr/bin/perl

use warnings;
use strict;
use MIME::Parser;

my $parser = new MIME::Parser;

my $tmpDir = '/tmp';
$parser->output_under( $tmpDir );

die "\nNo arguments!\n\n" unless @ARGV;

print "\nStarting parse...\n\n";

foreach my $file ( @ARGV ) {
	if ( -f $file ) {
		print "Parsing $file ...\n";
		my $entity = $parser->parse_open( $file );
	}
}

print "\nParsing complete.  Check $tmpDir for parsed files.\n\n";
