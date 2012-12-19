#!/usr/bin/perl

#
# getDiskStats - Gather disk stats for monitored hosts via SNMP -ryanfrantz 
#

use warnings;
use strict;

use Net::SNMP;
use RRDs;
use File::Basename;

#
# variables...
#

my $community = 'xxx';
my $time = time;
my $date = localtime( $time );
$date =~ s|:|\\:|g; # sterilize the date for inclusion in the graphs' COMMENT directive later
my $rrdDir = '/usr/local/rrd';
my $diskRRDLog = $rrdDir . '/diskRRDStatus.log';
my $pngDest = '/usr/local/apache2/htdocs/ts/snmpStats';

# %diskInstances contains the instance portion of the disk OID that we want to capture
my %diskInstances = (
	'foo'		=>	[ '2.67.58', '2.68.58', '2.70.58', '2.71.58' ],	
	'bar'		=>	[ '2.67.58', '2.68.58', '2.70.58', '2.71.58' ],
	'baz'		=>	[ '2.67.58', '2.68.58', '2.70.58', '2.71.58' ],
);

# build an AoA to aid in graphing later
# [ periodName, period, step ],
# periodName  -> used in graph name
# period      -> used to determine the data window (i.e. "end-$period)
# step        -> specifies the relevant step (re: CDP) expected in the RRA
my @period2step = (
	[ '30-min', '30m', '300' ],	# 30-min window, 5-min intervals
	[ '2-hour', '2h', '300' ],	# 2-hour window, 5-min intervals
	[ '8-hour', '8h', '300' ],	# 8-hour window, 5-min intervals
	[ '24-hour', '86399', '300' ],	# 24-hour window, 5-min intervals
	[ '7-day', '7d', '1800' ],	# 7-day window, 30-min intervals
	[ '30-day', '30d', '7200' ],	# 30-day window, 2-hour intervals
	[ '365-day', '365d', '365' ],	# 1-year window, 1-day intervals
);

# build up my OID leaves...
my $logicalDiskEntry = '1.3.6.1.4.1.9600.1.1.1.1';	# top o' the branch
my $diskName = $logicalDiskEntry . '.1';
my $pctDiskReadTimeOID = $logicalDiskEntry . '.2';
my $pctDiskTotalTimeOID = $logicalDiskEntry . '.3';
my $pctDiskWriteTimeOID = $logicalDiskEntry . '.4';
my $pctDiskFreeSpaceOID = $logicalDiskEntry . '.5';
my $avgSecPerReadOID = $logicalDiskEntry . '.10';
my $avgSecPerXferOID = $logicalDiskEntry . '.11';
my $avgSecPerWriteOID = $logicalDiskEntry . '.12';
my $currentQueueLengthOID = $logicalDiskEntry . '.13';
my $bytesTotalPerSecOID = $logicalDiskEntry . '.14';
my $bytesReadPerSecOID = $logicalDiskEntry . '.15';
my $opsReadPerSecOID = $logicalDiskEntry . '.16';
my $opsTotalPerSecOID = $logicalDiskEntry . '.17';
my $bytesWritePerSecOID = $logicalDiskEntry . '.18';
my $opsWritePerSecOID = $logicalDiskEntry . '.19';
my $diskFreeMBOID = $logicalDiskEntry . '.20';

#
# subs
#

sub createSNMPSession {

	# we need a host to query and a community string
	my $host = shift;
	my $community = shift;

	if ( ! $community ) {
		print LOG localtime( $time ) . ": createSNMPSession(): Missing arguments!!\n";
		exit 1;
	}

	my ( $session, $error ) = Net::SNMP->session (
		-hostname  => $host,
		-community => $community,
	# 	-version   => 2,
	);

	if ( ! defined ( $session ) ) {
		print LOG localtime( $time ) . ":" .  $host. ":" . $error . "\n";
		exit 1;
	}

	return $session;

} # end createSNMPSession()

sub getRequest {

	# getRequest() queries the SNMP agent for a given host
	# Returns:
	#  $error, $diskValues
	# we need the session object, host, OIDs to get, and the RRD name for reference in logged errors
	my ( $session, $host, $getOIDs, $rrd ) = @_;
	my $error = undef;	# set to undef to be safe...

	my $result = $session->get_request (
		-varbindlist => $getOIDs	# $getOIDs is already an arrayref (passed in as an arg)
	);

	if ( ! defined ( $result ) ) {
		print LOG localtime( $time ) . ': ' . $host . ": ERROR($rrd): " . $session->error . "\n";
		#print localtime( $time ) . ': ' . $host . ": ERROR($rrd): " . $session->error . "\n";
		$error = 'No SNMP result';
		return $error;
	} else {

		# return an undef error and the gathered values...
		return $error, $result;

	}	# end 'if ( ! defined ( $result...'

}	# end getRequest()

sub getDiskStats {

	# expect a host and the $snmp session object ( from createSNMPSession() )...
	my ( $host, $session ) = @_;
	if ( ! $session ) {
		print LOG localtime( $time ) . ": getDiskStats(): Missing \$session object!\n\n";
		#print localtime( $time ) . ": getDiskStats(): Missing \$session object!\n\n";
		exit 1;
	}

	my $dest = $rrdDir . '/' . $host;

	my $updateErr;

	# for each disk instance for the given host...
	foreach my $instance ( @{ $diskInstances{ $host } } ) {
		#print "\nDisk Instance: " . $instance . "\n";
		my $diskPctTimeRRD = $dest . '/disk_' . $host . '_' . 'pctTime_' . $instance . '.rrd';
		my $diskPctFreeSpaceRRD = $dest . '/disk_' . $host . '_' . 'pctFreeSpace_' . $instance . '.rrd';
		my $diskAvgDiskSecRRD = $dest . '/disk_' . $host . '_' . 'avgDiskSec_' . $instance . '.rrd';
		my $diskCurrentQueueLengthRRD = $dest . '/disk_' . $host . '_' . 'currentQueueLength_' . $instance . '.rrd';
		my $diskBytesPerSecRRD = $dest . '/disk_' . $host . '_' . 'bytesPerSec_' . $instance . '.rrd';
		my $diskOpsPerSecRRD = $dest . '/disk_' . $host . '_' . 'opsPerSec_' . $instance . '.rrd';
		my $diskFreeMBRRD = $dest . '/disk_' . $host . '_' . 'freeMB_' . $instance . '.rrd';

		# bundle the OIDs according to their RRD (some are standalone) into a hash of arrays...
		my %baseOIDs = (
			$diskPctTimeRRD => [
				$pctDiskReadTimeOID,
				$pctDiskTotalTimeOID,
				$pctDiskWriteTimeOID,
			],

			$diskPctFreeSpaceRRD => [
				$pctDiskFreeSpaceOID,
			],

			$diskAvgDiskSecRRD => [
				$avgSecPerReadOID,
				$avgSecPerXferOID,
				$avgSecPerWriteOID,
			],

			$diskCurrentQueueLengthRRD => [
				$currentQueueLengthOID,
			],

			$diskBytesPerSecRRD => [
				$bytesTotalPerSecOID,
				$bytesReadPerSecOID,
				$bytesWritePerSecOID,
			],

			$diskOpsPerSecRRD => [
				$opsReadPerSecOID,
				$opsTotalPerSecOID,
				$opsWritePerSecOID,
			],

			$diskFreeMBRRD => [
				$diskFreeMBOID,
			],

		);	# end %baseOIDs

		# iterate over the RRDs, grab the appropriate OIDs to poll, and update data
		foreach my $rrd ( sort keys %baseOIDs ) {	# %baseOIDs is indexed by RRD name
			#print "  RRD: $rrd\n";

			# build the full OIDs using the base OID and the instance ID
			my @getOIDs;
			foreach my $oid ( @{ $baseOIDs{ $rrd } } ) {
				my $fullOID = $oid . '.' . $instance;
				#print "    OID: $fullOID\n"
				push @getOIDs, $fullOID;
			}

			# call getRequest() with our full OIDs; send the RRD name for reference in logged error messages
			#print "getRequest(): @getOIDs\n";
			my ( $requestError, $values );
			( $requestError, $values ) = getRequest( $session, $host, \@getOIDs, $rrd );

			my ( @updateData, $updateString );
			push @updateData, $time;	# add the time as the first item
			if ( ! $requestError ) {
				# we've got some data; update the RRD
				foreach my $oid ( sort keys %$values ) {
					#print "RESULT: $oid -> " . @$values{ $oid } . "\n";
					push @updateData, @$values{ $oid };	# push each value into the list
				}
			} else {	# there was some problem; values are unknown
				foreach ( @getOIDs ) {	# iterate over @getOIDs to figure out how many UNKNOWN values need to be populated
					push @updateData, 'U';
				}
			}
			$updateString = join( ':', @updateData );	# delimit all items with a colon
			#print "UPDATE: $rrd -> $updateString\n";
			RRDs::update( $rrd, $updateString );
			$updateErr = RRDs::error;
			print LOG localtime( $time ) . ": " . $host . ": UPDATE ERROR($rrd): $updateErr\n" if $updateErr;

		}	# end 'foreach my $rrd...'


	}	# end 'foreach my $instance...'

}  # end getDiskStats()

sub genGraph {

	# generate all graphs for all subsystems for all periods
	# expect $host, $session, $periodName, $period, $step
	# !! the $session object is required so that we can poll SNMP for info (i.e. speed) on the NIC(s)
	my ( $host, $session, $periodName, $period, $step ) = @_;

	my $start = "end-$period";      # create the window of time that we want to graph data using $period
	my $end = "now";

	foreach my $instance ( @{ $diskInstances{ $host } } ) {
		# build up variable names based on the sub's input
		# RRD locations #
		my $dest = $rrdDir . '/' . $host;
		my $diskPctTimeRRD = $dest . '/disk_' . $host . '_' . 'pctTime_' . $instance . '.rrd';
		my $diskPctFreeSpaceRRD = $dest . '/disk_' . $host . '_' . 'pctFreeSpace_' . $instance . '.rrd';
		my $diskAvgDiskSecRRD = $dest . '/disk_' . $host . '_' . 'avgDiskSec_' . $instance . '.rrd';
		my $diskCurrentQueueLengthRRD = $dest . '/disk_' . $host . '_' . 'currentQueueLength_' . $instance . '.rrd';
		my $diskBytesPerSecRRD = $dest . '/disk_' . $host . '_' . 'bytesPerSec_' . $instance . '.rrd';
		my $diskOpsPerSecRRD = $dest . '/disk_' . $host . '_' . 'opsPerSec_' . $instance . '.rrd';
		my $diskFreeMBRRD = $dest . '/disk_' . $host . '_' . 'freeMB_' . $instance . '.rrd';

		# graph locations #
		my $diskPctTimePNG= $pngDest . '/' . $host . '/disk_' . $host . '_' . 'pctTime_' . $instance . '_' . $periodName . '.png';
		my $diskPctFreeSpacePNG = $pngDest . '/' . $host . '/disk_' . $host . '_' . 'pctFreeSpace_' . $instance . '_' . $periodName . '.png';
		my $diskAvgDiskSecPNG = $pngDest . '/' . $host . '/disk_' . $host . '_' . 'avgDiskSec_' . $instance . '_' . $periodName . '.png';
		my $diskCurrentQueueLengthPNG = $pngDest . '/' . $host . '/disk_' . $host . '_' . 'currentQueueLength_' . $instance . '_' . $periodName . '.png';
		my $diskBytesPerSecPNG = $pngDest . '/' . $host . '/disk_' . $host . '_' . 'bytesPerSec_' . $instance . '_' . $periodName . '.png';
		my $diskOpsPerSecPNG = $pngDest . '/' . $host . '/disk_' . $host . '_' . 'opsPerSec_' . $instance . '_' . $periodName . '.png';
		my $diskFreeMBPNG = $pngDest . '/' . $host . '/disk_' . $host . '_' . 'freeMB_' . $instance . '_' . $periodName . '.png';

		# all informational OIDs
		my $driveLetter = $diskName . '.' . $instance;
		#print "driveLetter = " . $driveLetter . "\n";
		my @getOIDs = ( $driveLetter );

		# call getRequest() to get informational data to enhance the graph titles
		#my ( $requestError, $values ) = getRequest( $session, $host, \@getOIDs, $rrd );
		my ( $requestError, $values ) = getRequest( $session, $host, \@getOIDs );
		my $title;
		foreach my $oid ( sort keys %$values ) {
			#print "Drive Letter: " . @$values{ $oid } . "\n";
			if ( @$values{ $oid } eq "" ) {
				$title = "Drive N/A";
			} else {
				$title = "Drive @$values{ $oid }";
			}
		}
		#print "TITLE: $title\n";

		# hash the graph arguments as arrayrefs
		my %rrd2Args = (

		$diskPctTimeRRD		=> [
			"$diskPctTimePNG",
			"--start=$start",
			"--end=$end",
			'--vertical-label=% Busy Time',
			"--title=$title",
			'--width=500',
			'--lower-limit=0',
			'--upper-limit=100',
			#'--height=150',
			'--color', 'SHADEA#ffffff',
			'--color', 'SHADEB#ffffff',
			#'--slope-mode',
			"DEF:pctDskReadTime=$diskPctTimeRRD:pctDskReadTime:AVERAGE:step=$step",
			"DEF:pctDskTotalTime=$diskPctTimeRRD:pctDskTotalTime:AVERAGE:step=$step",
			"DEF:pctDskWriteTime=$diskPctTimeRRD:pctDskWriteTime:AVERAGE:step=$step",
			'VDEF:minRead=pctDskReadTime,MINIMUM',
			'VDEF:minTotal=pctDskTotalTime,MINIMUM',
			'VDEF:minWrite=pctDskWriteTime,MINIMUM',
			'VDEF:maxRead=pctDskReadTime,MAXIMUM',
			'VDEF:maxTotal=pctDskTotalTime,MAXIMUM',
			'VDEF:maxWrite=pctDskWriteTime,MAXIMUM',
			'VDEF:lastRead=pctDskReadTime,LAST',
			'VDEF:lastTotal=pctDskTotalTime,LAST',
			'VDEF:lastWrite=pctDskWriteTime,LAST',
			"AREA:pctDskTotalTime#00FF00:Total",
			'GPRINT:lastTotal:  Current\: %.1lf %S%%',
			'GPRINT:minTotal:  Min\: %.1lf %S%%',
			'GPRINT:maxTotal:  Max\: %.1lf %S%%\n',
			"LINE2:pctDskReadTime#FF0000:Read",
			'GPRINT:lastRead:   Current\: %.1lf %S%%',
			'GPRINT:minRead:  Min\: %.1lf %S%%',
			'GPRINT:maxRead:  Max\: %.1lf %S%%\n',
			"LINE2:pctDskWriteTime#0000FF:Write",
			'GPRINT:lastWrite:  Current\: %.1lf %S%%',
			'GPRINT:minWrite:  Min\: %.1lf %S%%',
			'GPRINT:maxWrite:  Max\: %.1lf %S%%\n',
			'COMMENT:' . '[' . $date . ']\r',
		],	# end $diskPctTimeRRD

		$diskPctFreeSpaceRRD	=> [
			"$diskPctFreeSpacePNG",
			"--start=$start",
			"--end=$end",
			'--vertical-label=% Free Space',
			"--title=$title",
			'--width=500',
			'--lower-limit=0',
			'--upper-limit=100',
			#'--height=150',
			'--color', 'SHADEA#ffffff',
			'--color', 'SHADEB#ffffff',
			#'--slope-mode',
			"DEF:pctDskFreeSpace=$diskPctFreeSpaceRRD:pctDskFreeSpace:AVERAGE:step=$step",
			'VDEF:minFree=pctDskFreeSpace,MINIMUM',
			'VDEF:maxFree=pctDskFreeSpace,MAXIMUM',
			'VDEF:lastFree=pctDskFreeSpace,LAST',
			"AREA:pctDskFreeSpace#00FF00:Free",
			'GPRINT:lastFree:  Current\: %.1lf %S%%',
			'GPRINT:minFree:  Min\: %.1lf %S%%',
			'GPRINT:maxFree:  Max\: %.1lf %S%%\n',
			'COMMENT:' . '[' . $date . ']\r',
		],	# end $diskPctFreeSpaceRRD

		$diskAvgDiskSecRRD	=> [
			"$diskAvgDiskSecPNG",
			"--start=$start",
			"--end=$end",
			'--vertical-label=Avg Time/Ops',
			"--title=$title",
			'--width=500',
			'--lower-limit=0',
			#'--height=150',
			'--color', 'SHADEA#ffffff',
			'--color', 'SHADEB#ffffff',
			#'--slope-mode',
			"DEF:avgDskSecPerRead=$diskAvgDiskSecRRD:avgDskSecPerRead:AVERAGE:step=$step",
			"DEF:avgDskSecPerXfer=$diskAvgDiskSecRRD:avgDskSecPerXfer:AVERAGE:step=$step",
			"DEF:avgDskSecPerWrite=$diskAvgDiskSecRRD:avgDskSecPerWrite:AVERAGE:step=$step",
			'VDEF:minRead=avgDskSecPerRead,MINIMUM',
			'VDEF:minXfer=avgDskSecPerXfer,MINIMUM',
			'VDEF:minWrite=avgDskSecPerWrite,MINIMUM',
			'VDEF:maxRead=avgDskSecPerRead,MAXIMUM',
			'VDEF:maxXfer=avgDskSecPerXfer,MAXIMUM',
			'VDEF:maxWrite=avgDskSecPerWrite,MAXIMUM',
			'VDEF:lastRead=avgDskSecPerRead,LAST',
			'VDEF:lastXfer=avgDskSecPerXfer,LAST',
			'VDEF:lastWrite=avgDskSecPerWrite,LAST',
			"AREA:avgDskSecPerXfer#00FF00:Total",
			'GPRINT:lastXfer:  Current\: %.1lf %Ssec',
			'GPRINT:minXfer:  Min\: %.1lf %Ssec',
			'GPRINT:maxXfer:  Max\: %.1lf %Ssec\n',
			"LINE2:avgDskSecPerRead#FF0000:Read",
			'GPRINT:lastRead:   Current\: %.1lf %Ssec',
			'GPRINT:minRead:  Min\: %.1lf %Ssec',
			'GPRINT:maxRead:  Max\: %.1lf %Ssec\n',
			"LINE2:avgDskSecPerWrite#0000FF:Write",
			'GPRINT:lastWrite:  Current\: %.1lf %Ssec',
			'GPRINT:minWrite:  Min\: %.1lf %Ssec',
			'GPRINT:maxWrite:  Max\: %.1lf %Ssec\n',
			'COMMENT:' . '[' . $date . ']\r',
		],

		$diskCurrentQueueLengthRRD	=> [
			"$diskCurrentQueueLengthPNG",
			"--start=$start",
			"--end=$end",
			'--vertical-label=Queue Length',
			"--title=$title",
			'--width=500',
			'--lower-limit=0',
			#'--height=150',
			'--color', 'SHADEA#ffffff',
			'--color', 'SHADEB#ffffff',
			#'--slope-mode',
			"DEF:currentQueueLength=$diskCurrentQueueLengthRRD:currentQueueLength:AVERAGE:step=$step",
			'VDEF:minLength=currentQueueLength,MINIMUM',
			'VDEF:maxLength=currentQueueLength,MAXIMUM',
			'VDEF:lastLength=currentQueueLength,LAST',
			"LINE2:currentQueueLength#00FF00:Total",
			'GPRINT:lastLength:  Current\: %lf %S',
			'GPRINT:minLength:  Min\: %lf %S',
			'GPRINT:maxLength:  Max\: %lf %S\n',
			'COMMENT:' . '[' . $date . ']\r',
		],

		$diskBytesPerSecRRD	=> [
			"$diskBytesPerSecPNG",
			"--start=$start",
			"--end=$end",
			'--vertical-label=Throughput (Bps)',
			"--title=$title",
			'--width=500',
			'--lower-limit=0',
			#'--height=150',
			'--color', 'SHADEA#ffffff',
			'--color', 'SHADEB#ffffff',
			#'--slope-mode',
			"DEF:totalBytesPerSec=$diskBytesPerSecRRD:totalBytesPerSec:AVERAGE:step=$step",
			"DEF:readBytesPerSec=$diskBytesPerSecRRD:readBytesPerSec:AVERAGE:step=$step",
			"DEF:writeBytesPerSec=$diskBytesPerSecRRD:writeBytesPerSec:AVERAGE:step=$step",
			'VDEF:minRead=readBytesPerSec,MINIMUM',
			'VDEF:minTotal=totalBytesPerSec,MINIMUM',
			'VDEF:minWrite=writeBytesPerSec,MINIMUM',
			'VDEF:maxRead=readBytesPerSec,MAXIMUM',
			'VDEF:maxTotal=totalBytesPerSec,MAXIMUM',
			'VDEF:maxWrite=writeBytesPerSec,MAXIMUM',
			'VDEF:lastRead=readBytesPerSec,LAST',
			'VDEF:lastTotal=totalBytesPerSec,LAST',
			'VDEF:lastWrite=writeBytesPerSec,LAST',
			"AREA:totalBytesPerSec#00FF00:Total",
			'GPRINT:lastTotal:  Current\: %.1lf %SBps',
			'GPRINT:minTotal:  Min\: %.1lf %SBps',
			'GPRINT:maxTotal:  Max\: %.1lf %SBps\n',
			"LINE2:readBytesPerSec#FF0000:Read",
			'GPRINT:lastRead:   Current\: %.1lf %SBps',
			'GPRINT:minRead:  Min\: %.1lf %SBps',
			'GPRINT:maxRead:  Max\: %.1lf %SBps\n',
			"LINE2:writeBytesPerSec#0000FF:Write",
			'GPRINT:lastWrite:  Current\: %.1lf %SBps',
			'GPRINT:minWrite:  Min\: %.1lf %SBps',
			'GPRINT:maxWrite:  Max\: %.1lf %SBps\n',
			'COMMENT:' . '[' . $date . ']\r',
		],

		$diskOpsPerSecRRD	=> [
			"$diskOpsPerSecPNG",
			"--start=$start",
			"--end=$end",
			'--vertical-label=Ops/sec',
			"--title=$title",
			'--width=500',
			'--lower-limit=0',
			#'--height=150',
			'--color', 'SHADEA#ffffff',
			'--color', 'SHADEB#ffffff',
			#'--slope-mode',
			"DEF:totalOpsPerSec=$diskOpsPerSecRRD:totalOpsPerSec:AVERAGE:step=$step",
			"DEF:readOpsPerSec=$diskOpsPerSecRRD:readOpsPerSec:AVERAGE:step=$step",
			"DEF:writeOpsPerSec=$diskOpsPerSecRRD:writeOpsPerSec:AVERAGE:step=$step",
			'VDEF:minRead=readOpsPerSec,MINIMUM',
			'VDEF:minTotal=totalOpsPerSec,MINIMUM',
			'VDEF:minWrite=writeOpsPerSec,MINIMUM',
			'VDEF:maxRead=readOpsPerSec,MAXIMUM',
			'VDEF:maxTotal=totalOpsPerSec,MAXIMUM',
			'VDEF:maxWrite=writeOpsPerSec,MAXIMUM',
			'VDEF:lastRead=readOpsPerSec,LAST',
			'VDEF:lastTotal=totalOpsPerSec,LAST',
			'VDEF:lastWrite=writeOpsPerSec,LAST',
			"AREA:totalOpsPerSec#00FF00:Total",
			'GPRINT:lastTotal:  Current\: %.1lf %S',
			'GPRINT:minTotal:  Min\: %.1lf %S',
			'GPRINT:maxTotal:  Max\: %.1lf %S\n',
			"LINE2:readOpsPerSec#FF0000:Read",
			'GPRINT:lastRead:   Current\: %.1lf %S',
			'GPRINT:minRead:  Min\: %.1lf %S',
			'GPRINT:maxRead:  Max\: %.1lf %S\n',
			"LINE2:writeOpsPerSec#0000FF:Write",
			'GPRINT:lastWrite:  Current\: %.1lf %S',
			'GPRINT:minWrite:  Min\: %.1lf %S',
			'GPRINT:maxWrite:  Max\: %.1lf %S\n',
			'COMMENT:' . '[' . $date . ']\r',
		],

		$diskFreeMBRRD	=> [
			"$diskFreeMBPNG",
			"--start=$start",
			"--end=$end",
			'--vertical-label=Free Space',
			"--title=$title",
			'--width=500',
			'--lower-limit=0',
			#'--height=150',
			'--color', 'SHADEA#ffffff',
			'--color', 'SHADEB#ffffff',
			#'--slope-mode',
			"DEF:diskFreeMB=$diskFreeMBRRD:diskFreeMB:AVERAGE:step=$step",
			"CDEF:diskFreeGB=diskFreeMB,1024,/",
			'VDEF:minFree=diskFreeGB,MINIMUM',
			'VDEF:maxFree=diskFreeGB,MAXIMUM',
			'VDEF:lastFree=diskFreeGB,LAST',
			"AREA:diskFreeMB#00FF00:Free",
			'GPRINT:lastFree:  Current\: %.1lf GB',
			'GPRINT:minFree:  Min\: %.1lf GB',
			'GPRINT:maxFree:  Max\: %.1lf GB\n',
			'COMMENT:' . '[' . $date . ']\r',
		],

		);	# end %rrd2Args

		### graph 'em!
		## if the destination directory does not exist, create it; use $diskPctTimePNG to get the dirname
		my $graphDir = dirname( $diskPctTimePNG );
		if ( ! -d $graphDir ) {
			print LOG localtime( $time ) . " MISSING DIR( $graphDir ) -> creating...\n";
			mkdir $graphDir or warn "Unable to create \'$graphDir\': $!\n";
		}
		
		foreach my $rrd ( sort keys %rrd2Args ) {
			#print "RRD: $rrd\n";
			my @graphArgs = @{ $rrd2Args{ $rrd } };
			RRDs::graph( @graphArgs );
			my $error = RRDs::error;
			print LOG localtime( $time ) . " GRAPH ERROR( " . $rrd . " ): $error\n" if $error;
			print localtime( $time ) . " GRAPH ERROR( " . $rrd .  " ): $error\n" if $error;
		}

	}	# end 'foreach my $instance...'

}	# end genGraph()

#
# start me up!
#

open( LOG, ">>$diskRRDLog" ) or warn "Unable to open \'$diskRRDLog\' for writing: $!\n";

# run through each server, gather stats, then graph 'em!
foreach my $host ( sort keys %diskInstances ) {
#  print "\n--+ " . uc( $host ) . " +--\n";

  # create an SNMP session object
  my $snmp = createSNMPSession( $host, $community );
  # pass the object to getDiskStats()
  getDiskStats( $host, $snmp );

  # generate the graphs using info from @period2step
  foreach my $ref ( @period2step ) {
    #my $periodName = @$ref[0];
    #my $period = @$ref[1];
    #my $step = @$ref[2];
    my ( $periodName, $period, $step)  = @$ref;
    genGraph( $host, $snmp, $periodName, $period, $step );
  }

	# since we need to pass the session object to genGraph() so that it can query SNMP for info on the NICs; destroy the
	# object _after_ the call to genGraph()
  $snmp->close;

} # end 'foreach my $host...'

close LOG;

