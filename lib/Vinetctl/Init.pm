package Vinetctl::Init;

use strict;
use warnings;
use feature qw( say );
use File::Basename;
use File::Copy qw( copy );
use Data::Validate::IP qw( is_ipv4 );

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
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    get_rc
    chk_external_prog_dependencies
    log_cmdline
    get_ipaddr
    get_topology_owner
    get_topology_name
    chk_options
    clean_action_params
    copy_topology_file
    get_action_name
    get_vm_list
);

# get_rc(): set many run config variables, all in global %rc
#############################################################

sub get_rc { 
    report_calling_stack(@_) if $args{d};

    my $rc_href = shift;

    %$rc_href = (

        # maximums and minimums
        ########################

        max_dups          =>   9,       # max duplicate sessions
        min_uid           =>   1000,    # min user id value
        max_name_len      =>   5,       # max vm name len
        max_mem           =>   4096,    # max memory per vm
        max_nics          =>   8,       # qemu max nics
        max_vm_saves      =>   3,       # max number of memory saves

        # range of ports for ethernet wires (udp socks)
        sock_port_min     =>   1025,
        sock_port_max     =>   3100,

        # range of ports for spice
        spice_port_min    =>   5901,
        spice_port_max    =>   6901,


        # use UID to get unique last/2nd-last byte for ipaddrs/macs, to avoid
        # conflicts between different users on same host; uniq if <=255 users
        ######################################################################

        ip_prefix         =>   '127.0.',
        mac_base          =>   '52:54:00:12:',


        # directories
        ##############

        user_dir          =>   '.vinet',
        system_dir        =>   '/etc/vinet',
        base_img_dir      =>   '/var/vinet/images',
        tmux_sock_dir     =>   '/tmp',


        # some defaults
        ################
        DEFAULT_GUEST_OS  =>   'obsd63',
        vm_screen_width   =>   80,
        vm_screen_height  =>   25,


        # qemu defaults for vinetctl
        #############################

        kvm               =>   $^O eq 'linux' ? 'yes' : 'no',
        image_formats     =>   [ qw( qcow2 ) ],
        displays          =>   [ qw( curses nographic spice ) ],
        nic_drivers       =>   [ qw( virtio none ) ],
        archs             =>   [ ], # chk_exernal_progs_exist() fills this


        # external programs
        ####################

        qemu_64           =>   -e '/usr/local/bin/qemu-system-x86_64' ?
                               '/usr/local/bin/qemu-system-x86_64' :
                               '/usr/bin/qemu-system-x86_64',

        qemu_i386         =>   -e '/usr/local/bin/qemu-system-i386' ?
                               '/usr/local/bin/qemu-system-i386' :
                               '/usr/bin/qemu-system-i386',

        qemu_img          =>   -e '/usr/local/bin/qemu-img' ?
                               '/usr/local/bin/qemu-img' :
                               '/usr/bin/qemu-img',

        ifconfig          =>   '/sbin/ifconfig',

        lsof              =>   -e '/usr/local/sbin/lsof' ?
                               '/usr/local/sbin/lsof' :
                               -e '/usr/bin/lsof' ?
                               '/usr/bin/lsof' :
                               '/usr/sbin/lsof',

        fuser             =>   -e '/usr/bin/fuser' ?
                               '/usr/bin/fuser' :
                               '/bin/fuser',

        tmux              =>   -e '/usr/bin/tmux' ?
                               '/usr/bin/tmux' : 
                               '/usr/local/bin/tmux',

        top               =>   '/usr/bin/top',

        ps                =>   '/bin/ps',

        rsync             =>   -e '/usr/local/bin/rsync' ?
                               '/usr/local/bin/rsync' :
                               '/usr/bin/rsync', 

        rsync_options     =>   '--archive --compress',

        netstat           =>   -e '/usr/bin/netstat' ?
                               '/usr/bin/netstat' :
                               '/bin/netstat',

        backup_host       =>   '199.185.121.158',

        backup_port       =>   '6767',

        migrate_host      =>   '199.185.121.158',

        grant_type        =>   'acls',

        username          =>   $ENV{LOGNAME} || $ENV{USER} || getpwuid($<),

        progname          =>   basename("$0"),

        getfacl           =>   -e '/usr/bin/getfacl' ?
                               '/usr/bin/getfacl' :
                               '/usr/sbin/getfacl',

        setfacl           =>   -e '/usr/bin/setfacl' ?
                               '/usr/bin/setfacl' :
                               '/usr/sbin/setfacl',

        vde_switch        =>   -e '/usr/local/bin/vde_switch' ?
                               '/usr/local/bin/vde_switch' :
                               '/usr/bin/vde_switch',

        wirefilter        =>   -e '/usr/local/bin/wirefilter' ?
                               '/usr/local/bin/wirefilter' :
                               '/usr/bin/wirefilter',

        unixterm          =>   -e '/usr/local/bin/unixterm' ?
                               '/usr/local/bin/unixterm' : 
                               '/usr/bin/unixterm',


        socat             =>   -e '/usr/local/bin/socat' ?
                               '/usr/local/bin/socat' : 
                               '/usr/bin/socat',

        ssh               =>   '/usr/bin/ssh', 

        mg                =>   -e '/usr/local/bin/mg' ?
                                  '/usr/local/bin/mg' :
                                  '/usr/bin/mg',

        vi                =>   -e '/usr/local/bin/vi' ?
                                  '/usr/local/bin/vi' :
                                  '/usr/bin/vi',

    );

    # here we continue to populate %rc, but based on previous values
    #################################################################

    # all tmux sockets prefixed with 'vinetctl-<ruid>' (real uid)
    $rc_href->{tmux_sock_prefix}   = 
        "$rc_href->{tmux_sock_dir}/$rc_href->{progname}-$<", 

    # where we keep private base vm disk images
    $rc_href->{priv_base_img_dir}  =
        "$ENV{HOME}/$rc_href->{user_dir}/base_images", 

    # where we keep vm disk images
    $rc_href->{vm_img_dir}         =
        "$ENV{HOME}/$rc_href->{user_dir}/images";

    # tmux config file
    $rc_href->{tmux_conf}          =
        "$rc_href->{system_dir}/tmux-vinetctl.conf";

    # log file
    $rc_href->{log_file}           =
        "$ENV{HOME}/$rc_href->{user_dir}/log";

    # where we keep global topology files
    $rc_href->{topology_base_dir}  =
        "$rc_href->{system_dir}/topologies";

    # override this configuration
    $rc_href->{vinet_conf}  =
        "$rc_href->{system_dir}/vinetrc";

    # where we keep user specific topology related files
    #####################################################

    $rc_href->{topology_dir}            =         # topology files
        "$ENV{HOME}/$rc_href->{user_dir}/topologies";

    $rc_href->{pid_dir}                 =         # qemu pids
        "$ENV{HOME}/$rc_href->{user_dir}/.pids";

    $rc_href->{default_top_file}        =         # default topology file
        "$ENV{HOME}/$rc_href->{user_dir}/default_topology";

    $rc_href->{default_user_file}       =         # default userid
        "$ENV{HOME}/$rc_href->{user_dir}/default_user";

    $rc_href->{default_ipaddr_file}     =         # default IP address
        "$ENV{HOME}/$rc_href->{user_dir}/default_ipaddr";

    $rc_href->{socket_dir}              =         # qemu sockets for monitor
        "$ENV{HOME}/$rc_href->{user_dir}/.sockets";

    $rc_href->{vde_dir}                 =         # vde sockets
        "$ENV{HOME}/$rc_href->{user_dir}/.vde";

    $rc_href->{wirefilter_dir}          =         # wirefilter mgmt sockets
        "$ENV{HOME}/$rc_href->{user_dir}/.wirefilter";

    $rc_href->{history_dir}             =         # qemu cmdline history (-e)
        "$ENV{HOME}/$rc_href->{user_dir}/.history";

    $rc_href->{autostart_base_dir}      =         # qemu autostart cmdlines
        "$ENV{HOME}/$rc_href->{user_dir}/.autostart";

    $rc_href->{stderr_dir}              =         # qemu stderr stored here
        "$ENV{HOME}/$rc_href->{user_dir}/.stderr";

    $rc_href->{migrate_in_dir}          =         # migrate files for import
        "$ENV{HOME}/$rc_href->{user_dir}/.migrate_in";

    $rc_href->{migrate_out_dir}          =        # migrate files for export
        "$ENV{HOME}/$rc_href->{user_dir}/.migrate_out";


    # see if we need to disable acceleration
    #########################################

    if ( $^O eq 'linux' ) { 

        unless ( -w '/dev/kvm' ) { 
            $rc_href->{kvm} = 'no'; 
            $rc_href->{kvm_err} = '/dev/kvm not writable' 
        }

        my ($gname, $gpwd, $gid, $members);
        # find the kvm group entry
        while ( ($gname, $gpwd, $gid, $members) = getgrent() ) {
            last if $gname eq 'kvm';
        }
        unless ( defined $gname and $gname eq 'kvm' ) {
            $rc_href->{kvm} = 'no'; 
            $rc_href->{kvm_err} = 'no kvm group' 
                unless defined $rc_href->{kvm_err}; 
        }
        else { # kvm group found; are we in it?
            my @member_list = split( /\s+/, $members ); 
            unless ( grep { /^$rc_href->{username}$/ } @member_list ) { 
                $rc_href->{kvm} = 'no'; 
            $rc_href->{kvm_err} = 'kvm group exists, but you are not in it' 
                unless defined $rc_href->{kvm_err}; 
            }
                
        }
    } 
    else { 
        $rc_href->{kvm} = 'no'; 
        $rc_href->{kvm_err} = 'kvm not supported on this operating system'
     }

    # open rc file, read in values to override defaults
    my @vinetrc = ( $rc_href->{vinet_conf}, "$ENV{HOME}/.vinetrc" );

    # check for valid variables when reading in from vinetrc
    #########################################################

    # if it isn't there, use builtin defaults
    foreach my $vinetrc ( @vinetrc ) {

        unless ( -e $vinetrc ) { 
            warn "DEBUG: $vinetrc doesn't exist\n" if $args{d}; 
            next; 
        }

        open( my $fh, '<', $vinetrc ) 
            or Die "cannot open $vinetrc: $!\n";

        while( <$fh> )  {  # lines from $fh are of form: 'x=y'

            # ignore blanks and comments:
            next if m/^\s*$|^\s*#/; 

            # snip comments at the end of the line:
            s/(.*)#.*/$1/; 

            # get rid of white space: 
            s/\s+//g; 

            my ( $key, $val ) = split(/=/);

            # does this key exist?
            Warn "$vinetrc: ${key}: unknown key\n"
                unless grep { /$key/ } keys %rc;

            # did that split() work out?
            $key // $val // Die "$vinetrc: syntax error: $_"; 

            if ( ref($rc_href->{$key}) eq 'ARRAY' ) {
                Die "$vinetrc: $key: unsupported config option\n"; 
            }
            else { $rc_href->{$key} = $val } # just a scalar

        }

        close $fh;
    } 

    return( report_retval() );
}

# chk_external_prog_dependencies(): various progs must exist and be exec-able
##############################################################################

sub chk_external_prog_dependencies { 
    report_calling_stack(@_) if $args{d};

    # %progs: progname => full_path
    ################################

    my %progs = (
        lsof       => $rc{lsof},
        tmux       => $rc{tmux},
        qemu_img   => $rc{qemu_img},
        fuser      => $rc{fuser},
        ps         => $rc{ps},
        netstat    => $rc{netstat},
        ifconfig   => $rc{ifconfig},
        qemu_i386  => $rc{qemu_i386},
        qemu_64    => $rc{qemu_64},
        vde_switch => $rc{vde_switch},
    );

    # special checks for certain programs
    ######################################

    # what architectures do we support? 
    -e $rc{qemu_i386} and push @{ $rc{archs} }, 'i386';
    delete $progs{qemu_i386};
    -e $rc{qemu_64} and push @{ $rc{archs} }, 'x86_64';
    delete $progs{qemu_64};

    @{ $rc{archs} } or Die "no $rc{qemu_i386} or $rc{qemu_64}\n";

    # need either lsof or netstat
    -e $rc{lsof} or -e $rc{netstat}
        or Die "neither $rc{lsof} nor $rc{netstat} exist\n";
    delete $progs{lsof};
    delete $progs{netstat};

    # undef $rc{vde_switch} so that chk_topology_vde() can see if defined
    -e $rc{vde_switch} or undef $rc{vde_switch};
    delete $progs{vde_switch};

    # for the rest, make sure they exist and are executable
    ########################################################

    my @missing_progs;
    my @unexecutable_progs;
    foreach my $p ( keys %progs ) { 
        if ( not -e $progs{$p} ) { push @missing_progs, $progs{$p} }
        elsif ( not -x _ ) { push @unexecutable_progs, $progs{$p} }
    }
    Die "cannot execute:\n", join("\n", @missing_progs)
        if @missing_progs;
    Die "not executable:\n", join("\n", @unexecutable_progs)
        if @unexecutable_progs;
    
    return( report_retval() );
}

# get_topology_owner(): returns topology owner
###############################################

sub get_topology_owner { 
    report_calling_stack(@_) if $args{d};

    my $topology_owner;

    # there are various ways to get the topology owner
    ###################################################

    if ( $args{u} ) { 
        # owner specified explicitly on cmdline
        $topology_owner = $args{u} 
    } 
    elsif ( -e "$rc{default_user_file}" and not -z _ ) { 
        # owner retrieved from file 
        open( my $fh, '<', "$rc{default_user_file}" )
            or  Die "cannot open $rc{default_user_file}: $!\n";
        chomp( my $default_user = <$fh> );
        close $fh;
        unless (   $globals{action_name} =~ m/^(un)?set/
                or $default_user eq $rc{username}         ) 
        {
            Warn "you are running as user: $default_user\n";
            sleep 1;
        }
        $topology_owner = $default_user;
    } 
    else { 
        # owner defaults to unix username:
        $topology_owner = $rc{username}; 
    } 

    return( report_retval($topology_owner) );
}

# get_ipaddr(): returns default ipaddr used for udp socks and backup action
############################################################################

sub get_ipaddr {
    report_calling_stack(@_) if $args{d};

    my $ipaddr; 

    # there are various ways to get the ipaddr
    ###########################################

    if ( $args{i} ) { 
        # ipaddr specified on cmdline 
        is_ipv4( $args{i} ) 
            or Die "command line specified address: ", 
                   "$args{i}: not an IP address\n";
        $ipaddr = $args{i};
    } 
    elsif ( -e "$rc{default_ipaddr_file}" and not -z _ ) { 
        # ipaddr retrieved from file 
        open( my $fh, '<', "$rc{default_ipaddr_file}" )
            or  Die "cannot open $rc{default_ipaddr_file}: $!\n";
        chomp( $ipaddr = <$fh> );
        close $fh;
        is_ipv4( $ipaddr )
            or Die "IP address from file: ", 
                   "$ipaddr: not an IP address\n";
    } 
    else { 
        # use default ipaddr 
        $ipaddr = get_rc_ipaddr();
        is_ipv4( $ipaddr ) 
            or Die "$ipaddr: rc ipaddr not an IP address\n";
    }

    return( report_retval($ipaddr) );
}

# get_topology_name(): returns topology name being acted on
############################################################

sub get_topology_name {
    report_calling_stack(@_) if $args{d};

    my $topology_name;

    # there are various ways to get the topology name
    ##################################################

    if ( $args{f} ) { 
        # topology specified on cmdline 
        $topology_name = $args{f} 
    }
    elsif ( -e "$rc{default_top_file}" and not -z _ ) { 
        # topology retrieved from file 
        open( my $fh, '<', "$rc{default_top_file}" )
            or  Die "cannot open $rc{default_top_file}: $!\n";
        chomp( $topology_name = <$fh> );
        close $fh;
    } 
    elsif ( $globals{dialog_loop} ) {
        # if none set, set to default
        $topology_name = 'default'; 
    }
    else { 
        # error: topology is mandatory 
        Die "no topology specified or set\n" 
    }

    return( report_retval($topology_name) );
}

# chk_options(): sanity chk on combos of options (switches) and action
#######################################################################

sub chk_options {
    report_calling_stack(@_) if $args{d};

    # TODO: options are allowed when using Dialog (-D), and the checks
    # only happen in the middle; need to fix this

    # map an option to the actions that permit it
    #############################################

    my %opt2actions = (
        s => [ qw( start restore ) ],
        t => [ qw( start restore ) ],
        e => [ qw( start restore ) ],
        I => [ qw( restore ) ],
        p => [ qw( all ) ],
        r => [ qw( connect ) ],
        n => [ qw( start restore disks backup rmcable destroy ) ],
        u => [ qw( connect list ls disconnect set running ) ],
        i => [ qw( start restore ) ],
        F => [ qw( destroy kill disks backup rmcable undup migrate ) ],
        a => [ qw( connect ) ], 
        m => [ qw( restore save ) ], 
        b => [ qw( disks ) ], 
    );

    #  special case: with -u, 'unset' action is permitted only with one's 

    $globals{top_owner} eq $rc{username}
        or grep { /^$globals{action_name}$/ } ( @{$opt2actions{u}}, 'unset' )
            or Die "specify another user only with: ", 
                    @{$opt2actions{u}}, "\n";

    # die when options are invalid for specified action
    ####################################################

    foreach my $opt ( keys %opt2actions ) {
        next if $opt eq 'u';                      # this case covered above
        next unless $args{$opt};
        grep { $_ eq $globals{action_name} } @{$opt2actions{$opt}}
            or Die "-${opt} valid only with:", @{$opt2actions{$opt}}, "\n";
    }

    return( report_retval() );
}

# clean_action_params(): return list of machines specified on cmdline
######################################################################

######################################################################
# NOTE: the cmdline params may, for certain actions, be in a strange
# form; this function extracts the vms specified on command line from
# that potentially strange form (e.g. get 'h1' from 'h1.e0')
######################################################################

sub clean_action_params {
    report_calling_stack(@_) if $args{d};

    # sometimes params it isn't just a list of machines, but something
    # more complicated
    ###################################################################

    my @dirty_params = @_;    # what we get
    my @clean_params;         # what we return

    # so far, the actions 'rmcable', 'monitor', 'dup' and 'undup'
    # have params that need cleaning
    ##############################################################

    if ( $globals{action_name} eq 'rmcable' ) { 
        # of the form 'vm:nic'; snip off nic names to get vm list
        $globals{rmcable_params} = \@dirty_params;          # save orig for rmcable
        foreach my $param ( @dirty_params ) {     # should only be one
            @clean_params =
                map { /:/ ? ( split(/:/, $param) )[0] : $_ } 
                    @dirty_params;
        }
    } 
    elsif ( $globals{action_name} eq 'monitor' ) { 
        # of the form vm.<something>; snip off <something>
        $globals{monitor_params} = \@dirty_params;
        foreach my $param ( @dirty_params ) {
            @clean_params = 
                map { /\./ ? ( split(/\./, $param) )[0] : $_ } 
                    @dirty_params;
        }
    } 
    elsif (    $globals{action_name} eq 'dup' 
            or $globals{action_name} eq 'undup' ) 
    { 
        # dup params unrelated to vms in topology, 
        # so @clean_params should be empty
        $globals{dup_params} = \@dirty_params; 
        @clean_params = ();
    }
    else { 
        # already clean: do nothing
        @clean_params = @dirty_params 
    } 

    return( report_retval(@clean_params) );
}

# get_rc_ipaddr(): construct ip as a function of rc ip prefix and userid
#########################################################################

sub get_rc_ipaddr { 

    report_calling_stack(@_) if $args{d};

    my $dotted_byte;
    my $byte = sprintf( get_uid($rc{username}) - 990 );
    # make it two (hex) chars: 
    my $hex_byte = sprintf("%02x", $byte); 

    if ( $byte < 256 ) { $dotted_byte = "0.$byte" }
    else { $dotted_byte = join '.', unpack "C*", pack "H*", $hex_byte }

    return( report_retval("$rc{ip_prefix}${dotted_byte}") ); 
}

# copy_topology_file(): copy topology file from base dir to home dir
#####################################################################

sub copy_topology_file {
    report_calling_stack(@_) if $args{d};

    # topology must be specified
    $globals{topology_name} // Die "no default topology: use -f\n";

    my $user = "$rc{topology_dir}/$globals{topology_name}";
    my $base = "$rc{topology_base_dir}/$globals{topology_name}";

    # topology file must exist
    unless ( -e $user ) {
        -e $base and copy( $base, $user ) 
            or Die "topology '$globals{topology_name}': cannot copy: $!\n"; 
        say STDERR "DEBUG: $base copied to $user" 
            if $args{d};
    }

    -r $user 
        or  Die "topology file $globals{topology_name} is not readable";

    return( report_retval() ); 
}

# get_vm_list(): returns a list of vms the user wants to operate on
####################################################################

sub get_vm_list { 
    report_calling_stack(@_) if $args{d};

    # make sure vms specified on cmdline exist
    ###########################################

    my @some = @_;                           # those specified on cmdline
    my @all  =                               # all possible vms
        map { $_->{name} } @{ $globals{topology} }; 
    my @vm_list;

    # die if user specified vms that don't exist in the topology
    #############################################################

    my @unreal;
    { 
        no warnings 'experimental';  # '~~' is experimental
        foreach ( @some ) { 
            push @unreal, $_ unless ( $_ ~~ @all );
        }
    }
    # die if the user specified nonexistant vms
    ############################################

    Die join( ' ', @unreal ), "not in $globals{topology_name}\n" 
        if @unreal;

    # populate @vm_list with the cmdline specified vms
    ###################################################

    foreach my $vm_ref ( @{ $globals{topology} } ) { 

        # if a vm is not specified, 
        # we set that array element to undef
        #####################################

        push @vm_list, 
            ( grep { /^$vm_ref->{name}$/ } @some ) ? $vm_ref : undef;

    }

    return( \@vm_list );
}

# get_action_name(): return full action name from possible abbrevation
#######################################################################

sub get_action_name { 
    report_calling_stack(@_) if $args{d};

    my $try = shift;     # what was specified on cmdline
    $try // Die "$rc{progname}: no action specified:", 
                "-h for help or -D for menu\n";
    my @actions = @_;

    # is there a unique match for the abbreviation?
    ################################################

    my @matches = grep { /^$try/ } @actions; # any matches?

    if ( @matches == 0 ) { 
        Die "$try: no such action\n";
    } 
    elsif ( @matches >  1 ) {      # ambiguous
        Die "$try ambigious:", join(' ', @matches), "\n";
    } 
    else { return( report_retval($matches[0]) ) }
}

1;
