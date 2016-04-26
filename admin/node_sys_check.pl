#!/usr/bin/perl
#
## $Id: export_nodes.pl,v 1.1 2012/08/13 05:09:17 keiths Exp $
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#
#  This file is part of Network Management Information System ("NMIS").
#
#  NMIS is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  NMIS is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with NMIS (most likely in a file named LICENSE).
#  If not, see <http://www.gnu.org/licenses/>
#
#  For further information on NMIS or for a license other than GPL please see
#  www.opmantek.com or email contact@opmantek.com
#
#  User group details:
#  http://support.opmantek.com/users/
#
# *****************************************************************************

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use func;
use NMIS;
use Sys;
use NMIS::Timing;
use Data::Dumper;

if ( $ARGV[0] eq "" ) {
	usage();
	exit 1;
}

my $t = NMIS::Timing->new();

print $t->elapTime(). " Begin\n";

# Variables for command line munging
my %arg = getArguements(@ARGV);

my $C = loadConfTable();

if ( not defined $arg{node} ) {
	print "ERROR: need a node to check\n";
	usage();
	exit 1;
}

my $node = $arg{node};

# Set debugging level.
my $debug = setDebug($arg{debug});

# load configuration table
my $C = loadConfTable(conf=>$arg{conf},debug=>$arg{debug});

# Step 5: For loading only the local nodes on a Master or a Slave
my $NODES = loadLocalNodeTable();

if ( $arg{node} eq "all" ) {
	print "Processing all nodes\n";
	checkNodes();
}
elsif ( $arg{node} ) {
	checkNode($node);
}
else {
	print "WHAT? node=$arg{node}\n";
}

print $t->elapTime(). " END\n";

sub checkNode {
	my $node = shift;
  if ( $NODES->{$node}{active} eq "true") {
		my $S = Sys::->new; # get system object
		$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
		my $NI = $S->ndinfo;
		my $V =  $S->view;
		my $MDL = $S->mdl;
				
		my $changes = 0;
		my @interfaceSections = qw(interface pkts pkts_hc);
		my @cpuSections = qw(hrsmpcpu);

		my @bgpSections = qw(bgpPeer);
		
		my %nodeevents = loadAllEvents(node => $node);
		
		# pattern for looking for events which exist.
		foreach my $eventkey (keys %nodeevents) {
			my $thisevent = $nodeevents{$eventkey};
			#print "eventDelete(node => $node, event => $thisevent->{event}, element => $thisevent->{element})\n";
			#print Dumper $thisevent;

			if ( $thisevent->{event} =~ /BGP/ ) {
				
							
			}
		}

		
		foreach my $indx (sort keys %{$NI->{graphtype}} ) {
			print "Processing $indx\n" if $debug;
			if ( ref($NI->{graphtype}{$indx}) eq "HASH" and keys %{$NI->{graphtype}{$indx}} ) {
				foreach my $section (@interfaceSections) {
					if ( defined $NI->{graphtype}{$indx}{$section} and defined $NI->{interface}{$indx} ) {
						# there should be an interface to check
						print "INFO: $node $indx for $section and found interface\n" if $debug;
					}
					elsif ( defined $NI->{graphtype}{$indx}{$section} and not defined $NI->{interface}{$indx} ) {
						print "FIXING: $node $indx has graphtype $section but no interface\n";
						delete $NI->{graphtype}{$indx}{$section};
						$changes = 1;
					}
					else {
						# there should be an interface to check
					}
					
					# does a model section exist?
					if ( defined $MDL->{interface}{rrd}{$section} ) {
						print "INFO: $node found interface/rrd/$section in the model\n" if $debug;							
					}
					elsif ( defined $NI->{graphtype}{$indx}{$section} and not defined $MDL->{interface}{rrd}{$section} ) {
						print "FIXING: $node NO interface/rrd/$section found in the model for $indx\n";
						delete $NI->{graphtype}{$indx}{$section};							
						$changes = 1;
					}
				}

				foreach my $section (@cpuSections) {
					if ( defined $NI->{graphtype}{$indx}{$section} and defined $NI->{device}{$indx} ) {
						# there should be an interface to check
						print "INFO: $node $indx for $section and found CPU device\n" if $debug;
					}
					elsif ( defined $NI->{graphtype}{$indx}{$section} and not defined $NI->{device}{$indx} ) {
						print "FIXING: $node $indx has graphtype $section but no CPU device\n";
						delete $NI->{graphtype}{$indx}{$section};
						$changes = 1;
					}
					else {
						# there should be an interface to check
					}
					
				}

				# fixing a modelling messup				
				#"NetFlowStats" : "netflowstats,frag,ip",
				if ( defined $NI->{graphtype}{NetFlowStats} and ( $NI->{graphtype}{NetFlowStats} eq "netflowstats,frag,ip" or $NI->{graphtype}{NetFlowStats} eq "netflowstats,ip,frag" ) ) {
					print "FIXING: $node NetFlowStats has graphtype set to \"netflowstats,frag,ip\"\n";
					$NI->{graphtype}{NetFlowStats} = "netflowstats";
					$changes = 1;
				}
					

   #"bgpPeer" : {
   #   "192.168.90.18" : {
   #      "bgpPeerRemoteAs" : 64512,
   #
   #"status" : {
   #   "BGP Peer Down--192.168.90.18" : {
   #      "status" : "ok",               
   #      "value" : "100",               
   #      "event" : "BGP Peer Down",     
   #
   #"graphtype" : {
   #   "10.216.8.33" : {
   #      "bgpPeer" : "bgpPeerStats,bgpPeer"
   #   },
      
				# clean up BGP Peers
				foreach my $section (@bgpSections) {
					if ( defined $NI->{graphtype}{$indx}{$section} and defined $NI->{$section}{$indx} ) {
						# there should be an interface to check
						print "INFO: $node $indx for $section and found $section\n" if $debug;
					}
					elsif ( defined $NI->{graphtype}{$indx}{$section} and not defined $NI->{$section}{$indx} ) {
						print "FIXING: $node $indx has graphtype $section but no bgpPeer\n";
						
						delete $NI->{graphtype}{$indx}{$section};
						
						#Now check for any events existing.
						my $event = "Alert: BGP Peer Down";
						my $element = $indx;
						my $event_exists = eventExist($node, $event, $element);

						if ( -f $event_exists ) {
							my $thisevent = eventLoad(node => $node, event => $event, element => $element);
							eventDelete(event => $thisevent);
						}

						$changes = 1;
					}
					else {
						# there should be an interface to check
					}
					
				}
			}
			
			
			if ( ref($NI->{graphtype}{$indx}) eq "HASH" and not keys %{$NI->{graphtype}{$indx}} ) {
				print "FIXING: $node $indx graphtype has no keys\n";
				delete $NI->{graphtype}{$indx};
				$changes = 1;
			}
			elsif ( defined($NI->{graphtype}{$indx}) and $NI->{graphtype}{$indx} ne "" ) {
				print "INFO: $indx is a SCALAR\n" if $debug;
			}
			else {
				print "FIXING: $node $indx is unknown?\n";
				print Dumper $NI->{graphtype}{$indx};

			}
		}
		
		if ( $changes ) {
	
			my ($file,undef) = getFileName(dir => "var", file => lc("$node-node"));
			if ( $file !~ /^var/ ) {
				$file = "var/$file";
			}
			my $dataFile = "$C->{'<nmis_base>'}/$file";
			my $backupFile = "$C->{'<nmis_base>'}/$file.backup";
			my $backupCount = 0;
			while ( -f $backupFile ) {
				++$backupCount;
				$backupFile = "$C->{'<nmis_base>'}/$file.backup.$backupCount";
			}
			print "BACKUP $dataFile to $backupFile\n";
			#print Dumper $NI->{graphtype};
			
			my $backup = backupFile(file => $dataFile, backup => $backupFile);
			if ( $backup ) {
				print "$dataFile backup'ed up to $backupFile\n" if $debug;
				$S->writeNodeInfo();
			}
			else {
				print "SKIPPING: $dataFile could not be backup'ed\n";
			}
			
			#
		}
		
		if ( $arg{model} eq "dump" ) {
			print Dumper $MDL;
		}

  }
}

sub checkNodes {
	foreach my $node (sort keys %{$NODES}) {
		checkNode($node);
	}	
}



sub usage {
	print <<EO_TEXT;
$0 will export nodes and ports from NMIS.
ERROR: need some files to work with
usage: $0 dir=<directory>
eg: $0 node=nodename|all debug=true|false

EO_TEXT
}



sub backupFile {
	my %arg = @_;
	my $buff;
	if ( not -f $arg{backup} ) {			
		if ( -r $arg{file} ) {
			open(IN,$arg{file}) or warn ("ERROR: problem with file $arg{file}; $!");
			open(OUT,">$arg{backup}") or warn ("ERROR: problem with file $arg{backup}; $!");
			binmode(IN);
			binmode(OUT);
			while (read(IN, $buff, 8 * 2**10)) {
			    print OUT $buff;
			}
			close(IN);
			close(OUT);
			return 1;
		} else {
			print STDERR "ERROR: backupFile file $arg{file} not readable.\n";
			return 0;
		}
	}
	else {
		print STDERR "ERROR: backup target $arg{backup} already exists.\n";
		return 0;
	}
}
