#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#
#  This file is part of Network Management Information System (“NMIS”).
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

# Node class, use for access/manipulation of single node
# every node must have a UUID, this object will not devine one for you

package NMISNG::Node;
use strict;

our $VERSION = "1.0.0";

use Module::Load 'none';
use Carp::Assert;
use Clone;    # for copying overrides out of the record
use Data::Dumper;

use NMISNG::DB;
use NMISNG::Inventory;
use Compat::NMIS;								# for cleanEvent

# create a new node object
# params:
#   uuid - required
#   nmisng - NMISNG object, required ( for model loading, config and log)
#   id or _id - optional db id
# note: you must call one of the accessors to update the object before it can be saved!
sub new
{
	my ( $class, %args ) = @_;

	return if ( !$args{nmisng} );    #"collection nmisng"
	return if ( !$args{uuid} );      #"uuid required"

	my $self = {
		_dirty  => {},
		_nmisng => $args{nmisng},
		_id     => $args{_id} // $args{id} // undef,
		uuid    => $args{uuid}
	};
	bless( $self, $class );

	# weaken the reference to nmisx to avoid circular reference problems
	# not sure if the check for isweak is required
	Scalar::Util::weaken $self->{_nmisng} if ( $self->{_nmisng} && !Scalar::Util::isweak( $self->{_nmisng} ) );

	return $self;
}

###########
# Private:
###########

# tell the object that it's been changed so if save is
# called something needs to be done
# each section is tracked for being dirty, if it's 1 it's dirty
sub _dirty
{
	my ( $self, $newvalue, $whatsdirty ) = @_;

	if ( defined($newvalue) )
	{
		$self->{_dirty}{$whatsdirty} = $newvalue;
	}

	my @keys = keys %{$self->{_dirty}};
	foreach my $key (@keys)
	{
		return 1 if ( $self->{_dirty}{$key} );
	}
	return 0;
}

###########
# Public:
###########

# bulk set records to be historic which match this node and are 
# not in the array of active_indices (or active_ids) provided
#
# also updates records which are in the active_indices/active_ids 
# list to not be historic
# please note: this cannot and does NOT extend the expire_at ttl for active records!
#
# args: active_indices (optional), arrayref of active indices,
#   which can work if and  only if the concept uses 'index'!
# active_ids (optional), arrayref of inventory ids (mongo oids or strings),
#   note that you can pass in either active_indices OR active_ids 
#   but not both
# concept (optional, if not given all inventory entries for node will be 
#   marked historic (useful for update force=1)
# 
# returns: hashref with number of records marked historic and nothistoric
sub bulk_update_inventory_historic
{
	my ($self,%args) = @_;
	my ($active_indices, $active_ids, $concept) = @args{'active_indices','active_ids','concept'};

	return "invalid input, active_indices must be an array!" 
			if ($active_indices && ref($active_indices) ne "ARRAY");
	return "invalid input, active_ids must be an array!" 
			if ($active_ids && ref($active_ids) ne "ARRAY");
	return "invalid input, cannot handle both active_ids and active_indices!"
		if ($active_ids and $active_indices);
	
	my $retval = {};
	
	# not a huge fan of hard coding these, not sure there is much of a better way 
	my $q = {
		'path.0'  => $self->cluster_id,
		'path.1'  => $self->uuid,
	};
	$q->{'path.2'} = $concept if( $concept );

	# get_query currently doesn't support $nin, only $in
	if ($active_ids)
	{
		$q->{'_id'} = { '$nin' => [ map { NMISNG::DB::make_oid($_) } (@$active_ids) ] };
	}
	else
	{
		$q->{'data.index'} = {'$nin' => $active_indices};
	}

	# mark historic where not in list
	my $result = NMISNG::DB::update(
		collection => $self->nmisng->inventory_collection,
		freeform => 1,
		multiple => 1,
		query => $q,
		record => { '$set' => { 'historic' => 1 } }
	);
	$retval->{marked_historic} = $result->{updated_records};
	$retval->{matched_historic} = $result->{matched_records};

	# if we have a list of active anythings, unset historic on them
	if( $active_indices  or $active_ids)
	{
		# invert the selection
		if ($active_ids)
		{
			# cheaper than rerunning the potential oid making
			$q->{_id}->{'$in'} = $q->{_id}->{'$nin'};
			delete $q->{_id}->{'$nin'};
		}
		else
		{
			$q->{'data.index'} = {'$in' => $active_indices};
		}
		$result = NMISNG::DB::update(
			collection => $self->nmisng->inventory_collection,
			freeform => 1,
			multiple => 1,
			query => $q,
			record => { '$set' => { 'historic' => 0 } }
		);
		$retval->{marked_nothistoric} = $result->{updated_records};
		$retval->{matched_nothistoric} = $result->{matched_records};
	}
	return $retval;
}

sub cluster_id
{
	my ($self) = @_;
	my $configuration = $self->configuration();
	return $configuration->{cluster_id};
}

# get/set the configuration for this node
# setting data means the configuration is dirty and will
#  be saved next time save is called, even if it is identical to what
#  is in the database
# getting will load the configuration if it's not already loaded and return a copy so
#   any changes made will not affect this object until they are put back (set) using this function
# params:
#  newvalue - if set will replace what is currently loaded for the config
#   and set the object to be dirty
# returns configuration hash
sub configuration
{
	my ( $self, $newvalue ) = @_;

	if ( defined($newvalue) )
	{
		$self->nmisng->log->warn("NMISNG::Node::configuration given new config with uuid that does not match")
			if ( $newvalue->{uuid} && $newvalue->{uuid} ne $self->uuid );

		# UUID cannot be changed
		$newvalue->{uuid} = $self->uuid;

		$self->{_configuration} = $newvalue;
		$self->_dirty( 1, 'configuration' );
	}

	# if there is no config try and load it
	if ( !defined( $self->{_configuration} ) )
	{
		$self->load_part( load_configuration => 1 );
	}

	return Clone::clone( $self->{_configuration} );
}

# remove this node from the db and clean up all leftovers: 
# node configuration, inventories, timed data,
# -node and -view files.
# args: keep_rrd (default false)
# returns (success, message) or (0, error) 
sub delete
{
	my ($self,%args) = @_;

	my $keeprrd = NMISNG::Util::getbool($args{keep_rrd});

	# not errors but message doesn't hurt
	return (1, "Node already deleted") if ($self->{_deleted});
	return (1, "Node has never been saved, nothing to delete") if ($self->is_new);

	$self->nmisng->log->debug("starting to delete node ".$self->name);

	# get all the inventory objects for this node
	# tell them to delete themselves (and the rrd files)

	# get everything, historic or not - make it instantiatable
	# concept type is unknown/dynamic, so have it ask nmisng
	my $result = $self->get_inventory_model(
		class_name => { 'concept' => \&NMISNG::Inventory::get_inventory_class } );
	return (0, "Failed to retrieve inventories: $result->{error}")
			if (!$result->{success});
	
	my $gimme = $result->{model_data}->objects;
	return (0, "Failed to instantiate inventory: $gimme->{error}")
			if (!$gimme->{success});
	for my $invinstance (@{$gimme->{objects}})
	{
		$self->nmisng->log->debug("deleting inventory instance "
															.$invinstance->id
															.", concept ".$invinstance->concept
															.", description \"".$invinstance->description.'"');
		my ($ok, $error) = $invinstance->delete(keep_rrd => $keeprrd);
		return (0, "Failed to delete inventory ".$invinstance->id.": $error")
				if (!$ok);
	}

	# node and view files, if present - failure is not error-worthy
	for my $goner (map { $self->nmisng->config->{'<nmis_var>'}
											 .lc($self->name)."-$_.json" } ('node','view'))
	{
		next if (!-f $goner);
		$self->nmisng->log->debug("deleting file $goner");
		unlink($goner) if (-f $goner);
	}

	# delete any open events, failure undetectable *sigh* and not error-worthy
	Compat::NMIS::cleanEvent($self->name, "NMISNG::Node"); # fixme9: we don't have any useful caller

 	# finally delete the node record itself
	$result = NMISNG::DB::remove(
		collection => $self->nmisng->nodes_collection,
		query      => NMISNG::DB::get_query( and_part => { _id => $self->{_id} } ),
		just_one   => 1 );
	return (0, "Node config removal failed: $result->{error}") if (!$result->{success});

	$self->nmisng->log->debug("deletion of node ".$self->name." complete");
	$self->{_deleted} = 1;
	return (1,undef);
}

# get a list of id's for inventory related to this node,
# useful for iterating through all inventory
# filters/arguments:
#  cluster_id,node_uuid,concept
# returns: array ref (may be empty)
sub get_inventory_ids
{
	my ( $self, %args ) = @_;

	# what happens when an error happens here?
	$args{fields_hash} = {'_id' => 1};

	my $result = $self->get_inventory_model(%args);
	# fixme: add better error handling
	if ($result->{success} && $result->{model_data}->count)
	{
		return [ map { $_->{_id}->{value} } (@{$result->{model_data}->data()}) ];
	}
	else
	{
		return [];
	}
}

# wrapper around the global inventory model accessor
# which adds in the  current node's uuid and cluster id
# returns: hash ref with success, error, model_data
sub get_inventory_model
{
	my ( $self, %args ) = @_;
	$args{cluster_id} = $self->cluster_id;
	$args{node_uuid}  = $self->uuid();

	my $result = $self->nmisng->get_inventory_model(%args);
	return $result;
}

# find all unique values for key from collection and filter provided
# makes sure unique values are for this node
sub get_distinct_values
{
	my ($self, %args) = @_;	
	my $collection = $args{collection};
	my $key = $args{key};
	my $filter = $args{filter};

	$filter->{cluster_id} = $self->cluster_id;
	$filter->{node_uuid} = $self->uuid;

	return $self->nmisng->get_distinct_values( collection => $collection, key => $key, filter => $filter );
}

# find or create inventory object based on arguments
# object returned will have base class NMISNG::Inventory but will be a
# subclass of it specific to its concept; if no specific implementation is found
# the DefaultInventory class will be used/returned.
# if searching by path then it needs to be passed in, caller will know what type of
# inventory class they want so they can call the appropriate make_path function
# args: 
#    any args that can be used for finding an inventory model, 
#  if none is found then:
#    concept, data, path path_keys, create - 0/1 
#    (possibly not path_keys but whatever path info is needed for that specific inventory type)
# returns: (inventory object, undef) or (undef, error message)
sub inventory
{
	my ( $self, %args ) = @_;

	my $create = $args{create};
	delete $args{create};
	my ( $inventory, $class ) = ( undef, undef );

	# force these arguments to be for this node
	my $data = $args{data};
	$args{cluster_id} = $self->cluster_id();
	$args{node_uuid}  = $self->uuid();

	# fix the search to this node
	my $path = $args{path} // [];

	# it sucks hard coding this to 1, please find a better way
	$path->[1] = $self->uuid;

	# tell get_inventory_model enough to instantiate object later
	my $result = $self->nmisng->get_inventory_model(
		class_name => { "concept" => \&NMISNG::Inventory::get_inventory_class },
		%args);
	return (undef, "failed to get inventory: $result->{error}")
			if (!$result->{success} && !$create);
	
	my $model_data = $result->{model_data};
	if ( $model_data->count() > 0 )
	{
		$self->nmisng->log->warn("Inventory search returned more than one value, using the first!".Dumper(\%args))
				if($model_data->count() > 1);

		# instantiate as object, please
		(my $error, $inventory) = $model_data->object(0);
		return (undef, "instantiation failed: $error") if ($error);
	}
	elsif ($create)
	{
		# concept must be supplied, for now, "leftovers" may end up being a concept,		
		$class = NMISNG::Inventory::get_inventory_class( $args{concept} );
		$self->nmisng->log->debug("Creating Inventory for concept: $args{concept}, class:$class");
		$self->nmisng->log->error("Creating Inventory without concept") if ( !$args{concept} );

		$args{nmisng} = $self->nmisng;
		Module::Load::load $class;
		$inventory = $class->new(%args);
	}

	return ( $inventory, undef );
}

# get all subconcepts and any dataset found within that subconcept
# returns hash keyed by subconcept which holds hashes { subconcept => $subconcept, datasets => [...], indexed => 0/1 }
# args: - filter, basically any filter that can be put on an inventory can be used
#  enough rope to hang yourself here.  special case arg: subconcepts gets mapped into datasets.subconcepts
sub inventory_datasets_by_subconcept
{
	my ( $self, %args ) = @_;
	my $filter = $args{filter};
	$args{cluster_id} = $self->cluster_id();
	$args{node_uuid}  = $self->uuid();

	if( $filter->{subconcepts} )
	{
		$filter->{'dataset_info.subconcept'} = $filter->{subconcepts};
		delete $filter->{subconcepts};
	}
	
	my $q = $self->nmisng->get_inventory_model_query( %args );
	my $retval = {};

	# print "q".Dumper($q);
	# query parts that don't look at $datasets could run first if we need optimisation
	my @prepipeline = (
		{ '$unwind' => '$dataset_info' },
		{ '$match' => $q },
		{ '$unwind' => '$dataset_info.datasets' },
		{ '$group' => 
			{ '_id' => { "subconcept" => '$dataset_info.subconcept'},  # group by subconcepts
			'datasets' => { '$addToSet' => '$dataset_info.datasets'}, # accumulate all unique datasets
			'indexed' => { '$max' => '$data.index' }, # if this != null then it's indexed
			# rarely this is needed, if so it shoudl be consistent across all models
			# cbqos so far the only place
			'concept' => { '$first' => '$concept' } 
		}}
  );
  my ($entries,$count,$error) = NMISNG::DB::aggregate(
		collection => $self->nmisng->inventory_collection,
		pre_count_pipeline => \@prepipeline, #use either pipe, doesn't matter
		allowtempfiles => 1
	);
	foreach my $entry (@$entries)
	{	
		$entry->{indexed} = ( $entry->{indexed} ) ? 1 : 0;	
		$entry->{subconcept} = $entry->{_id}{subconcept};
		delete $entry->{_id};
		$retval->{ $entry->{subconcept} } = $entry;

	}
	return ($error) ? $error : $retval;
}

# sub inventory_indices_by_subconcept
# {

# }

# create the correct path for an inventory item, calling the make_path
# method on the class that relates to the specified concept
# args must contain concept and data, along with any other info required
# to make that path (probably path_keys)
sub inventory_path
{
	my ( $self, %args ) = @_;

	my $concept = $args{concept};
	my $data    = $args{data};
	$args{cluster_id} = $self->cluster_id();
	$args{node_uuid}  = $self->uuid();

	# ask the correct class to make the inventory
	my $class = NMISNG::Inventory::get_inventory_class($concept);

	Module::Load::load $class;
	my $path = $class->make_path(%args);
	return $path;
}

# returns 0/1 if the object is new or not.
# new means it is not yet in the database
sub is_new
{
	my ($self) = @_;

	my $configuration = $self->configuration();

	# print "id".Dumper($configuration);
	my $has_id = ( defined($configuration) && defined( $configuration->{_id} ) );
	return ($has_id) ? 0 : 1;
}

# load data for this node from the database, named load_part because the module Module::Load has load which clashes
# and i don't know how else to resolve the issue
# params:
#  options - hash, if not set or present all data for the node is loaded
#    load_overrides => 1 will load overrides
#    load_configuration => 1 will load overrides
# no return value
sub load_part
{
	my ( $self, %options ) = @_;
	my @options_keys = keys %options;
	my $no_options   = ( @options_keys == 0 );

	my $query = NMISNG::DB::get_query( and_part => {uuid => $self->uuid} );
	my $cursor = NMISNG::DB::find(
		collection => $self->nmisng->nodes_collection(),
		query      => $query
	);
	my $entry = $cursor->next;
	if ($entry)
	{

		if ( $no_options || $options{load_overrides} )
		{
			# return an empty hash if it's not defined
			$entry->{overrides} //= {};
			$self->{_overrides} = Clone::clone( $entry->{overrides} );
			$self->_dirty( 0, 'overrides' );
		}
		delete $entry->{overrides};

		if ( $no_options || $options{load_configuration} )
		{
			# everything else is the configuration
			$self->{_configuration} = $entry;
			$self->_dirty( 0, 'configuration' );
		}
	}
}

sub name
{
	my ($self) = @_;
	return $self->configuration()->{name};
}

# get/set the overrides for this node
# setting data means the overrides is dirty and will
#  be saved next time save is called, even if it is identical to what
#  is in the database
# getting will load the overrides if it's not already loaded
# params:
#  newvalue - if set will replace what is currently loaded for the overrides
#   and set the object to be dirty
# returns overrides hash
sub overrides
{
	my ( $self, $newvalue ) = @_;
	if ( defined($newvalue) )
	{
		$self->{_overrides} = $newvalue;
		$self->_dirty( 1, 'overrides' );
	}

	# if there is no config try and load it
	if ( !defined( $self->{_overrides} ) )
	{
		if ( !$self->is_new && $self->uuid )
		{
			$self->load_part( load_overrides => 1 );
		}
	}

	# loading will set this to an empty hash if it's not defined
	return $self->{_overrides};
}

# Save object to DB if it is dirty
# returns tuple, ($sucess,$error_message), 
# 0 if no saving required
#-1 if node is not valid, 
# >0 if all good
#
# TODO: error checking just uses assert right now, we may want
#   a differnent way of doing this
sub save
{
	my ($self) = @_;

	return ( -1, "node is incomplete, not saveable yet" )
			if ($self->is_new && !$self->_dirty);
	return ( 0,  undef )          if ( !$self->_dirty() );

	my ( $valid, $validation_error ) = $self->validate();
	return ( $valid, $validation_error ) if ( $valid <= 0 );

	my $result;
	my $op;

	my $entry = $self->configuration();
	$entry->{overrides} = $self->overrides();

	# make 100% certain we've got the uuid correct
	$entry->{uuid} = $self->uuid;
	
	# need the time it was last saved
	$entry->{lastupdate} = time;

	if ( $self->is_new() )
	{
		# could maybe be upsert?
		$result = NMISNG::DB::insert(
			collection => $self->nmisng->nodes_collection(),
			record     => $entry,
		);
		assert( $result->{success}, "Record inserted successfully" );
		$self->{_configuration}{_id} = $result->{id} if ( $result->{success} );

		$self->_dirty( 0, 'configuration' );
		$self->_dirty( 0, 'overrides' );
		$op = 1;
	}
	else
	{
		$result = NMISNG::DB::update(
			collection => $self->nmisng->nodes_collection(),
			query      => NMISNG::DB::get_query( and_part => {uuid => $self->uuid} ),
			record     => $entry
		);
		assert( $result->{success}, "Record updated successfully" );

		$self->_dirty( 0, 'configuration' );
		$self->_dirty( 0, 'overrides' );
		$op = 2;
	}
	return ( $result->{success} ) ? ( $op, undef ) : ( -2, $result->{error} );
}

# return nmisng object this node is using
sub nmisng
{
	my ($self) = @_;
	return $self->{_nmisng};
}

# get the nodes id (which is its UUID)
sub uuid
{
	my ($self) = @_;
	return $self->{uuid};
}

# returns (1,nothing) if the node configuration is valid,
# (negative or 0, explanation) otherwise
sub validate
{
	my ($self) = @_;
	my $configuration = $self->configuration();

	return (-2, "node requires cluster_id") if ( !$configuration->{cluster_id} );
	for my $musthave (qw(name host group))
	{
		return (-1, "node requires $musthave property") if (!$configuration->{$musthave} ); # empty or zero is not ok
	}
	return (-3, "given netType is not a known type")
			if (!grep($configuration->{netType} eq $_, 
								split(/\s*,\s*/, $self->nmisng->config->{nettype_list})));
	return (-3, "given roleType is not a known type")
			if (!grep($configuration->{roleType} eq $_, 
								split(/\s*,\s*/, $self->nmisng->config->{roletype_list})));
		return (1,undef);
}

1;
