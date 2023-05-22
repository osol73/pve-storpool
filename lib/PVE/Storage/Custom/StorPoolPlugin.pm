package PVE::Storage::Custom::StorPoolPlugin;

use v5.16;

use strict;
use warnings;

use Carp qw(carp croak);
use Data::Dumper;
use File::Path;
use PVE::Storage;
use PVE::Storage::Plugin;
use PVE::JSONSchema qw(get_standard_option);
use Sys::Hostname;
use List::Util qw'first';

use JSON;
use LWP::UserAgent;
use LWP::Simple;

use base qw(PVE::Storage::Plugin);

# The volume tags that we look for and set
use constant {
    VTAG_VIRT => 'virt',
    VTAG_CLUSTER => 'pve-cluster',
    VTAG_TYPE => 'pve-type',
    VTAG_FORMAT => 'pve-format',
    VTAG_VM => 'pve-vm',
    VTAG_BASE => 'pve-base',
    VTAG_COMMENT => 'pve-comment',
    VTAG_SNAP => 'pve-snapshot',
    VTAG_SNAP_PARENT => 'pve-snapshot-parent',

    VTAG_V_PVE => 'pve',
};

my $SP_VERS = '1.0';

#TODO upload same iso on two storpool templates (test)
#TODO disks list shows iso files from other templates
#TODO disks list shows saved states



sub log_and_die($) {
    my ($msg) = @_;

    warn "FIXME-WIP: $msg\n";
    croak "FIXME-WIP: $msg\n";
}

# Get some storpool settings from storpool.conf
sub sp_confget() {
    my %res;
    open my $f, '-|', 'storpool_confget' or log_and_die "Could not run storpool_confget: $!";
    while (<$f>) {
        chomp;
        my ($var, $value) = split /=/, $_, 2;
        $res{$var} = $value;
    }
    $res{'SP_URL'} = "http://$res{SP_API_HTTP_HOST}:$res{SP_API_HTTP_PORT}/ctrl/$SP_VERS/";
    return %res;
}

# Wrapper functions for the actual request
sub sp_get($$) {
	my ($cfg, $addr) = @_;

	return sp_request($cfg, 'GET', $addr, undef);
}

sub sp_post($$$) {
	
	my ($cfg, $addr, $params) = @_;
	my $res = sp_request($cfg, 'POST', $addr, $params);
	return $res
}

# HTTP request to the storpool api
sub sp_request($$$){
	my ($cfg, $method, $addr, $params) = @_;
	
	return undef if ( ${^GLOBAL_PHASE} eq 'START' );

	my $h = HTTP::Headers->new;
	$h->header('Authorization' => 'Storpool v1:'.$cfg->{sp}->{'SP_AUTH_TOKEN'});
	
	my $p = HTTP::Request->new($method, $cfg->{'sp'}->{'SP_URL'}.$addr, $h);
	$p->content( encode_json( $params ) ) if defined( $params );
	
	my $ua = new LWP::UserAgent;
	$ua->timeout(2 * 60 * 60);
	my $response = $ua->request($p);
	if ($response->code eq "200"){
		return decode_json($response->content);
	}else{
		# this might break something
		my $res = decode_json($response->content);
		return $res if $res and $res->{'error'};
		return { 'error' => { 'descr' => 'Error code: '.$response->code} };
	}
}

sub sp_vol_create($$$$$;$){
	my ($cfg, $name, $size, $template, $ignoreError, $tags) = @_;
        if (defined($name) && $name) {
            log_and_die 'FIXME-WIP: sp_vol_create: non-null name: '.Dumper({name => $name, size => $size, template => $template, ignoreError => $ignoreError});
        }
	
	my $req = { 'template' => $template, 'size' => $size, (defined($tags) ? (tags => $tags) : ()) };
	my $res = sp_post($cfg, "VolumeCreate", $req);
	
	die "Storpool: ".$res->{'error'}->{'descr'} if (!$ignoreError && $res->{'error'});
	return $res
}

sub sp_vol_status($) {
    my ($cfg) = @_;
	
	my $res = sp_get($cfg, "VolumesGetStatus");
	
	# If there is an error here it's fatal, we do not check.
	die $res->{'error'}->{'descr'} if ($res->{'error'});
	
	return $res;
}

sub sp_vol_list($) {
    my ($cfg) = @_;
	my $res = sp_get($cfg, "VolumesList");
	
	die $res->{'error'}->{'descr'} if ($res->{'error'});
	
	return $res;
}

sub sp_vol_info($$) {
	my ($cfg, $global_id) = @_;
	
	my $res = sp_get($cfg, "Volume/~$global_id");
	
	die $res->{'error'}->{'descr'} if ($res->{'error'});
	
	return $res;
}

sub sp_vol_info_single($$) {
    my ($cfg, $global_id) = @_;

    my $res = sp_vol_info($cfg, $global_id);
    if (!defined($res->{'data'}) || ref($res->{'data'} ne 'ARRAY') || @{$res->{'data'}} != 1) {
        log_and_die("Internal StorPool error: expected exactly one volume with the $global_id global ID, got ".Dumper($res));
    }
    $res->{'data'}->[0]
}

sub sp_snap_info_single($$) {
    my ($cfg, $global_id) = @_;

    my $res = sp_snap_info($cfg, $global_id);
    if (!defined($res->{'data'}) || ref($res->{'data'} ne 'ARRAY') || @{$res->{'data'}} != 1) {
        log_and_die("Internal StorPool error: expected exactly one snapshot with the $global_id global ID, got ".Dumper($res));
    }
    $res->{'data'}->[0]
}

sub sp_snap_list($) {
    my ($cfg) = @_;
	
	my $res = sp_get($cfg, "SnapshotsList");
	
	die $res->{'error'}->{'descr'} if ($res->{'error'});
	
	return $res;
}

sub sp_attach_list($) {
    my ($cfg) = @_;
	my $res = sp_get($cfg, "AttachmentsList");
	
	die $res->{'error'}->{'descr'} if ($res->{'error'});
	
	return $res;
}

sub sp_snap_info($$) {
	my ($cfg, $snapname) = @_;
	
	my $res = sp_get($cfg, "Snapshot/~$snapname");
	#use Devel::StackTrace;
	#my $trace = Devel::StackTrace->new;
	die $res->{'error'}->{'descr'} if ($res->{'error'});
	
	return $res;
}

sub sp_disk_list($) {
    my ($cfg) = @_;
	
	my $res = sp_get($cfg, "DisksList");
	
	die $res->{'error'}->{'descr'} if ($res->{'error'});
	
	return $res;
}

sub sp_temp_get($$) {
	my ($cfg, $name) = @_;
	
	my $res = sp_get($cfg, "VolumeTemplateDescribe/$name");
	
	die $res->{'error'}->{'descr'} if ($res->{'error'});
	return $res;
}

#TODO, if adding more nodes, iso need to be attached to them as well
sub sp_vol_attach($$$$$;$) {
	my ($cfg, $global_id, $spid, $perms, $ignoreError, $is_snapshot) = @_;
	
	my $res;
        my $keyword = $is_snapshot ? 'snapshot' : 'volume';
        my $req = [{ $keyword => "~$global_id", $perms => [$spid], 'force' => JSON::false }];
        $res = sp_post($cfg, "VolumesReassignWait", $req);
	
	die "Storpool: $global_id, $spid, $perms, $ignoreError: ".$res->{'error'}->{'descr'} if (!$ignoreError && $res->{'error'});
	
	
	return $res
}

sub sp_vol_detach($$$$;$) {
	my ($cfg, $global_id, $spid, $ignoreError, $is_snapshot) = @_;
	
	my $req;
        my $keyword = $is_snapshot ? 'snapshot' : 'volume';
	if ($spid eq "all"){
		$req = [{ $keyword => "~$global_id", 'detach' => $spid, 'force' => JSON::false }];
	}else{
		$req = [{ $keyword => "~$global_id", 'detach' => [$spid], 'force' => JSON::false }];
	}
	my $res = sp_post($cfg, "VolumesReassignWait", $req);
	
	die "Storpool: ".$res->{'error'}->{'descr'} if (!$ignoreError && $res->{'error'});
	return $res
}

sub sp_vol_del($$$) {
	my ($cfg, $global_id, $ignoreError) = @_;
	
	my $req = {};
	my $res = sp_post($cfg, "VolumeDelete/~$global_id", $req);
	
	die "Storpool: ".$res->{'error'}->{'descr'} if (!$ignoreError && $res->{'error'});
	return $res
}

sub sp_vol_from_snapshot ($$$;$) {
	my ($cfg, $global_id, $ignoreError, $tags) = @_;
	
	my $req = { 'parent' => "~$global_id", 'tags' => $tags // '' };
	my $res = sp_post($cfg, "VolumeCreate", $req);
	
	die "Storpool: ".$res->{'error'}->{'descr'} if (!$ignoreError && $res->{'error'});
	return $res
}

# Currently only used for resize
sub sp_vol_update ($$$$) {
	my ($cfg, $global_id, $req, $ignoreError) = @_;
	
	my $res = sp_post($cfg, "VolumeUpdate/~$global_id", $req);
	
	die "Storpool: ".$res->{'error'}->{'descr'} if (!$ignoreError && $res->{'error'});
	return $res
}

sub sp_services_list($) {
    my ($cfg) = @_;
	
	my $res = sp_get($cfg, "ServicesList");
	return $res;
}

sub sp_vol_snapshot($$$;$) {
	my ($cfg, $global_id, $ignoreError, $tags) = @_;
	
	# my $req = { 'name' => $snap };
        my $req = { tags => $tags // {}, };
	my $res = sp_post($cfg, "VolumeSnapshot/~$global_id", $req);
	
	die "Storpool: ".$res->{'error'}->{'descr'} if (!$ignoreError && $res->{'error'});
	return $res
}

sub sp_snap_del($$$) {
	my ($cfg, $global_id, $ignoreError) = @_;
	
	my $req = { };
	my $res = sp_post($cfg, "SnapshotDelete/~$global_id", $req);
	
	die "Storpool: ".$res->{'error'}->{'descr'} if (!$ignoreError && $res->{'error'});
	return $res
}

sub sp_placementgroup_list($$) {
	my ($cfg, $pg) = @_;
	
	my $res = sp_get($cfg, "PlacementGroupDescribe/$pg");
	
	die $res->{'error'}->{'descr'} if ($res->{'error'});
	return $res;
}

sub sp_vol_revert_to_snapshot($$$) {
    my ($cfg, $vol_id, $snap_id) = @_;

    my $req = { 'toSnapshot' => "~$snap_id" };
    my $res = sp_post($cfg, "VolumeRevert/~$vol_id", $req);

    die "Storpool: ".$res->{'error'}->{'descr'} if $res->{'error'};
    return $res
}

sub sp_volume_find_snapshots($$$) {
    my ($cfg, $vol, $snap) = @_;

    grep {
        sp_vol_tag_is($_, VTAG_VIRT, VTAG_V_PVE) &&
        sp_vol_tag_is($_, VTAG_CLUSTER, $cfg->{'sp'}->{'SP_CLUSTER_NAME'}) &&
        $_->{'templateName'} eq $cfg->{'storeid'} &&
        sp_vol_tag_is($_, VTAG_SNAP_PARENT, $vol->{'globalId'}) &&
        (!defined($snap) || sp_vol_tag_is($_, VTAG_SNAP, $snap))
    } @{sp_snap_list($cfg)->{'data'}}
}

# Delete all snapshot that are parents of the volume provided
sub sp_clean_snaps($$) {
    my ($cfg, $vol) = @_;

    for my $snap_obj (sp_volume_find_snapshots($cfg, $vol, undef)) {
        sp_snap_del($cfg, $snap_obj->{'globalId'}, 0);
    }
}

# Various name encoding helpers and utility functions

# Get the value of a tag for a volume.
#
# Returns an undefined value if the volume does not have that tag.
sub sp_vol_get_tag($ $) {
    my ($vol, $tag) = @_;

    ${$vol->{tags} // {}}{$tag}
}

# Check whether a volume has the specified tag, and that its value is as expected.
sub sp_vol_tag_is($ $ $) {
    my ($vol, $tag, $expected) = @_;
    my $value = sp_vol_get_tag($vol, $tag);

    defined($value) && $value eq $expected
}

# Check whether a content type denotes an image, either of a VM or of a container.
sub sp_type_is_image($) {
    my ($type) = @_;

    $type eq 'images' || $type eq 'rootdir'
}

# Encode a single key/value pair.
sub sp_encode_single($) {
    my ($pair) = @_;
    if (scalar @{$pair} != 2) {
        log_and_die "Internal error: sp_encode_single: expected two elements: ".Dumper($pair);
    }
    my ($key, $value) = @{$pair};

    if (length($key) != 1) {
        log_and_die "Internal error: sp_encode_single: expected a single-character key: ".Dumper($pair);
    }
    $value //= '';

    # Encode some special characters; for the present, dashes only.
    $value =~ s/-/--/g;

    "$key$value"
}

# Encode a list of [key, value] pairs into a "V0-ga.b.c-timages"-style string.
sub sp_encode_list($) {
    my ($raw) = @_;
    my @slugs = map { sp_encode_single($_) } @{$raw};
    join('-', @slugs)
}

sub sp_encode_volsnap_from_tags($) {
    my ($vol) = @_;

    sp_encode_list([
        [
            ($vol->{'snapshot'} ? 'S' : 'V'),
            '0',
        ],
        [
            'g',
            $vol->{'globalId'},
        ],
        [
            't',
            $vol->{'tags'}->{VTAG_TYPE()},
        ],
        [
            'v',
            $vol->{'tags'}->{VTAG_VM()} // '',
        ],
        [
            'B',
            $vol->{'tags'}->{VTAG_BASE()} // '0',
        ],
        [
            'c',
            $vol->{'tags'}->{VTAG_COMMENT()} // '',
        ],
        [
            's',
            $vol->{'tags'}->{VTAG_SNAP()} // '',
        ],
        [
            'P',
            $vol->{'tags'}->{VTAG_SNAP_PARENT()} // '',
        ],
        # TODO: pp: 'f' for a format other than "raw"
    ])
}

sub sp_decode_single($) {
    my ($part) = @_;

    if (!defined($part) || $part eq '') {
        log_and_die 'Internal error: sp_decode_single: got part '.Dumper(\$part);
    }

    # Make sure there is a sensible number of dashes in there...
    if ($part =~ /(?: ^ | [^-] ) - (?: -- )* (?: $ | [^-] )/x) {
        log_and_die 'FIXME-TODO: decode an odd number of dashes: '.Dumper(\$part);
    }
    # ...and then decode them.
    $part =~ s/--/-/g;

    split //, $part, 2
}

sub sp_decode_list($) {
    my ($raw) = @_;

    # Split on dashes, but ignore double dashes.
    my @parts;
    while ($raw =~ /^ (?P<first> (?: [^-] | -- )+ ) (?: - (?P<rest> .* ) )? $/x) {
        push @parts, $+{'first'};
        $raw = $+{'rest'};
        last unless defined $raw;
    }
    if ($raw) {
        log_and_die "FIXME-TODO: sp_decode_list: leftover ".Dumper(\$raw);
    }

    map { sp_decode_single($_) } @parts
}

sub sp_s($) {
    my ($value) = @_;

    if (defined($value) && $value eq '') {
        undef
    } else {
        $value
    }
}

sub sp_decode_volsnap_to_tags($) {
    my ($volname) = @_;

    my ($first, $rest) = split /-/, $volname, 2;
    if (!defined($first)) {
        log_and_die "sp_decode_volname_to_tags: no dashes at all: ".Dumper(\$volname);
    }

    my $snapshot;
    if ($first eq 'V0') {
        $snapshot = JSON::false;
    } elsif ($first eq 'S0') {
        $snapshot = JSON::true;
    } else {
        log_and_die 'sp_decode_volname_to_tags: unsupported first slug: '.Dumper(\$volname);
    }

    my %pairs = sp_decode_list($rest // '');
    return {
        snapshot => $snapshot,
        globalId => $pairs{'g'},
        tags => {
            VTAG_TYPE() => $pairs{'t'},
            VTAG_VM() => sp_s($pairs{'v'}),
            VTAG_BASE() => $pairs{'B'} // '0',
            VTAG_COMMENT() => sp_s($pairs{'c'}),
            VTAG_SNAP() => sp_s($pairs{'s'}),
            VTAG_SNAP_PARENT() => sp_s($pairs{'P'}),
        },
    };
}

sub sp_cfg($$) {
    my ($scfg, $storeid) = @_;

    my %sp = sp_confget();
    return {
        'storeid' => $storeid,
        'scfg' => $scfg,
        'sp' => \%sp,
    };
}

# Configuration

sub api {
    my $minver = 3;
    my $maxver = 10;

    # We kind of depend on the way `use constant` declares a function.
    # If we try to use barewords and not functions, the compiler will
    # throw a compile-time error, not a run-time one, which would
    # disable the whole plugin.

    my $apiver;
    eval {
        $apiver = PVE::Storage::APIVER();
    };
    if ($@) {
        # Argh, they don't even declare APIVER? Well... too bad.
        return $minver;
    }

    my $apiage;
    eval {
        $apiage = PVE::Storage::APIAGE();
    };
    if ($@) {
        # Hm, no APIAGE? OK, is their version within our range?
        if ($apiver >= $minver && $apiver <= $maxver) {
            return $apiver;
        }

        # Ah well...
        return $minver;
    }

    # Is our version within their declared supported range?
    if ($apiver >= $maxver && $apiver <= $maxver + $apiage) {
        return $maxver;
    }

    # This is a bit of a lie, but, well...
    if ($apiver <= $maxver) {
        return $apiver;
    }

    # Oof. This is fun.
    return $minver;
}

# This is the most important method. The ID of the plugin
sub type {
    return 'storpool';
}

# The capabilities of the plugin
sub plugindata {
    
    return {
	content => [ { images => 1, rootdir => 1, vztmpl => 1, iso => 1, backup => 1, none => 1 },
		     { images => 1,  rootdir => 1 }],
	format => [ { raw => 1 } , 'raw' ],
    };
}   

# The properties the plugin can handle
sub properties {

    return {
	'sp-extra-tags' => {
	    description => 'Additional tags to add to the StorPool volumes and snapshots',
	    type => 'string',
	},
    };
}

sub options {

    return {
	path => { fixed => 1 },
        nodes => { optional => 1 },
	shared => { optional => 1 },
	disable => { optional => 1 },
        maxfiles => { optional => 1 },
	content => { optional => 1 },
	format => { optional => 1 },
	'sp-extra-tags' => { optional => 1 },
   };
}

# Storage implementation

# The path has to be provided separately for iso file listing
sub check_config {
    my ($class, $sectionId, $config, $create, $skipSchemaCheck) = @_;

    $config->{path} = "/dev/storpool-byid" if $create && !$config->{path};

    return $class->SUPER::check_config($sectionId, $config, $create, $skipSchemaCheck);
}

# Just chech value before accepting the request
PVE::JSONSchema::register_format('pve-storage-replication', \&sp_parse_replication);
sub sp_parse_replication {
    my ($rep, $noerr) = @_;

    if ($rep < 1 or $rep > 4) {
	return undef if $noerr;
	die "replication must be between 1 and 4\n";
    }

    return $rep;
}

# This creates the storpool template. It's called frequently though,
# so we ignore "already exists" errors
sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    my $cfg = sp_cfg($scfg, $storeid);
    
    sp_temp_get($cfg, $storeid);
}

sub sp_get_tags($) {
    my ($cfg) = @_;

    my $extra_spec = $cfg->{'scfg'}->{'sp-extra-tags'} // '';
    my %extra_tags = map { split /=/, $_, 2 } split /\s+/, $extra_spec;
    return (
        VTAG_VIRT() => VTAG_V_PVE,
        VTAG_CLUSTER() => $cfg->{'sp'}->{'SP_CLUSTER_NAME'},
        %extra_tags,
    );
}

# Create the volume
sub alloc_image {
	my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;
        my $cfg = sp_cfg($scfg, $storeid);

	# One of the few places where size is in K
	$size *= 1024;
	die "unsupported format '$fmt'" if $fmt ne 'raw';
	
	my $c_res = sp_vol_create($cfg, undef, $size, $storeid, 0, {
            sp_get_tags($cfg),
            VTAG_TYPE() => 'images',
            VTAG_FORMAT() => $fmt,
            (defined($vmid) ? (VTAG_VM() => "$vmid"): ()),
        });
        my $global_id = ($c_res->{'data'} // {})->{'globalId'};
        if (!defined($global_id) || $global_id eq '') {
            log_and_die 'StorPool internal error: no globalId in the VolumeCreate API response: '.Dumper($c_res);
        }

        my $vol = sp_vol_info_single($cfg, $global_id);
        sp_encode_volsnap_from_tags($vol);
}

# Status of the space of the storage
sub status {
    my ($class, $storeid, $scfg, $cache) = @_;
    my $cfg = sp_cfg($scfg, $storeid);
    # TODO: pp: discuss: we should probably change this to process "template status" in some way
    my $disks = sp_disk_list($cfg);

    my $total = 0;
    my $free = 0;
    my $used = 0;
    
    my $template = sp_temp_get($cfg, $storeid);
    my $placeAll = sp_placementgroup_list($cfg, $template->{data}->{placeAll})->{data}->{disks};
    my $placeTail = sp_placementgroup_list($cfg, $template->{data}->{placeTail})->{data}->{disks};
    my $minAG = 100000000000000;

    foreach my $diskID (@$placeAll){
	$minAG = $disks->{data}->{$diskID}->{agCount} if $disks->{data}->{$diskID}->{agCount} < $minAG;
	$used += $disks->{data}->{$diskID}->{'objectsOnDiskSize'};
    }

    if ($template->{data}->{placeAll} eq $template->{data}->{placeTail}){
	$total = $minAG * 512*1024*1024 * 4096 / (4096 + 128) * scalar(@$placeAll);
    }else{
	foreach my $diskID (@$placeTail){
	    $minAG = $disks->{data}->{$diskID}->{agCount} if $disks->{data}->{$diskID}->{agCount} < $minAG;
	    $used += $disks->{data}->{$diskID}->{'objectsOnDiskSize'};
	}
	$total = $minAG * 512*1024*1024 * 4096 / (4096 + 128) * (scalar(@$placeAll) + scalar(@$placeTail));
    }

    #while ((my $key, my $disk) = each $disks->{'data'}){
	#$total += $disk->{'agCount'} * 512*1024*1024 * 4096 / (4096 + 128);
	#$used += $disk->{'objectsOnDiskSize'};
    #}
    
    #This way this could be negative
    $free = $total - $used;
    #my $template = sp_temp_get($storeid);
        
    my $replication = $template->{'data'}->{'replication'};
    return ($total/$replication, $free/$replication, $used/$replication, 1);
}

sub parse_volname ($) {
    my ($class, $volname) = @_;

    my $vol = sp_decode_volsnap_to_tags($volname);

    return (
        $vol->{'tags'}->{VTAG_TYPE()},
        $vol->{'globalId'},
        $vol->{'tags'}->{VTAG_VM()},
        undef,
        undef,
        ($vol->{'tags'}->{VTAG_BASE()} // '0') eq '1',
        'raw',
    )
}

sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;

    my ($vtype, $name, $vmid) = $class->parse_volname("$volname");
    
    my $path = "/dev/storpool-byid/$name";

    return wantarray ? ($path, $vmid, $vtype) : $path;
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $exclusive, $cache) = @_;
    my $cfg = sp_cfg($scfg, $storeid);
	
    my $path = $class->path($scfg, $volname, $storeid);

    my $vol = sp_decode_volsnap_to_tags($volname);
    my $global_id = $vol->{'globalId'};

    my $perms = $vol->{'snapshot'} ? 'ro' : 'rw';

    # TODO: pp: remove this when the configuration goes into the plugin?
    sp_vol_attach($cfg, $global_id, $cfg->{'sp'}->{'SP_OURID'}, $perms, 0, $vol->{'snapshot'});
    log_and_die "Internal StorPool error: could not find the just-attached volume $global_id at $path" unless -e $path;
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $cache) = @_;
    my $cfg = sp_cfg($scfg, $storeid);
    
    my $path = $class->path($scfg, $volname, $storeid);
    
    return if ! -b $path;

    my $vol = sp_decode_volsnap_to_tags($volname);
    my $global_id = $vol->{'globalId'};

    # TODO: pp: remove this when the configuration goes into the plugin?
    sp_vol_detach($cfg, $global_id, $cfg->{'sp'}->{'SP_OURID'}, 0, $vol->{'snapshot'});
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;
    my $cfg = sp_cfg($scfg, $storeid);
    my $vol = sp_decode_volsnap_to_tags($volname);
    my ($global_id, $is_snapshot) = ($vol->{'globalId'}, $vol->{'snapshot'});

    # Volume could already be detached, we do not care about errors
    sp_vol_detach($cfg, $global_id, 'all', 1, $is_snapshot);

    if ($is_snapshot) {
        sp_snap_del($cfg, $global_id, 0);
    } else {
        sp_vol_del($cfg, $global_id, 0);
        sp_clean_snaps($cfg, $vol);
    }
    
    return undef;
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;

    my $features = {
	snapshot => { current => 1, snap => 1 },
	clone => { base => 1, snap => 1 },
	template => { current => 1 },
	copy => { base => 1,
		  current => 1,
		  snap => 1 },
        rename => { current => 1, },
        sparseinit => { base => 1, current => 1, snap => 1 },
    };

    my ($vtype, $name, $vmid, , undef, undef, $isBase) =
	$class->parse_volname($volname);

    my $key = undef;
    if($snapname){
        $key = 'snap';
    }else{
        $key =  $isBase ? 'base' : 'current';
    }

    return 1 if defined($features->{$feature}->{$key});

    return undef;
}

#sub file_size_info {
#    my ($filename, $timeout) = @_;
#}

sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;
    my $cfg = sp_cfg($scfg, $storeid);
    
    my $vol = sp_decode_volsnap_to_tags($volname);
    my $global_id = $vol->{'globalId'};
    
    my $res = sp_vol_status($cfg);
    my @vol_status = grep { $_->{'globalId'} eq $global_id } values %{$res->{'data'}};
    if (@vol_status != 1) {
        log_and_die "Internal StorPool error: expected exactly one $global_id volume: ".Dumper(\@vol_status);
    }
    my ($size, $used) = ($vol_status[0]->{'size'}, $vol_status[0]->{'storedSize'});

    # TODO: pp: do we ever need to support anything other than 'raw' here?
    return wantarray ? ($size, 'raw', $used, undef) : $size;

}

sub list_volumes {
    my ($class, $storeid, $scfg, $vmid, $content_types) = @_;
    my $cfg = sp_cfg($scfg, $storeid);
    my %ctypes = map { $_ => 1 } @{$content_types};

    my $volStatus = sp_vol_status($cfg);
    my $res = [];

    for my $vol (values %{$volStatus->{'data'}}) {
        next unless sp_vol_tag_is($vol, VTAG_VIRT, VTAG_V_PVE) &&
            sp_vol_tag_is($vol, VTAG_CLUSTER, $cfg->{'sp'}->{'SP_CLUSTER_NAME'});
        my $v_type = sp_vol_get_tag($vol, VTAG_TYPE);
        next unless defined($v_type) && exists $ctypes{$v_type};
        my $v_template = $vol->{templateName} // '';
        next unless $v_template eq $storeid;

        my $v_vmid = sp_vol_get_tag($vol, VTAG_VM);
        if (defined $vmid) {
            next unless defined($v_vmid) && $v_vmid eq $vmid;
        }

        # TODO: pp: apply the rootdir/images fix depending on $v_vmid

        # TODO: pp: figure out whether we ever need to store non-raw data on StorPool
        my $data = {
            volid => "$storeid:".sp_encode_volsnap_from_tags($vol),
            content => $v_type,
            vmid => $v_vmid,
            size => $vol->{size},
            used => $vol->{storedSize},
            parent => undef,
            format => 'raw',
        };
        push @{$res}, $data;
    }

    return $res;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;
    log_and_die 'FIXME-TODO: list_images: non-null vmid: '.Dumper({class => $class, storeid => $storeid, scfg => $scfg, vmid => $vmid, vollist => $vollist, cache => $cache}) if defined($vmid);
    $class->list_volumes($storeid, $scfg, $vmid, [keys %{$scfg->{content}}])
}

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;
    my $cfg = sp_cfg($scfg, $storeid);

    my $vol = sp_decode_volsnap_to_tags($volname);
    my ($global_id, $vtype) = ($vol->{'globalId'}, $vol->{tags}->{VTAG_TYPE()});
    # my ($vtype, $name, $vmid, undef, undef, $isBase) =
	# $class->parse_volname($volname);
    die "create_base not possible with types other than images. '$vtype' given.\n" if $vtype ne 'images';

    die "create_base not possible with base image\n" if $vol->{tags}->{VTAG_BASE()};
	
    # my ($size, $format, $used, $parent) = $class->volume_size_info($scfg, $storeid, $volname, 0);
    # die "file_size_info on '$volname' failed\n" if !($format && $size);

    # die "volname '$volname' contains wrong information about parent\n"
	# if $isBase && !$parent;

    # my $newname = $name;
    # $newname =~ s/^vm-/base-/;

    my $current_tags = (
        $vol->{'snapshot'}
            ? sp_snap_info_single($cfg, $vol->{'globalId'})
            : sp_vol_info_single($cfg, $vol->{'globalId'})
    )->{'tags'} // {};

    my $snap_res = sp_vol_snapshot($cfg, $global_id, 0, {
        %{$current_tags},
        VTAG_BASE() => "1",
    });

    my $snap_id = $snap_res->{'data'}->{'snapshotGlobalId'};
    my $snap = sp_snap_info_single($cfg, $snap_id);

    sp_vol_detach($cfg, $global_id, 'all', 0);
    sp_vol_del($cfg, $global_id, 0);

    return sp_encode_volsnap_from_tags($snap);
}

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap) = @_;
    my $cfg = sp_cfg($scfg, $storeid);

    my $vol = sp_decode_volsnap_to_tags($volname);
    if ($snap) {
        my @found = sp_volume_find_snapshots($cfg, $vol, $snap);
        if (@found != 1) {
            log_and_die "Expected exactly one StorPool snapshot for $vol / $snap, got ".Dumper(\@found);
        }

        # OK, let's go wild...
        $vol = $found[0];
    }

    my ($global_id, $vtype, $isBase) = (
        $vol->{'globalId'},
        $vol->{'tags'}->{VTAG_TYPE()},
        $vol->{'tags'}->{VTAG_BASE()},
    );

    die "clone_image on wrong vtype '$vtype'\n" if $vtype ne 'images';

    die "clone_image only works on StorPool snapshots\n" if !$vol->{'snapshot'};

    my $current_tags = sp_snap_info_single($cfg, $vol->{'globalId'})->{'tags'} // {};

    my $c_res = sp_vol_from_snapshot($cfg, $global_id, 0, {
        %{$current_tags},
        VTAG_BASE() => '0',
        VTAG_VM() => "$vmid",
    });
    my $newvol = sp_vol_info_single($cfg, $c_res->{'data'}->{'globalId'});
    return sp_encode_volsnap_from_tags($newvol);
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;
    my $cfg = sp_cfg($scfg, $storeid);


    my $vol = sp_decode_volsnap_to_tags($volname);
    sp_vol_update($cfg, $vol->{'globalId'}, { 'size' => $size }, 0);
    
    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    log_and_die "deactivate_storage: args: ".Dumper({class => $class, storeid => $storeid, scfg => $scfg, cache => $cache});

    #TODO this does NOT occur when deleteing a storage
    
}

sub check_connection {
    my ($class, $storeid, $scfg) = @_;
    my $cfg = sp_cfg($scfg, $storeid);
    my $res = sp_services_list($cfg);
    die "Could not fetch the StorPool services list\n" if ! defined $res;
    die "Could not fetch the StorPool services list: ".$res->{'error'}."\n" if $res->{'error'};
    return 1;
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;
    my $cfg = sp_cfg($scfg, $storeid);

    my $vol = sp_decode_volsnap_to_tags($volname);
    sp_vol_snapshot($cfg, $vol->{'globalId'}, 0, {
        %{$vol->{tags}},
        sp_get_tags($cfg),
        VTAG_SNAP() => $snap,
        VTAG_SNAP_PARENT() => $vol->{'globalId'},
    });

    return undef;
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;
    my $cfg = sp_cfg($scfg, $storeid);

    my $vol = sp_decode_volsnap_to_tags($volname);
    for my $snap_obj (sp_volume_find_snapshots($cfg, $vol, $snap)) {
        sp_snap_del($cfg, $snap_obj->{'globalId'}, 0);
    }

    return undef;
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;
    my $cfg = sp_cfg($scfg, $storeid);

    my $vol = sp_decode_volsnap_to_tags($volname);
    my @found = sp_volume_find_snapshots($cfg, $vol, $snap);
    if (@found != 1) {
        log_and_die "volume_snapshot_rollback: expected exactly one '$snap' snapshot for $vol->{globalId}, got ".Dumper(\@found);
    }

    my $snap_obj = $found[0];
    sp_vol_revert_to_snapshot($cfg, $vol->{'globalId'}, $snap_obj->{'globalId'});
    
    return undef;
}

sub volume_snapshot_needs_fsfreeze {
    return 1;
}

sub get_subdir {
    my ($class, $scfg, $vtype) = @_;
    log_and_die "get_subdir: args: ".Dumper({class => $class, scfg => $scfg, vtype => $vtype});
	
    return "/dev/storpool";
}

sub delete_store {
	my ($class, $storeid) = @_;
        my $cfg = sp_cfg({}, $storeid);
    log_and_die "delete_store: args: ".Dumper({class => $class, storeid => $storeid});
	my $vols_hash = sp_vol_list($cfg);
	my $snaps_hash = sp_snap_list($cfg);
	my $atts_hash = sp_attach_list($cfg);

        my %attachments = map { ($_->{volume}, 1) } @{$atts_hash->{'data'}};

	foreach my $vol (@{$vols_hash->{data}}){
                next unless sp_vol_tag_is($vol, VTAG_VIRT, VTAG_V_PVE) &&
                    sp_vol_tag_is($vol, VTAG_CLUSTER, $cfg->{'sp'}->{'SP_CLUSTER_NAME'});
                next unless $vol->{'templateName'} eq $storeid;
                if ($attachments{$vol->{'name'}}) {
                        sp_vol_detach($cfg, $vol->{'globalId'}, 'all', 0);
                }
                sp_vol_del($cfg, $vol->{'globalId'}, 0);
	}

	foreach my $snap (@{$snaps_hash->{data}}){
                next unless sp_vol_tag_is($snap, VTAG_VIRT, VTAG_V_PVE) &&
                    sp_vol_tag_is($snap, VTAG_CLUSTER, $cfg->{'sp'}->{'SP_CLUSTER_NAME'});
                next unless $snap->{'templateName'} eq $storeid;
                if ($attachments{$snap->{'name'}}) {
                        sp_vol_detach($snap->{'globalId'}, 'all', 0, 1);
                }
                sp_snap_del($cfg, $snap->{'globalId'},0);
	}
}

sub rename_volume($$$$$$) {
    my ($class, $scfg, $storeid, $source_volname, $target_vmid, $target_volname) = @_;
    my $cfg = sp_cfg($scfg, $storeid);

    my $vol = sp_decode_volsnap_to_tags($source_volname);
    sp_vol_update($cfg, $vol->{'globalId'}, {
        'tags' => {
            %{$vol->{'tags'}},
            VTAG_VM() => $target_vmid,
        },
    }, 0);

    my $updated = sp_vol_info_single($cfg, $vol->{'globalId'});
    "$storeid:".sp_encode_volsnap_from_tags($updated)
}

1;
#TODO when creating new storage, fix placementgroups
#TODO detach on normal shutdown (maybe done)
#TODO reattach iso after reboot
#misc TODO
# remove "raw" from interface make storage!   
#full clone (dropped)
#TODO clean sectionconfig.pm
