package Vinetctl::StartRestoreAction;

use strict;
use warnings;
use feature qw( say );
use IO::Socket::UNIX qw( SOCK_STREAM );
use File::Basename;
use constant { TRUE => 1, FALSE => 0 };
use UI::Dialog::Backend::CDialog;
use File::Path qw( remove_tree );

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
    my_system
    get_uniq
);

use Vinetctl::Tmux qw( 
    tmux_has_session
    tmux_new_session
    tmux_cmd
);

use Vinetctl::DisksAction qw(
    disks_action
);

use Vinetctl::StatusAction qw(
    get_vm_status
    vm_save_status
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    start_restore_action
    vm_cmdline
    start_vm
);

# start_restore_action(): start or restore some or all vms in a topology
#########################################################################

sub start_restore_action {
    report_calling_stack(@_) if $args{d};

    # for udp netdev, ipaddrs must be reachable:
    ping_topology() unless $args{n}; 

    # -s saves the cmdlines created with -ne (pretend/edit), 
    # while -s grabs cmdlines from file
    Die "-s -e requires -n\n" 
        if $args{s} and $args{e} and not $args{n};

    # create the qemu cmdlines; varies depending on 'start' vs 'restore'
    #####################################################################

    my $cmdlines;

    if ( $args{s} and not $args{e} ) { 
        # -s set without -e, so grab cmdlines from .autostart dir
        $cmdlines = construct_cmdlines_from_file();
    } 
    else { 
        # regular start: construct cmdlines from scratch:
        $cmdlines = construct_cmdlines( $globals{action_name}, 
                                        $globals{topology_name} );
        # -e (without -s) specified; user can revise the constructed cmdlines:
        edit_cmdlines( $cmdlines ) if $args{e};
    }

    # for 'restore' action, modify cmdlines as appropriate
    #######################################################

    if ( $globals{action_name} eq 'restore' ) {           

        # die if there are unrestorable vms:
        my $unrestorable_vms = get_unrestorable_vms();
        Die "unrestorable machines:", join(' ', @$unrestorable_vms), "\n"
            if @$unrestorable_vms;

        # cmdline modification depends on switches: 
        if ( $args{m} ) { 
            # restore from migrate file via -incoming
            do_migrate_in ( $cmdlines ) 
        } 
        elsif ( $args{I} ) { 
            # interactive restore from mem save
            choose_restore( $cmdlines ) 
        } 
        else { 
            # non-interactive restore from mem save
            do_auto_restore( $cmdlines ) 
        }    

    } 

    # auto-create disk images if necessary, when starting or restoring
    # after migration.  Do this before we create tmux session in case 
    # disks_action() dies
    ###################################################################

    if ( $globals{action_name} eq 'start' or $args{m} ) { 

        my @images;

        foreach my $vm_ref ( grep {defined} @{ $globals{vm_list} } ) {
            foreach my $image ( @{ $vm_ref->{images} } ) {
                push( @images, $image )
                    unless -e "$rc{vm_img_dir}/$image"
            }
        }

        if ( @images and not $args{n} ) {
            print "auto-disks: ", $args{v} ? "\n" : "";
            # just in case disks_action() fails:
            select()->flush(); 
            disks_action();
        }

    }

    # start the tmux session if it doesn't exist:
    ##############################################
    unless ( $args{n} ) {
        tmux_has_session( "$rc{tmux_sock_prefix}-$globals{topology_name}",
                           $globals{topology_name} )

                                 or 

        tmux_new_session( "$rc{tmux_sock_prefix}-$globals{topology_name}", 
                           $globals{topology_name}, undef );
    }

    # print the header
    ###################

    if ( $args{n} ) { 
        print "\n$globals{topology_name}:\n", 
              '-' x length($globals{topology_name}), 
              "\n\n";
    }
    else {
        print "$globals{topology_name}: ", 
        $args{v} ? "\n" . '-' x length($globals{topology_name}) . "\n"
                 : "";
    }

    # start/restore the vms, loading them into the tmux windows:
    #############################################################

    my @failed_vms;                # array of machines that failed to start
    my $ok = 0;                    # flag
    my $dialog;

    if ( $globals{dialog_loop} ) {
        $dialog = new UI::Dialog::Backend::CDialog (
            backtitle => 'Vinetctl',
            title => 'Progress bar',
            height => 8,
            width => 40,
            order => [ 'CDialog', 'Whiptail' ],
        );
        $dialog->gauge_start( 
            text => "Starting $globals{topology_name}...", 
            percentage => 0 
        );
    }
    my @vm_list = @{ $globals{vm_list} };
    my $increment = int( 100 / ($#{vm_list} + 1) );

    VM: for my $i ( 0 .. $#{vm_list} ) {

        if ( $globals{dialog_loop} ) {
            $dialog->gauge_inc( $increment )
                or Die "CDialog: gauge_inc() failed: $!\n";
        }

        next VM unless defined $vm_list[$i]; 

        my $retval = start_vm( $vm_list[$i], $cmdlines->[$i] );

        if ( $retval == 1 ) {           # vm started
            $ok++ 
        } 
        elsif ( $retval == -1 ) {       # vm failed
            push( @failed_vms, $vm_list[$i]->{name} ) 
        } 
        elsif ( $retval = 2 ) {         # vm already up
            # nothing
        } 
        elsif ( $retval == 0 ) {        # -n
            # nothing
        }

    }

    if ( $globals{dialog_loop} ) {
        $dialog->gauge_stop()
            or Die "CDialog: gauge_stop() failed: $!\n";
    }

    # kill the 0th window
    tmux_cmd( "$rc{tmux_sock_prefix}-$globals{topology_name}",
              "$globals{topology_name}:0",
              'kill-window'                                     );

    # make first window active iff no vms specified
    tmux_cmd( "$rc{tmux_sock_prefix}-$globals{topology_name}",
              "$globals{topology_name}:1",
              'select-window'
    ) if ( grep {defined} @vm_list == @{ $globals{topology} } );

    # report results
    #################

#    if ( $ok )  { say "ok" }
#    else        { say "" } 

    say $ok ? "ok" : "";

    # report failed vms
    foreach my $failed ( @failed_vms ) {
        print "\n$failed stderr: ";
        my $stderr_file = 
            "$rc{stderr_dir}/$globals{topology_name}/$failed";
        if ( -s $stderr_file ) {
            open( my $fh, '<', $stderr_file ) 
                or Die "cannot open $stderr_file: $!\n";
            print "\n";
            print while <$fh>;
            print "\n";
        } 
        else { print "NONE\n" }
    }

    return( report_retval() );
}

# start_vm(): start a machine, given a vm and cmdline as arguments
###################################################################

sub start_vm {
    report_calling_stack(@_) if $args{d};

    my( $vm_ref, $cmdline ) = @_;

    if ( $args{n} ) { 

        # pretend mode: just print the cmdline:
        ########################################

        print "$vm_ref->{name}: $cmdline\n\n" 

    }
    else {  

        ##################################################
        # really do it, eventually, but some setup first:
        ##################################################

        # (1) return immediately if the vm is already up:
        ##################################################

        if ( get_vm_status($vm_ref) ) {
            print "$vm_ref->{name}(already up) ";
            return( report_retval(2) );
        }

        # (2) make sure no process has opened this vm's disk image: 
        ############################################################

        my $image = $vm_ref->{images}->[0];
        if ( $image ) {  # not all vms have images
            my $pids =
                `$rc{fuser} $rc{vm_img_dir}/$image 2>> $rc{log_file}`;
            Die "$rc{vm_img_dir}/$image: opened by pids:$pids\n"
                if $pids;
        }
        # (3) if the nic uses udp, check that its socket is free: 
        ##########################################################

        foreach my $nic ( @{ $vm_ref->{nics} } ) {
            next unless $nic->{netdev} eq 'udp';
            my $msg = "$vm_ref->{name}: " .
                      "$nic->{local_ip}:$nic->{local_port} in use\n";
            my $free = is_free_udp_socket( $nic->{local_ip}, 
                                       $nic->{local_port} );
            Die $msg unless $free;
        }

    }

    # startup the vde_switch wires, if applicable
    ##############################################

    NIC: foreach my $nic ( @{ $vm_ref->{nics} } ) {
        next NIC unless $nic->{netdev} =~ m/^vde/;

        # sub start_vde_nic() pretends with -n too, so just call it
        start_vde_nic( $vm_ref, $nic );     # covers vde and vde++
    }

    # we're done if pretending
    ###########################

    return( report_retval(0) ) if $args{n};

    # finally we start this vm; kill 0th window if we fail
    #######################################################

    unless ( my_system("$cmdline 2>> $rc{log_file}") == 0 ) {
        tmux_cmd( "$rc{tmux_sock_prefix}-$globals{topology_name}",
                  "$globals{topology_name}:0",
                  'kill-window',
        );
        Warn "system( $cmdline ) failed: $!\n";
    }

    # ensure window exists, and interpret this as a successful start: 
    ##################################################################

    my $failed;     # flag
    sleep 1;        # give qemu/tmux time to take effect

    my $cmd = join(' ',
        $rc{tmux}, 
        '-S', 
        "$rc{tmux_sock_prefix}-$globals{topology_name}", 
        'list-windows', 
        '-t', 
        "$globals{topology_name}"
    );
    my @output = split "\n", `$cmd`;
    $failed++ unless grep { m/^\d+: $vm_ref->{name}/ } @output; 
            
    # resize the window:
    #####################

    my $width  = $rc{vm_screen_width};
    my $height = $rc{vm_screen_height} + 1;   # +1 for tmux status bar
    my $resize_window = 
        "$rc{tmux} " . 
        "-S $rc{tmux_sock_prefix}-$globals{topology_name} " .
        "setw -t $globals{topology_name} " . 
        "force-height $height " .
        '> /dev/null';
    my_system( $resize_window );                  # height

    $resize_window = 
        "$rc{tmux} " . 
        "-S $rc{tmux_sock_prefix}-$globals{topology_name} " .
        "setw -t $globals{topology_name} " . 
        "force-width $width " .
        '> /dev/null';
    my_system( $resize_window );                  # width

    # report result
    ################

    if ( $args{v} or $failed ) { 
        print "$vm_ref->{name}", $failed ? "(failed) " : "\n";
    } 
    else { print "$vm_ref->{name} " }

    # return
    #########

    my $retval = $failed ? -1 : 1;

    return( report_retval($retval) );
}

# start_vde_nic(): start a nic using vde_switch
################################################

sub start_vde_nic {
    report_calling_stack(@_) if $args{d};

    my( $vm_ref, $nic ) = @_;

    # vde_switch cmdline (same for vde and vde++) 
    ##############################################

    my $cmd = 
          "$rc{vde_switch} " 
        . "--sock $nic->{vde_wire}.ctl "  
        . "--mgmt $nic->{vde_wire}.mgmt "  
        . "--pidfile $nic->{vde_wire}.pid " 
        . "--daemon"; 

    # wirefilter cmdline (vde++ only)
    ##################################

    my( $wirefilter_cmd, $remote_vde_switch);
    if ( $nic->{netdev} eq 'vde++' ) {
        $remote_vde_switch = 
            $rc{vde_dir} . '/' . $globals{topology_name} . '/' 
                . join( '.', $nic->{remote_host}, $nic->{remote_nic} );
        $wirefilter_cmd = "$rc{wirefilter} -v " .
                          "$nic->{vde_wire}.ctl:${remote_vde_switch}.ctl " .
                          "-M $nic->{wirefilter}.mgmt " .
                          "--pidfile $nic->{wirefilter}.pid " .
                          "--daemon";
    }

    # pretend mode
    ###############

    if ( $args{n} ) { 

        if ( $args{v} ) {
            print "    $nic->{name}: $cmd", 
                  $nic->{netdev} eq 'vde++'                          ? 
                  "\n\n         wire: $nic->{name}: $wirefilter_cmd" : 
                  "", 
                  "\n\n";
        }

        return( report_retval() ); 

    } 

    # start vde switch
    ###################

    # does the vde switch already exist?
    #####################################

    if ( -e "$nic->{vde_wire}.mgmt" ) {  
        # already exists

        # then, for vde (but not vde++) probably vde_switch was 
        # created by a previous vm; but let's ensure that it is responsive
        ###################################################################

        print basename("$nic->{vde_wire}.mgmt"), 
                       " already exists: checking it...\n" 
            if $args{v}; 

        my $sock = IO::Socket::UNIX->new(        # failure is normal
            Type => SOCK_STREAM,
            Peer => "$nic->{vde_wire}.mgmt",
        ) or $args{v} and Warn "IO::Socket::UNIX->new() failed: $!\n";

        if ( $sock ) {
            print { $sock } 'showinfo';
            my $line = <$sock>;
            $line 
                or Die "$nic->{vde_wire} doesn't seem to be responding\n";
        } 
        else { 
            Warn "$nic->{vde_wire} seems stale, deleting...\n" 
                if $args{v};

            unlink( "$nic->{vde_wire}.mgmt" ) 
                or Die "cannot unlink $nic->{vde_wire}.mgmt: $!\n";

            unlink( "$nic->{vde_wire}.pid" ) 
                or Die "cannot unlink $nic->{vde_wire}.mgmt: $!\n";

            my $rm_cnt;
            unless ( $rm_cnt = remove_tree("$nic->{vde_wire}.ctl", 
                     {error => \my $err})                          ) 
            {
                if ( $err &&  @$err ) {   # remove_tree() error msgs
                    foreach my $diag ( @$err ) {
                        my( $file, $message ) = %$diag;
                        if ( $file eq '' ) {
                            Die "remove_tree(): general error: $message\n";
                        }
                        else {
                            Die "remove_tree(): ",
                                "problem unlinking $file: $message\n";
                        }
                    }
                }
            }
#            say "ASDF: remove_tree() removed $rm_cnt files";

            # start up vde_switch
            Warn "Starting up vde_switch after removing stale files...\n" 
                if $args{v};
#            sleep 1; 
#            say "ASDF: execing: $cmd";
            my_system( "$cmd >> $rc{log_file} 2>> $rc{log_file}" ); 
#            say "vde_switch returned: $?";
            Die "vde create failed: system() exited with: $?\n" 
                unless ( $? == 0 );
    
            if ( $args{v} ) { 
                my $basename = basename( $nic->{vde_wire} );
                print "(${basename}) ";
            }
            # give vde time to startup:
#            sleep 1;
            # checking socket again:
            $sock = IO::Socket::UNIX->new(        # failure is normal
                Type => SOCK_STREAM,
                Peer => "$nic->{vde_wire}.mgmt",
            ) or Die "IO::Socket::UNIX->new() check on restart failed: $!\n";

        }
    } 
    else { 
        # vde switch doesn't already exist: start it up
        my_system( "$cmd >> $rc{log_file} 2>> $rc{log_file}" );
    
        Die "vde create failed: system() exited with: $?\n" 
            unless ( $? == 0 );

        if ( $args{v} ) { 
            my $basename = basename( $nic->{vde_wire} );
            print "(${basename}) ";
        }
    }


    # start wirefilter
    ###################

    # start the wirefilter, if applicable, unless it exists
    if (   $nic->{netdev} eq 'vde++' ) {               # applicable

        if ( -e "$nic->{wirefilter}.mgmt" ) {          # already exists
            print "\n", basename("$nic->{wirefilter}.mgmt"), 
                  " already exists: checking it...\n" 
                    if $args{v};

            my $sock = IO::Socket::UNIX->new(          # failure is normal
                Type => SOCK_STREAM,
                Peer => "$nic->{wirefilter}.mgmt",
            ) or $args{d} and Warn "IO::Socket::UNIX->new() failed: $!\n";

            if ( $sock ) {
                print { $sock } 'showinfo';
                my $line = <$sock>;
                $line or Die "$nic->{wirefilter}.mgmt ", 
                             "doesn't seem to be responding\n";
            } 
            else { 
            Warn "$nic->{wirefilter}.mgmt seems stale, deleting...\n";
            unlink( "$nic->{wirefilter}.mgmt" ) 
                or Die "cannot unlink $nic->{wirefilter}.mgmt";
            }
        } 
        elsif (     -e "$nic->{vde_wire}.ctl" 
                and -e "${remote_vde_switch}.ctl" ) 
        { 
           # vde_switches on both ends exist, so safe to start the wirefilter
            my_system( "$wirefilter_cmd >/dev/null 2>> $rc{log_file}" );

            Die "wirefilter create failed: system() exited with: $?\n" 
                unless ( $? == 0 );

            if ( $args{v} ) { 
                my $basename = basename( $nic->{wirefilter} );
                print "(${basename}) ";
            }
        }

    }

    return( report_retval() );
}

# construct_cmdlines(): construct and return an array qemu cmdlines 
####################################################################

sub construct_cmdlines { 
    report_calling_stack(@_) if $args{d};

    my $action_name = shift;            # 'start' or 'restore'
    my $topology_name = shift;

    # push the commands onto this array, and return a reference to it:
    ###################################################################

    my @cmds; 

    # loop through each vm in the topology
    #######################################

    my @topology = @{ $globals{topology} };
    VM: foreach my $i ( 0 .. $#topology ) { 

        my $cmd = vm_cmdline( $i, $topology[$i], $topology_name ); 

        # add this cmdline to the list
        push @cmds, $cmd;

        ## TODO: write this cmdline to logfile too

    } # end VM loop

    return( report_retval(\@cmds) );
}

# vm_cmdline(): take a vm, an index and a topology name,
# and return its qemu cmdline 
#########################################################

sub vm_cmdline { 
    report_calling_stack(@_) if $args{d};

        my $i = shift;
        my $window = $i+1;              # tmux windows start at 1, not 0 
        my $vm_ref = shift; 
        my $topology_name = shift; 

        # temp storage for the constructed cmdline: 
        my $cmd; 

        # we run each qemu process in a tmux window, with these options: 
        #################################################################

        my @tmux_opts = (
            -S => "$rc{tmux_sock_prefix}-${topology_name}",
            'new-window',
            -t => "$topology_name:$window",
            -n => $vm_ref->{name},
        );

        # set qemu executable
        ######################

        my $qemu_exe = $vm_ref->{arch} eq "x86_64" ? $rc{qemu_64} 
                     : $vm_ref->{arch} eq "i386"   ? $rc{qemu_i386} 
                     : undef;

        $qemu_exe // Die "BUG: vm arch wrong: this msg shouldn't appear\n"; 

        ##################################
        # begin constructing qemu cmdline
        ##################################

        # general options
        ##################

        my @qemu_opts = (
            -name => $vm_ref->{name},
            -pidfile => 
                join( '/', 
                      $rc{pid_dir}, 
                      $globals{topology_name}, 
                      $vm_ref->{name}, 
                ),
            '-no-fd-bootchk',
            -m => $vm_ref->{memory},
            -monitor =>
                join( '/',
                      "unix:$rc{socket_dir}",
                       $globals{topology_name},
                      "$vm_ref->{name},server,nowait" ), 
        );
        push @qemu_opts, '-enable-kvm' 
            if $rc{kvm} eq "yes";

        # image specific options
        #########################

        foreach my $image ( @{ $vm_ref->{images} } ) {
            my $drive = "file=/$rc{vm_img_dir}/$image";
            if ( $vm_ref->{driver} eq 'none' ) { 
                $drive .= ',if=ide';     # default to ide
            }
            else { $drive .= ",if=$vm_ref->{driver}" }

            # default cache=writeback unstable on power loss:
            $drive .= ",cache=writethrough";
            push @qemu_opts, -drive => "$drive";
        }

        # display specific options
        ###########################

        if ( $vm_ref->{display}->{name} eq 'spice' ) { 
            my $name    = $vm_ref->{name}; 
            my $display = $vm_ref->{display}->{name}; 
            my $port    = $vm_ref->{display}->{port}; 
            my @vm_list = grep {defined} @{ $globals{vm_list} }; 

            # is this vm in our list?  then check the spice port: 
            if (         grep { $_->{name} eq $name } @vm_list 
                 and not is_free_tcp_socket($globals{ipaddr}, $port) 
                 and not get_vm_status $vm_ref                       ) 
            { Die "$name: $display: TCP $port is in use\n" }

            push @qemu_opts, 
                -spice => join(',',
                    "port=$vm_ref->{display}->{port}",
                    "password=$vm_ref->{display}->{pword}",
                ),
                -usbdevice => "tablet -vga qxl";
        } 
        elsif ( $vm_ref->{display}->{name} eq 'nographic' ) { 
            push @qemu_opts, 
                '-serial mon:stdio', 
                "-$vm_ref->{display}->{name}"; 
        }
        elsif ( $vm_ref->{display}->{name} eq 'curses' ) { 
            push @qemu_opts, "-$vm_ref->{display}->{name}" 
        }
        else { 
            # this is probably redundant: 
            Die "unrecognized display: $vm_ref->{display}->{name}" 
        }

        # cdrom specific options
        #########################
        if ( $vm_ref->{cdrom} ) { 
            my $base = 
                -e "$rc{priv_base_img_dir}/$vm_ref->{cdrom}" ? 
                   "$rc{priv_base_img_dir}/$vm_ref->{cdrom}" :
                -e "$rc{base_img_dir}/$vm_ref->{cdrom}" ? 
                   "$rc{base_img_dir}/$vm_ref->{cdrom}" : undef;

            push @qemu_opts, -cdrom => $base
                if defined $base;
        }

        ########################
        # nic specific options:
        ########################

        NIC: foreach my $i ( 0 .. $#{ $vm_ref->{nics} } ) {
            my $nic = $vm_ref->{nics}->[$i];
            my $mac = $nic->{mac};
            my $nic_driver;
            if ( $vm_ref->{driver} eq "none" ) { $nic_driver = "e1000" }
            else                                { $nic_driver = "virtio-net" }
            push @qemu_opts,
                -device => join(',', "${nic_driver}",
                                     "mac=${mac}",
                                     "netdev=e${i}",
                           );

            # different qemu options depending on netdev
            #############################################

            if ( $nic->{netdev} eq 'udp' ) {

                # udp sockets
                ##############

                push @qemu_opts,
                    -netdev => 
                        join(',', 
                            "socket",
                            "id=e${i}",
                            "udp=$nic->{remote_ip}:$nic->{remote_port}",
                            "localaddr=$nic->{local_ip}:$nic->{local_port}",
                        );

            } 
            elsif ( $nic->{netdev} eq 'tap' ) {

                # tap connection
                #################

                push @qemu_opts,
                    -netdev => 
                        join(',', 
                            "tap",
                            "id=e${i}",
                            "ifname=$nic->{remote}",
                            "script=no",
                            "downscript=no",
                        );

            } 
            elsif ( $nic->{netdev} =~ '^vde' ) {

                # vde sockets
                ##############

                my $vde_name;

                if ( $nic->{netdev} eq 'vde' ) {

                    # just the vde switch
                    #####################

                    my @sorted = 
                        sort( "$nic->{remote_host}.$nic->{remote_nic}", 
                              "$vm_ref->{name}.$nic->{name}"            );
                    $vde_name = "$sorted[0]" . "-" . "$sorted[1]" . '.ctl';
                } 
                elsif ( $nic->{netdev} eq 'vde++' ) {

                    # vde switch plus wirefilter
                    #############################

                    $vde_name = "$vm_ref->{name}.$nic->{name}" . '.ctl';
                }                    

                my $sockpath = join( '/', 
                                      $rc{vde_dir}, 
                                      $globals{topology_name}, 
                                      $vde_name                );

                push @qemu_opts,
                    -netdev => 
                        join( ',', 
                              'vde', 
                              "id=e${i}", 
                              "sock=$sockpath", 
                        );

            }

        }

        # or maybe there are no nics: 
        ##############################

        push @qemu_opts, -net => "none" 
            unless @{ $vm_ref->{nics} }; 

        # redirect qemu stderr to this file:
        #####################################

        my $stderr_file = 
            "$rc{stderr_dir}/$globals{topology_name}/$vm_ref->{name}";

        # finally, the complete command:
        #################################

        $cmd = 
            "$rc{tmux} @tmux_opts "; 

        # opening single quote for tmux command:
        $cmd .= "'";

        # add a little msg in tmux window when using spice:
        $cmd .= "echo Spice display on TCP port $vm_ref->{display}->{port}; " 
            if $vm_ref->{display}->{name} eq 'spice';

        $cmd .= "$qemu_exe @qemu_opts 2> $stderr_file "; 

        # closing single quote for tmux command:
        $cmd .= "'";

        return( report_retval($cmd) );

}

# construct_cmdlines_from_file(): for -s: get cmdline from file
################################################################

sub construct_cmdlines_from_file { 
    report_calling_stack(@_) if $args{d};

    my @cmds;
    my $autostart_dir = join( '/', 
        $rc{autostart_base_dir}, 
        $globals{topology_name},
    );
    my @vm_list = @{ $globals{vm_list} };

    # grab the cmdline for each specified vm
    #########################################

    VM: for my $i ( 0 .. $#{vm_list} ) {

        my $vm_ref = $vm_list[$i];
        next VM unless defined $vm_ref;

        my $autostart_file = 
            join( '/', $autostart_dir, $vm_ref->{name} );
        open( my $fh, '<', $autostart_file )
            or Die "cannot open $autostart_file: $!\n";
        chomp( my $cmd = <$fh> );

        push @cmds, $cmd;

    }

    return( report_retval(\@cmds) );
}

# ping_topology(): ping all ip addrs in topology
#################################################

sub ping_topology { 
    report_calling_stack(@_) if $args{d};

    require Net::Ping;
    my $p = Net::Ping->new();      # uses tcp echo port
    my @pinged_addrs;              # list of addrs we've already pinged

    VM: foreach my $vm_ref ( grep {defined} @{ $globals{vm_list} } ) {

        NIC: foreach my $nic ( @{ $vm_ref->{nics} } ) { 
            next NIC unless $nic->{netdev} eq 'udp';

            # ping the default ipaddr
            unless ( grep {$_ eq $globals{ipaddr}} @pinged_addrs ) {
                $p->ping( $globals{ipaddr} ) 
                    or Die "$globals{ipaddr} unreachable.\n";
            }

            # ping the nic specific local ip (for udp sockets)
            unless ( grep {$nic->{local_ip} eq $_} @pinged_addrs ) {
                $p->ping( $nic->{local_ip} );
                push @pinged_addrs, $nic->{local_ip};
            }

            # ping the nic specific remote ip (for udp sockets)
            unless ( grep {$nic->{remote_ip} eq $_} @pinged_addrs ) {
                $p->ping( $nic->{remote_ip} );
                push @pinged_addrs, $nic->{remote_ip};
            }
        }

    }

    return( report_retval() );
}

# get_unrestorable_vms(): return list of vms without saved memory state
########################################################################

sub get_unrestorable_vms { 
    report_calling_stack(@_) if $args{d};

    my @unrestorable;

    # skip if we're migrating (TODO)
    return( report_retval(\@unrestorable) ) if $args{m};

    # vm_save_status() returns true if mem state is saved:
    #######################################################

    foreach my $vm_ref ( grep {defined} @{ $globals{vm_list} } ) {
        unless ( vm_save_status( $vm_ref ) ) {
            push @unrestorable, $vm_ref->{name};
            $vm_ref = undef;
        }
    }

    return( report_retval(\@unrestorable) );
}

# do_migrate_in(): start a vm from migration file
###################################################################

sub do_migrate_in {
    report_calling_stack(@_) if $args{d};

    my $cmdlines = shift;
    my @vm_list = @{ $globals{vm_list} };

    VM: foreach my $i ( 0 .. $#{vm_list} ) {
        next VM unless defined $vm_list[$i];

        # check that migrate file exists, and is readable
        my $migrate_file =
            join('/', $rc{migrate_in_dir}, 
                      $globals{topology_name},
                      "$vm_list[$i]->{name}.gz", 
            );
        unless ( $args{n} ) {
            -e $migrate_file or Die "$migrate_file doesn't exist\n";
            -r _             or Die "migrate_file isn't readable\n";
        }

        # modify the normal qemu cmdline to load from that mem state
        my $incoming = "-incoming \"exec:gzip -c -d $migrate_file\"";
        $cmdlines->[$i] =~
            s/(-name $vm_list[$i]->{name})/$1 $incoming/;
    }

    return( report_retval() );
}

# do_auto_restore(): restores a vm from the last memory state save
###################################################################

sub do_auto_restore {
    report_calling_stack(@_) if $args{d};

    my $cmdlines = shift;
    my @vm_list = @{ $globals{vm_list} };

    VM: foreach my $i ( 0 .. $#{vm_list} ) {
        next VM unless defined $vm_list[$i];

        # get the saves from qemu monitor
        my @saves = vm_save_status( $vm_list[$i] );

        # extract the name of the save
        my @save_names =
            map { my @fields = split ' ', $_; $fields[2] } @saves;

        # choose the last saved memstate
        my $choice = $save_names[-1];

        # modify the normal qemu cmdline to load from that mem state
        $cmdlines->[$i] =~
            s/(-name $vm_list[$i]->{name})/$1 -loadvm \Q$choice\E/;
    }

    return( report_retval() );
}

# choose_restore(): restores a vm from memory state chosen by user
###################################################################

sub choose_restore { 
    report_calling_stack(@_) if $args{d};

    my $cmdlines = shift;                         # array ref
    my @vm_list = @{ $globals{vm_list} };

    VM: foreach my $i ( 0 .. $#{vm_list} ) {
        next VM unless defined $vm_list[$i];

        # get the saves from qemu monitor
        my @saves = vm_save_status( $vm_list[$i] );

        # extract the name of the save
        my @save_names = 
            map { my @fields = split ' ', $_; $fields[2] } @saves; 

        # prompt the user for a save name
        ##################################

        PROMPT: while (1) {
            my $choice = $save_names[-1];
            print "$vm_list[$i]->{name}: ",
                join(' ', @save_names), " [$choice]:";
            chomp( $choice = <STDIN> );
            $choice = $save_names[-1] unless $choice;
            if ( grep { /^$choice$/ } @save_names ) {
                $cmdlines->[$i] =~
                    s/(-name $vm_list[$i]->{name})/$1 -loadvm \Q$choice\E/;
                last PROMPT;
            } 
            else { say "$choice: invalid" }
        }

    }

    return( report_retval() );
}

## - TODO: should be able to open up the cmdline in an editor, 
## with a ctl-e sequence or something?

# edit_cmdlines(): edit qemu cmdlines when -e set with start/restore action
############################################################################

sub edit_cmdlines { 
    report_calling_stack(@_) if $args{d};

    Die "-e: editing unavailable (no Term::ReadLine::Gnu)\n"
        unless got_readline();

    my $cmdlines = shift;     # array ref

    say "At each vm prompt, use up arrow to display and edit.  ",
        "(Or just hit <enter> to leave it as is.)";

    # read in lines of edit history
    ################################

    my @vm_list = @{ $globals{vm_list} };
    my $term = Term::ReadLine->new("vmcli");

    VM: for my $i ( 0 .. $#{vm_list} ) {
        next VM unless defined $vm_list[$i];

        # read in edit history from file
        #################################

        my $cmdfile = 
            "$rc{history_dir}/$globals{topology_name}/$vm_list[$i]->{name}";
        my @lines;
        if ( -e $cmdfile ) { 
            open( my $fh, '<', $cmdfile ) 
                or Die "cannot open $cmdfile: $!\n";
            chomp( @lines = <$fh> );
            close( $fh );
            foreach my $line ( @lines ) {
                $term->addhistory($line) unless $line =~ m/^$/;
            }
        }

        # add current qemu startup command for this vm
        ###############################################

        $term->addhistory( $cmdlines->[$i] );

        my $OUT = $term->OUT() || *STDOUT;        # what's this for?

        # get user's edit
        ##################

        chomp( my $cmd = $term->readline("$vm_list[$i]->{name}: ") );
        if ( $cmd and $cmdlines->[$i] ne $cmd ) {

            # user edited default command, so add it to history
            ####################################################

            push @lines, "$cmd\n";
            @lines = @{ get_uniq( \@lines ) };
            open( my $fh, '>', $cmdfile ) 
                or Die "cannot open $cmdfile: $!\n"; 
            # limit to 10 lines of history
            for ( my $j = 0; $j < 10 and $j < @lines; $j++ ) { 
                say { $fh } $lines[$j];
            }
            close( $fh );

        }

        # set cmdline to edited cmdline
        ################################

        $cmdlines->[$i] = "$cmd" if $cmd;

        # if -s used, save the edited cmd to autostart file
        ####################################################

        if ( $args{s} ) {                         # save to autostart file
            my $autostart_file = join( '/', 
                $rc{autostart_base_dir},
                $globals{topology_name},
                $vm_list[$i]->{name},
            );
            open( my $fh, '>', $autostart_file )
                or Die "cannot open $autostart_file: $!\n";
            say { $fh } $cmd ? "$cmd" : $cmdlines->[$i];
        }
    }

    return( report_retval() );
}

# got_readline(): returns true if we have GNU readline, false otherwise
########################################################################

sub got_readline { 
    report_calling_stack(@_) if $args{d};

    require Term::ReadLine;
    my $retval = TRUE;   # default return
    unless ( Term::ReadLine->new('t')->ReadLine eq "Term::ReadLine::Gnu" ) {
        Warn "Term::ReadLine::Gnu unavailable\n" if $args{d};
        $retval = FALSE;
    }

    return( report_retval($retval) );
}

# is_free_udp_socket(): determine if a udp port is free
########################################################

sub is_free_udp_socket { 
    report_calling_stack(@_) if $args{d};

    my( $ip, $port ) = @_;
    @_ == 2 
        or Die "is_free_udp_socket() must be called with two parameters";

    # try various ways to check the udp socket
    ###########################################

    # lsof
    if ( -e $rc{lsof} ) {
        my_system( "$rc{lsof} -iUDP\@${ip}:$port >>$rc{log_file} 2>&1" );
        return( report_retval($? > 0 ? 1 : 0) );
    } 
    # netstat
    elsif ( -e $rc{netstat} ) {
        my $netstat_cmdline;
        if    ( $^O eq "linux" ) {
            $netstat_cmdline = "$rc{netstat} -4uan"
        } 
        elsif ( $^O eq "openbsd" ) {
            $netstat_cmdline = "$rc{netstat} -anp udp -f inet"
        }
        open( my $netstat_output, '-|', "$netstat_cmdline 2>/dev/null" )
            or Die "cannot run netstat: $!\n";
        while(<$netstat_output>) { 
            return( report_retval(0) ) 
                if m/${ip}:${port}/ 
        }
        close $netstat_output;
        return( report_retval(1) );
    } 
    # BUG: get_external_program_dependencies() should have died on this
    else { 
        Die "BUG: no $rc{netstat} or $rc{lsof}, but already checked!\n" 
    }

    return( report_retval() );
}

# is_free_tcp_socket(): determine if a tcp port is free (spice)
################################################################

sub is_free_tcp_socket { 
    report_calling_stack(@_) if $args{d};

    my( $ip, $port ) = @_;
    @_ == 2 
        or Die "is_free_tcp_socket() must be called with two parameters";

    # try various ways to check the udp socket
    ###########################################

    # lsof
    if ( -e $rc{lsof} ) {
#        my_system( "$rc{lsof} -iTCP\@${ip}:$port >>$rc{log_file} 2>&1" );
        # lsof() doesn't interpret something listening on 0.0.0.0 
        # as all ips, so:
        my_system( "$rc{lsof} -iTCP:$port >>$rc{log_file} 2>&1" );
        return( report_retval($? > 0 ? 1 : 0) );
    } 
    # netstat
    elsif ( -e $rc{netstat} ) {
        my $netstat_cmdline;
        if    ( $^O eq "linux" ) {
            $netstat_cmdline = "$rc{netstat} -4tan"
        } 
        elsif ( $^O eq "openbsd" ) {
            $netstat_cmdline = "$rc{netstat} -anp tcp -f inet"
        }
        open( my $netstat_output, '-|', "$netstat_cmdline 2>/dev/null" )
            or Die "cannot run netstat: $!\n";
        while(<$netstat_output>) { 
            return( report_retval(0) ) 
                if m/${ip}:${port}/ 
        }
        close $netstat_output;
        return( report_retval(1) );
    } 
    # BUG: get_external_program_dependencies() should have died on this
    else { 
        Die "BUG: no $rc{netstat} or $rc{lsof}, but already checked!\n" 
    }

    return( report_retval() );
}

1;
