package Vinetctl::Topology;

use strict;
use warnings;
use feature qw( say );
use constant { TRUE => 1, FALSE => 0 };
use Hash::Util qw( lock_keys lock_value unlock_value ); 
use Data::Validate::IP qw( is_ipv4 );
use File::Path qw( make_path );

use Vinetctl::Globals qw( 
    %args
    %rc
    %globals
);

use Vinetctl::Debug qw( 
    report_calling_stack
    report_retval
    Die
    Warn
);

use Vinetctl::Util qw( 
    get_uid 
    my_system
);

use Vinetctl::Init qw(
    get_rc
    log_cmdline
    get_vm_list
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    open_topology_file
    create_topology
    init_topology
    chk_topology
    get_vmref_by_name
    create_vm_hashref
    create_topology_vde
);


# init_topology(): set up the topology
#######################################

sub init_topology { 
    report_calling_stack(@_) if $args{d};

    my $retval;

    # make topology specific subdirs, if necessary 
    ###############################################

    make_path( "$rc{socket_dir}/$globals{topology_name}",
               "$rc{pid_dir}/$globals{topology_name}",
               "$rc{vde_dir}/$globals{topology_name}",
               "$rc{history_dir}/$globals{topology_name}", 
               "$rc{autostart_base_dir}/$globals{topology_name}", 
               "$rc{stderr_dir}/$globals{topology_name}", 
               "$rc{wirefilter_dir}/$globals{topology_name}",
               "$rc{migrate_in_dir}/$globals{topology_name}", 
               "$rc{migrate_out_dir}/$globals{topology_name}", 
    );

    # make topology
    ################

    my $fh = open_topology_file( 
        $globals{topology_name} eq 'default' ?
        '_DEFAULT'                           :
        "$rc{topology_dir}/$globals{topology_name}" 
    );
    create_topology( $fh, $globals{topology_name} ); 

    # determine if and which machines were specified on the cmdline
    ################################################################

    unlock_value( %globals, 'vm_list' );
    if ( @{ $globals{action_params} } ) {    # machines were specified
        $globals{vm_list} = get_vm_list( @{ $globals{action_params} } );
    } 
    else {                              # none specified, defaults to all
        $globals{vm_list} = $globals{topology}; 
    } 
    lock_value( %globals, 'vm_list' );

    # check topology
    #################

    if ( my $err_msgs = chk_topology() ) { 
        say "Error: $_" foreach @$err_msgs;
        $retval = 0;                    # bad topology
    }
    else { $retval = 1 }

    return( report_retval($retval) );
}

# create_vm_hashref(): create and return a hashref representing a vm
#####################################################################

sub create_vm_hashref {
    report_calling_stack(@_) if $args{d};

    my %vm = (
        name => undef,
        arch => 'x86_64',
        images => [], 
        memory => 256,
        display => { name => 'curses' },
        driver => 'virtio',
        powerd => 'powerdown',
        nics => [], 
        cdrom => undef,
    );

    # lock_keys() returns \%vm
    return( report_retval( lock_keys(%vm) ) );
}

# open_topology_file(): open file for reading, return fh
#########################################################

sub open_topology_file {
    report_calling_stack(@_) if $args{d};

    my $topology_file = shift;
    my $topology_fh;

    # builtin sample topology:
    ###########################

    if ( $topology_file eq '_DEFAULT' ) {
        my $default = get_default_topology();
        open $topology_fh, '<', \$default;
    } 
    # read topology from file:
    ###########################
    else {
        Die "$topology_file does not exist\n" 
            unless -e "$rc{topology_dir}/$globals{topology_name}";
        Die "$topology_file is not readable\n" 
            unless -r _;
        Die "$topology_file is not a plain text file\n" 
            unless -T _;
        Die "cannot open $rc{topology_dir}/$globals{topology_name}: $!\n" 
            unless open($topology_fh, '<', "$topology_file");
    }

    return( report_retval($topology_fh) );
}

# get_default_topology(): a simple topology used as default
############################################################

sub get_default_topology {
    report_calling_stack(@_) if $args{d};

#############################################
my $default = <<"    DEFAULT";
## h1--rt1--h2
% name images
h1  vde:e0:55:rt1,e0
rt1 vde:e0:56:h1,e0  vde:e1:57:h2,e0
h2  vde:e0:58:rt1,e1
    DEFAULT
#############################################

    return( report_retval($default) );
}

# get_topology_template(): get template line from topology file
################################################################

sub get_topology_template { 
    report_calling_stack(@_) if $args{d};

    my( $topology_fh, $topology_name, $template ) = @_;

    # get to the template line
    ###########################

    while ( <$topology_fh> ) {
        next if m/^\s*$/ or m/^\s*#/; 
        last;
    }

    # template line must be first line after comments or blanks
    ############################################################

    Die "topology file $globals{topology_name}: no template line\n"
        unless m/^%\s+/;

    # does the line end with '\'?  if so, it's continued
    #####################################################

    my $continued = s/\\\s*$// ? TRUE : FALSE; 
    chomp( my $line = $_ );

    # keep grabbing lines until the continued template line is done
    ################################################################

    LINE: while ( $continued ) {
        chomp( $_ = <$topology_fh> );
        # concatenate when newlines escaped with '\'
        $line .= $_;
        if ( $line =~ s/\\\s*$// ) { next LINE }
        else                       { $continued = FALSE }
    }


    @$template = split( ' ', $line );

    # get rid of '%'; 
    shift @$template; 

    ## TODO: what if first word is '%asdf' or something?  should chk
    ## the value of what's shifted to ensure it is '%'

    # got the template, check for sanity
    #####################################

    grep {/^name$/ } @$template
        or Die "$topology_name: template line $. must contain 'name'\n";
    my $vm_ref = create_vm_hashref();
    my @keys = keys %$vm_ref;
    TEMPLATE: foreach my $key ( @$template ) {
        grep { $key eq $_ } @keys
            or Die "$topology_name: $key: ",
                   "unsupported machine attribute\n";
    }

    return( report_retval() );
}

# get_full_mac(): expand a partial mac to a full mac and return it
###################################################################

sub get_full_mac { 
    report_calling_stack(@_) if $args{d};

    # split the suffix into a list of hex bytes
    ############################################

    my $suffix = shift;
    my @suffix_lst;
    @suffix_lst = ( $suffix ) unless @suffix_lst = split(/\./, $suffix);
    Die "$globals{topology_name}: invalid mac address: $suffix\n"
        unless @suffix_lst <= 6;

    # split the prefix also into a list of hex bytes
    ################################################

    my @prefix_lst = split( ':', $rc{mac_base} );

    # generate full mac from mac_base:uid:suffix
    #############################################

    my $full_mac;
    if ( @suffix_lst == 1 ) { 
        # just a 1 byte suffix
        my $uid_byte = sprintf( get_uid($rc{username}) - 990 );
        my $hex_byte = sprintf("%02x", $uid_byte); # two (hex) chars
        $full_mac = join( ':', @prefix_lst, $hex_byte, $suffix );
    } 
    else { 
        # multi-byte suffix: take what we need from the left side of mac_base
        my @full_mac_lst = @suffix_lst;
        while ( @full_mac_lst + @prefix_lst > 6 ) { pop @prefix_lst }
        unshift( @full_mac_lst, @prefix_lst );
        $full_mac = join( ':', @full_mac_lst );
    }

    return( report_retval($full_mac) );
}

# create_topology(): read in the topology file, populate hashref
#################################################################

sub create_topology { 
    report_calling_stack(@_) if $args{d};

    my( $topology_fh, $topology_name ) = @_;

    # the ports action loops over all topologies, so we need to empty this:
    @{ $globals{topology} } = (); 

    # $template[i] holds kind, corresponding value[i] holds
    my ( @values, @template );

    # populate @template
    get_topology_template( $topology_fh, $topology_name, \@template );

    # now that we have the template, populate $globals{topology}
    #############################################################

    my( $line, $continued );
    LINE: while ( <$topology_fh> ) {

        next LINE if m/^\s*$/ or m/^\s*#/;
        chomp;

        # concatenate when newlines escaped with '\'
        #############################################

        if ( $continued ) { $line .= $_ }
        else              { $line = $_  }
        if ( $line =~ s/\\\s*$// ) { 
            $continued = TRUE;
            next LINE;
        } 
        else { $continued = FALSE }

        # @values contains a list of a vm's specs:
        ###########################################

        @values = split( ' ', $line ); 

        # remaining lines contain vm specs, one per line
        #################################################

        my $vm_ref = create_vm_hashref();

        # take a line, and populate the vm hashref based on it,
        # in accordance with the template
        ########################################################

        TEMPLATE: foreach my $i ( 0 .. $#template ) {
            if ( $template[$i] eq 'memory' ) { 
                $vm_ref->{memory} = $values[$i];
                # GB or MB?
                $vm_ref->{memory} =~ s/^(\d+)([mMgG]?)$/$1/;
                $vm_ref->{memory} *= 1024 if $2 =~ m/^[gG]$/;
            } 
            elsif ( $template[$i] eq 'images' ) { 
                # multiple disk images are comma separated
                my @images = split( /,/, $values[$i] );
                create_topology_images( $topology_name, $vm_ref, \@images )
                    if @images;
            } 
            elsif (     $template[$i] ne 'display' 
                    and $template[$i] ne 'images'   ) 
            {   # then its easy:
                $vm_ref->{ $template[$i] } = $values[$i];
            } 
            else {                              # vm->{display} is hashref
                (  $vm_ref->{display}->{name}, 
                   $vm_ref->{display}->{port}, 
                   $vm_ref->{display}->{pword}, 
                ) = split /:/, $values[$i];
            }            # port and pword undefined unless display eq spice
        }

        # construct a default disk image, if not specified in template
        ###############################################################

        unless ( @{ $vm_ref->{images} } or $vm_ref->{cdrom} ) {
            $vm_ref->{images}->[0] =
                "$rc{DEFAULT_GUEST_OS}-" .
                "$globals{topology_name}-" .
                "$vm_ref->{name}-0.qcow2";
        }

        # sanity check: does $vm_ref have keys with no values?
        #######################################################

        foreach ( keys %$vm_ref ) {
            next if $_ eq 'cdrom';  # cdrom is optional
            $vm_ref->{$_} 
                // Die "$vm_ref->{name}: key '$_' undefined\n"; 
        }

        # remove all values that we processed above, from the template
        ###############################################################

        splice( @values, 0, scalar @template );

        # remaining entries in @values are nic specifications
        ######################################################

        NIC: foreach my $nic ( @values ) { # loop through the vm's nics

            # a nics properties are colon separated
            my @fields = split /:/, $nic;

            # nic specs different depending on netdev (vde, tap, udp)
            ##########################################################

            if ( $fields[0] =~ m/^vde/ ) {               # vde or vde++

                # syntax chk for vde:
                Die "$vm_ref->{name}: $nic: syntax error\n" 
                    unless @fields == 4;

                create_topology_vde( $topology_name, $vm_ref, \@fields );

            } 
            elsif ( $fields[0] eq 'tap' ) {          # tap

                # syntax chk for tap:
                Die "$vm_ref->{name}: $nic: syntax error\n" 
                    unless @fields == 4;

                create_topology_tap( $topology_name, $vm_ref, \@fields );
            } 
            else {                                   # udp (default)

                # syntax chk for udp:
                # e.g. h3,e0:fa:e0:1111:[ip]:[netdev], 
                # or, e.g., [r_port],[r_ip]:fa;e0:1111:[ip]:[netdev]
                Die "$vm_ref->{name}: $nic: too many fields\n"
                    unless @fields >= 4 and @fields <= 6;

                unshift( @fields, $globals{ipaddr} ) if @fields == 4;

                unshift( @fields, 'udp' ) if @fields == 5;

                create_topology_udp( $topology_name, $vm_ref, \@fields );
            }
        } # end NIC loop

        # add this vm to the array of vms for this topology
        ####################################################

        push @{ $globals{topology} }, $vm_ref;
    } # end LINE loop
    close $topology_fh;

    # fill in remote ip and port, now that topology has been created
    #################################################################
    # NOTE: only applicable to udp netdev
    #################################################################

    create_topology_remotes( $topology_name, $globals{topology} );

    return( report_retval() );
}

# create_topology_vde(): add vde specific values to vm hashref
###############################################################
 
sub create_topology_vde { 
    report_calling_stack(@_) if $args{d};

    # parse the arguments given to this function
    #################################################################
    # NB: $topology_name currently unused, but useful for error msgs
    #################################################################

    my( $topology_name, $vm_ref, $fields_ref ) = @_; 
    my( $netdev, $nic_name, $mac, $remote ) = @$fields_ref;
    my( $remote_host, $remote_nic ) = split /\,/, $remote;

    my $full_mac = get_full_mac( $mac );

    # directories containing vde switch and wirefilter
    #####################################################
    # NB: these two assignments below are just prefixes: 
    # we compute the tail and tack it on below
    #####################################################

    my $vde_wire = "$rc{vde_dir}/$globals{topology_name}/";
    my $wirefilter = "$rc{wirefilter_dir}/$globals{topology_name}/"
        if $netdev eq 'vde++';

    # compute the tails and pin them on to $vde_wire and $wirefilter
    #################################################################
    # NB: tail names are in alphabetical order, when tail contains
    # both ends of the wire
    #################################################################

    my @sorted = sort( "${remote_host}.${remote_nic}", 
                       "$vm_ref->{name}.${nic_name}" );

    # vde_switch and wirefilter: 
    if ( $netdev eq 'vde++' ) { 
        # e.g. h1.e0
        $vde_wire .= $vm_ref->{name} . '.' . ${nic_name}; 
        # e.g. h1.e0--rt1.e1
        $wirefilter .= $sorted[0] . '--' . $sorted[1]; 
    } 
    # just vde_switch
    elsif ( $netdev eq 'vde' ) {
        # e.g. h1.e0-rt1.e0
        $vde_wire .= "$sorted[0]" . '-' . "$sorted[1]"; 
        # no wirefilter for 'vde'
    }

    # each vm is a hash, with one value being a nic aref; 
    # each element of this aref is a hash of nic properties
    ########################################################

    my %nic_hash = ( 
        name => $nic_name, 
        mac => $full_mac, 
        remote_host => $remote_host,
        remote_nic => $remote_nic, 
        netdev => $netdev, 
        vde_wire => $vde_wire, 
    );
    $nic_hash{'wirefilter'} = $wirefilter if $netdev eq 'vde++';
    push @{ $vm_ref->{nics} }, \%nic_hash;

    return( report_retval() );
}

# create_topology_tap(): create tap specific values for vm hashref
###################################################################

sub create_topology_tap {
    report_calling_stack(@_) if $args{d};

    # parse the arguments given to this function
    #################################################################
    # NB: $topology_name currently unused, but useful for error msgs
    #################################################################

    my( $topology_name, $vm_ref, $fields_ref ) = @_;
    my( $netdev, $nic_name, $mac, $remote ) = @$fields_ref;
    my $full_mac = get_full_mac( $mac );

    push @{ $vm_ref->{nics} }, {
        name => $nic_name, mac => $full_mac, remote => $remote,
        netdev => $netdev,
    };

    return( report_retval() );
}

# create_topology_udp(): create udp sock specific values for vm hashref
########################################################################

sub create_topology_udp {

    report_calling_stack(@_) if $args{d};

    # parse the arguments given to this function
    #################################################################
    # NB: $topology_name currently unused, but useful for error msgs
    #################################################################

    my( $topology_name, $vm_ref, $fields_ref ) = @_;
    my( $netdev, $local_ip, $local_port, $nic_name, $mac, $remote ) =
        @$fields_ref;

#    # for error msgs below:
#    my $nic_line = join( ':', @$fields_ref ); 
#    my $err_prefix = "$topology_name: $nic_line: syntax error: "; 
#
#    # sanity check:
#    $netdev eq 'udp' 
#        or Die "$err_prefix: '$netdev' != 'udp'\n"; 

    $local_ip = $local_ip // get_ipaddr(); # default ip if undef
#    is_ipv4( $local_ip ) 
#        or Die "$err_prefix: '$local_ip' must be a valid ipv4 address\n";

    my $full_mac = get_full_mac( $mac );

    # getting the remote host and nic is more complex for udp socks
    ################################################################

    my( $remote_host, $remote_nic );
    if ( $remote =~ /,/ ) { 

        # comma separated: could be names or numbers
        ############################################

        my( $remote1, $remote2 ) = split /\,/, $remote;

        if ( is_ipv4($remote1) ) {
            if ( $remote2 =~ m/\d+/ ) { # looks like ip,prt pair
                ( $remote_host, $remote_nic ) = ( $remote1, $remote2 );
                if ( $args{v} or $args{d} ) {
                    Warn "$topology_name: $vm_ref->{name}: ",
                         "remote nic ($remote1,$remote2) ",
                         "specified as ip,port pair\n";
                }
            } 
            else { Die "remote1,$remote2: invalid ip,port specified\n" }
        } 
        else { ( $remote_host, $remote_nic ) = ( $remote1, $remote2 ) }

    } 
    else { 

        # not comma separated: must be a port number only
        ##################################################

        Die "$remote: invalid remote port specification\n"
            unless $remote =~ m/\d+/;
        ( $remote_host, $remote_nic ) = ( $globals{ipaddr}, $remote );
        if ( $args{d} ) {
            Warn "$topology_name: $vm_ref->{name}: ",
                 "remote nic ($remote) specified as port number\n";
        }

    }

    # add the udp socket values to the nic hashref
    ###############################################

    push @{ $vm_ref->{nics} }, {
        name => $nic_name, 
        local_ip => $local_ip,
        local_port => $local_port, 
        mac => $full_mac,
        remote_host => $remote_host, 
        remote_nic => $remote_nic, 
        netdev => $netdev,
    };

    return( report_retval() );
}

# get_remote_udp_sock(): input remote host+nic, return ip+port
###############################################################

sub get_remote_udp_sock { 
    report_calling_stack(@_) if $args{d};

    my( $local_host, $local_nic, $remote_host, $remote_nic ) = @_;
    @_ == 4
        or Die "get_remote_udp_sock() must be called with two arguments";

    my( $remote_ip, $remote_port );

    # loop through all vms, looking for $remote host 
    #################################################

    VM: foreach my $vm_ref ( @{ $globals{topology} } ) {

        next unless $vm_ref->{name} eq $remote_host;

        # found it: now find the port on this remote host that
        # we are connected to
        #######################################################

        NIC: foreach my $nic ( @{ $vm_ref->{nics} } ) {

            next NIC unless $nic->{name} eq $remote_nic;

            # remote nic is a different netdev!
            Die "nic peers: $local_host:$local_nic ", 
                "$remote_host:$remote_nic: netdev mismatch\n"
                unless $nic->{netdev} eq 'udp';

            # found the nic: return to caller
            return( report_retval($nic->{local_ip}, $nic->{local_port}) );

        } 

        # return empty list if remote not found
        return( report_retval( () ) );                 

    }

    return( report_retval() );
}

# create_topology_remotes(): udp netdevs only: infer
# the remote ip and port from remote host and nic
#####################################################

sub create_topology_remotes {      # called by create_topology()
    report_calling_stack(@_) if $args{d};

    my( $topology_name, $topology_ref ) = @_;
    VM: foreach my $vm_ref ( @$topology_ref ) {

        NIC: foreach my $nic ( @{ $vm_ref->{nics} } ) {
            # udp sockets only: 
            if ( $nic->{netdev} eq 'udp' ) {
                ( $nic->{remote_ip}, $nic->{remote_port} ) =
                    get_remote_udp_sock( $vm_ref->{name}, 
                                         $nic->{name},
                                         $nic->{remote_host}, 
                                         $nic->{remote_nic}   );
                unless ( $nic->{remote_ip} and $nic->{remote_port} ) {
                    my $msg = "$topology_name: $vm_ref->{name}: " .
                              "$nic->{name}: unverified remote\n";
#                    Die $msg;  # disabling 'force' for now
                    ( $nic->{remote_ip}, $nic->{remote_port} ) =
                        ( $nic->{remote_host}, $nic->{remote_nic} );
                }
            }

        }

    }

    return( report_retval() );
}

# create_topology_images(): add images to vm hashref
#####################################################

sub create_topology_images {       # called by create_topology()
    report_calling_stack(@_) if $args{d};

    my( $topology_name, $vm_ref, $images_aref ) = @_;
    my $size = @{ $images_aref };

    for my $i ( 0 .. ${size}-1 ) {
        $images_aref->[$i] .= 
            "-$globals{topology_name}-$vm_ref->{name}-${i}.qcow2";
        push( @{ $vm_ref->{images} }, $images_aref->[$i] );
    }

    return( report_retval() );
}

# chk_topology(): sanity chk on topology
##########################################

sub chk_topology { 
    report_calling_stack(@_) if $args{d};

    my @err_msgs;

    ########################################
    # sanity checks on topology as a whole:
    ########################################

    # check for duplicate vm names
    ###############################

    my %seen;
    foreach my $vm_ref ( @{ $globals{topology} } ) {
        next unless $seen{ $vm_ref->{name} }++;
        push @err_msgs,
            "$globals{topology_name}: duplicate vm name: $vm_ref->{name}";
    }

    # check for duplicate image names
    ##################################

    undef %seen;
    foreach my $vm_ref ( @{ $globals{topology} } ) {
        foreach my $image ( @{ $vm_ref->{images} } ) {
            next unless $seen{ $image }++;
            push @err_msgs,
                "$globals{topology_name}: duplicate vm image: $image";
        }
    }

    # check for duplicate macs, but warn only (might be intentional)
    #################################################################

    undef %seen;
    VM: foreach my $vm_ref ( @{ $globals{topology} } ) {
        NIC: foreach my $nic ( @{ $vm_ref->{nics} } ) {
            next unless $seen{ $nic->{mac} }++;
            Warn "$globals{topology_name}: ", 
                 "duplicate mac address: $nic->{mac}\n";
        }
    }

    # check for mismatching netdevs
    ################################

    my @mismatches;
    VM: foreach my $vm_ref ( @{ $globals{topology} } ) {

        LOCAL_NIC: foreach my $nic ( @{ $vm_ref->{nics} } ) { 

            # tap netdev has no remote host, so skip: 
            next if $nic->{netdev} eq 'tap'; 

            # udp with ip/port as remote skipped too: 
            next if $nic->{remote_ip} and $nic->{remote_port}; 

            $nic->{remote_host} 
                or Die "BUG: $vm_ref->{name}:$nic->{name}: no remote host\n";

            my $remote_vmref = get_vmref_by_name( $nic->{remote_host} ); 

            REMOTE_NIC: foreach my $rnic ( @{ $remote_vmref->{nics} } ) {

                # this rnic is not applicable:
                next unless $nic->{remote_nic} eq $rnic->{name}; 

                # good: netdevs match:
                next if $nic->{netdev} eq $rnic->{netdev}; 

                # avoid duplicate err msgs:
                next if grep { "$vm_ref->{name}:$nic->{name}" eq $_ } 
                             @mismatches
                     or grep { "$remote_vmref->{name}:$rnic->{name}" eq $_ }
                             @mismatches; 

                # it's a mismatch: keep a record to avoid duplicate err msgs:
                push @mismatches, "$vm_ref->{name}:$nic->{name}";

                # error msg: 
                push @err_msgs, 
                    "$globals{topology_name}: " .
                    "$vm_ref->{name}:$nic->{name}:$nic->{netdev}" .
                    "<-->" .
                    "$remote_vmref->{name}:$rnic->{name}:$rnic->{netdev} " .
                    "netdev mismatch";

            }  # REMOTE_NIC

        }      # LOCAL_NIC

    }          # VM

    # these hashes used to discover duplicate udp ports
    my( %remote_tally, %local_tally ); 

    #######################
    # individual vm checks
    #######################

    # flag: did we use udp socks?  (requires many sanity chks)
    my $use_udp = 0;

    VM: foreach my $vm_ref ( grep {defined} @{ $globals{vm_list} } ) {

        # vm name
        ##########

        # vm name too long?
        unless ( length $vm_ref->{name} < $rc{max_name_len} ) {
            push @err_msgs, "$vm_ref->{name} > $rc{max_name_len} chars";
        }
        # vm name not alphanumeric?
        unless ( $vm_ref->{name} =~ m/^[0-9a-zA-Z]+$/ ) {
            push @err_msgs, "$vm_ref->{name}: use only numbers and letters";
        }

        # vm arch
        ##########

        # legit arch?
        unless ( grep { m/^$vm_ref->{arch}$/ } @{ $rc{archs} } ) {
            push @err_msgs,
                "$vm_ref->{name}: $vm_ref->{arch}: undefined architecture";
        }

        # vm image
        ###########

        # does the image exist, is it readable, writeable?
        my @no_image_actions = qw( 
            set unset reset disks show top destroy connect cat kill start
            status stop check chk ps
        );
        foreach my $image ( @{ $vm_ref->{images} } ) {
            my $image_path = "$rc{vm_img_dir}/$image";
            unless (    grep { m/^$globals{action_name}$/ } @no_image_actions
                     or $globals{action_name} eq 'restore' and $args{m}       ) 
            {
                if ( not -e "$image_path" ) {
                    push @err_msgs, 
                         "$vm_ref->{name}: $image_path: does not exist";
                } 
                elsif ( not -r _ ) {
                    push @err_msgs, 
                         "$vm_ref->{name}: $image_path: not readable";
                } 
                elsif ( not -w _ ) {
                    push @err_msgs, 
                         "$vm_ref->{name}: $image_path: not writeable";
                }
            }
            foreach my $format ( @{ $rc{image_formats} } ) {
                unless ( $image =~ m/\.${format}$/ ) {
                    push @err_msgs,
                        "$vm_ref->{name}: $image: unsupported format";
                }
                unless ( $image =~ m/^[-0-9a-zA-Z_]+\./ ) {
                    my $msg = "$vm_ref->{name}: $image " .
                              "can contain only alphanumeric characters, " .
                              "'-', '.' and '_'";
                    push @err_msgs, $msg;
                }
            }
        }

        # vm memory
        ############

        # too much memory?  is it specified properly?
        if ( $vm_ref->{memory} =~ /^\d+$/ ) {
            if ( $vm_ref->{memory} > $rc{max_mem} ) {
                push @err_msgs,
                    "$vm_ref->{name}: max memory: $rc{max_mem} MB";
            }
        } 
        else {
            my $msg = 
                "$vm_ref->{name}: $vm_ref->{memory}: ".
                "invalid memory specified";
            push @err_msgs, $msg;
                
        }

        # display
        ##########

        # legit display specified?
        unless ( grep { m/^$vm_ref->{display}->{name}$/ } 
                      @{$rc{displays}}                    ) 
        {
            local $, = ' ';  # list separator
            push @err_msgs, 
                "$vm_ref->{name}: display must be one of: @{ $rc{displays} }";
        }
        # various checks when display uses spice protocol
        if ( $vm_ref->{display}->{name} eq 'spice' ) {
#            if ( keys( %{$vm_ref->{display}} ) != 6 ) {
#                push @err_msgs,
#                    "$vm_ref->{name}: spice: syntax: spice:<port>:<pword>";
#            } 
#            elsif ( $vm_ref->{display}->{port} < $rc{spice_port_min}  or
#
            if ( $vm_ref->{display}->{port} < $rc{spice_port_min}  or
                    $vm_ref->{display}->{port} > $rc{spice_port_max}
            ) {
                push @err_msgs, "$vm_ref->{name}: spice port " .
                    "$vm_ref->{display}->{port} out of range";
            }
        }

        # nic driver
        #############

        unless ( grep { m/^$vm_ref->{driver}$/ } @{$rc{nic_drivers}} ) {
            local $, = ' ';  # list separator
            push @err_msgs,
                "$vm_ref->{name}: driver must be: @{ $rc{nic_drivers} }";
        }

        # stopping the vms
        ###################

        my @stop_methods = qw( powerdown quit );
        unless ( grep { $_ eq $vm_ref->{powerd} } @stop_methods ) {
            local $, = ' ';  # list separator
            push @err_msgs, "$vm_ref->{name}: powerd must be: @stop_methods";
        }

        # per vm nic checks
        ####################

        # too many nics?
        unless ( @{ $vm_ref->{nics} } <= $rc{max_nics} ) {  # qemu nic limit
            my $msg = "$vm_ref->{name}: " .
                      "number of nics cannot be greater than $rc{max_nics}";
            push @err_msgs, $msg;
        }

        # individual nic checks
        ########################

        # cycle through the vm's nics, doing a couple of checks...
        NIC: foreach my $nic ( @{ $vm_ref->{nics} } ) {

            # mac suffix in range?
            unless ( $nic->{mac} =~ /[0-9a-f][0-9a-f]$/ ) {
                push @err_msgs,
                        "$vm_ref->{name}: " .
                        "mac suffix must range between 01 and ff";
            }

            if ( $nic->{netdev} eq 'tap' ) {                # tap 
                my $cmd = "$rc{ifconfig} " . 
                          "$nic->{remote} " . 
                          ">/dev/null " .
                          " 2>> $rc{log_file}";
                my_system( $cmd );
                unless ( $? == 0 ) { 
                    my $msg = "$vm_ref->{name}: " . 
                              "stat on iface $nic->{remote} failed: " .
                              "system() exited with: $?";
                    if ( $args{n} ) { Warn "$msg" }
                    else            { push @err_msgs, $msg }
                }
            } 
            elsif ( $nic->{netdev} =~ m/^vde/ ) {           # vde or vde++
                unless ( defined($rc{vde_switch}) ) {
                    push @err_msgs, 
                        "$vm_ref->{name}: ".
                        "vde unsupported: cannot find vde_switch\n";
                }
            } 
            elsif ( $nic->{netdev} eq 'udp' ) {             # udp socks 
                $use_udp++;
                unless ( defined $nic->{local_port} ) { # why BUG?
                    push @err_msgs, 
                        "BUG: $globals{topology_name}: $vm_ref->{name}: " .
                        "undefined local port for $nic->{name}";
                }
                unless ( defined $nic->{remote_port} ) {
                    my $err =
                        "$globals{topology_name}: " . 
                        "$vm_ref->{name}:$nic->{name}: " .
                        "remote port: " .
                        "$nic->{remote_host}:$nic->{remote_nic} " .
                        "does not exist";
                    push @err_msgs, $err;
                }
                { no warnings;     # abs() complains if $port isn't numeric
                  foreach my $port ( $nic->{local_port}, 
                                     $nic->{remote_port} ) 
                  {
                      unless ( abs($port) == $port and 
                               int($port) == $port and
                               $port > 0           and 
                               $port < 65536            ) {
                          Die "$vm_ref->{name}: $port: syntax error: ", 
                              "not a tcp port\n";
                      }
                  }
                }
                if ( defined $nic->{local_ip} ) {
                    unless ( is_ipv4($nic->{local_ip}) ) {
                        push @err_msgs,
                            "$vm_ref->{name}: local ip '$nic->{local_ip}' " .
                            "is not an IP address";
                    }
                } 
                else {
                    my $msg = "$vm_ref->{name}: $nic->{name}: " .
                               "undefined local ip (BUG?)";
                    push @err_msgs, $msg;
                }
                if ( defined $nic->{remote_ip} ) {
                    unless ( is_ipv4($nic->{remote_ip}) ) {
                        push @err_msgs,
                            "$vm_ref->{name}: remote ip '$nic->{remote_ip}' " .
                            "is not an IP address " .
                            "(syntax error for $nic->{remote_host}:$nic->{remote_nic}?)";
                    }
                } 
                else {
                    my $msg = "$vm_ref->{name}: $nic->{name}: " .
                              "undefined remote ip (BUG?)";
                    push @err_msgs, $msg;
                        
                }
            
                # nic socket ports in range?
                if (     defined $nic->{local_port}
                     and defined $nic->{remote_port}
                ) {
                    if ( $nic->{local_port} < $rc{sock_port_min}  ||  
                         $nic->{local_port} > $rc{sock_port_max}  or
                         $nic->{remote_port} < $rc{sock_port_min} ||  
                         $nic->{remote_port} > $rc{sock_port_max} 
                   ) 
                    {
                        push @err_msgs, 
                            "$vm_ref->{name}: sock ports " . 
                            "$nic->{local_port} and $nic->{remote_port} " .
                            "must range between " .
                            "$rc{sock_port_min} and $rc{sock_port_max}";
                    }
                }
                # need to tally for other checks below ...
                $remote_tally{ "$nic->{remote_ip}:$nic->{remote_port}" }++
                    if defined $nic->{remote_ip} and 
                       defined $nic->{remote_port};
                $local_tally{ "$nic->{local_ip}:$nic->{local_port}" }++
                    if defined $nic->{local_ip} and 
                       defined $nic->{local_port};
            } 
            else {
                push @err_msgs,
                     "$vm_ref->{name}: $nic->{netdev}: unsupported netdev";
            }
        }
    }

    # udp socket checks
    ####################

    if ( $use_udp ) { 

        # collective nic (all nics on all vms) sanity checks
        #####################################################

        # two jacks in one nic port?
        REMOTE: foreach my $remote ( keys %remote_tally ) {
            push @err_msgs,   "$globals{topology_name}: "
                            . "duplicate remote address: $remote "
                            . "(two jacks, one nic!)"
                if $remote_tally{$remote} > 1;
        }

        # one jack in two nic ports?
        LOCAL: foreach my $local ( keys %local_tally ) {
            push @err_msgs,   "$globals{topology_name}: "
                            . "duplicate local address: $local "
                            . "(one jack, two nics!)"
                if $local_tally{$local} > 1;
        }
    }

    my $retval = @err_msgs ? \@err_msgs : FALSE;

    return( report_retval($retval) );
}

# get_vmref_by_name(): given a vm name, return its hashref
###########################################################

sub get_vmref_by_name {
    report_calling_stack(@_) if $args{d};

    my $vm_name = shift or Die "get_vmref_by_name(): no parameter\n";

    # loop through all vms in topology, looking for one with this name
    foreach my $vm_ref ( @{ $globals{topology} } ) {
            return( report_retval($vm_ref) ) 
                if $vm_ref->{name} eq $vm_name;
    }

    # if we're here, the vm wasn't found, and there's a bug in vinetctl:
    Die "BUG: get_vmref_by_name failed with $vm_name as parameter\n";
}

1;
