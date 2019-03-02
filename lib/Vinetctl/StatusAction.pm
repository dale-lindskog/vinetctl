package Vinetctl::StatusAction;

# Copyright (c) 2019 Dale Lindskog <dale.lindskog@gmail.com>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF MIND, USE, DATA OR PROFITS, WHETHER
# IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING
# OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

use strict;
use warnings;
use feature qw( say );
use constant { TRUE => 1, FALSE => 0 };
use IO::Socket::UNIX qw( SOCK_STREAM );
use File::Basename;
use IPC::Open3 qw( open3 );   # used with qemu-img for stderr
use Sort::Versions;           # to check qemu-img versions

use Vinetctl::Globals qw( 
    %args
    %rc
    %globals
);

use Vinetctl::Debug qw( 
    report_calling_stack
    report_retval
    Warn
    Die
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    status_action
    get_monitor_sock
    get_vm_status
    vm_save_status
    get_vde_status
);

# status_action(): show whether vms in a topology are running, and other info
##############################################################################

sub status_action {
    report_calling_stack(@_) if $args{d};

    my $all = @{ $globals{topology} };
    my $some = my @def_vm_list = grep {defined} @{ $globals{vm_list} }; 

    # will push vms into these arrays depending on if their up or down:
    my ( @vm_up, @vm_down, );

    my $output;
    my( $nics_r_dead, $need_newline ) = ( FALSE, FALSE );   # flags

    # loop thru vms, get status
    ############################

    VM: foreach my $vm_ref ( @def_vm_list ) {

        # populate the up and down arrays
        my $up = get_vm_status( $vm_ref );

        if ( $up ) { push @vm_up, $vm_ref }
        else       { push @vm_down, $vm_ref }

        # loop thru nics, get status
        #############################

        my $nic_line; 
        NIC: foreach my $nic ( @{ $vm_ref->{nics} } ) {

            next unless $nic->{netdev} =~ m/^vde/;

            my $name;     # of vde_switch or wirefilter

            # vde_switch
            #############

            # make note if a vde_switch is dead
            my $its_up = 
                get_vde_status($nic->{vde_wire}, 'vde') ? TRUE : FALSE;
            $nics_r_dead++ unless $its_up;

            # construct vde specific output for verbose mode
            $name = basename($nic->{vde_wire});
            $nic_line .= "\n  " . $name . ( $its_up ? "(up)" : "(down)" )
                if $args{v};

            next unless $nic->{netdev} eq 'vde++';

            # wirefilter
            #############

            # make note if a wirefilter is dead
            $its_up = 
                get_vde_status($nic->{wirefilter}, 'wirefilter') ? TRUE
                                                                 : FALSE;
            $nics_r_dead++ unless $its_up;

            # construct wirefilter specific output for verbose mode
            $name = basename($nic->{wirefilter});
            $nic_line .= "\n  " . $name . ( $its_up ? "(up)" : "(down)" )
                if $args{v};

        }

        if ( $args{v} ) { 

            # verbose output
            #################

            $output .= "$vm_ref->{name}:";
            $output .= $up ? "up($up) " : "down ";
            $output .= $nic_line // '';
            my @save_dates = vm_save_status($vm_ref);
            $output .= "\n " . join "  ", map { qq/[$_]/ } @save_dates
                if @save_dates;
            $output .= "\n";

        } 
        elsif ( $some != $all ) { 

            # terse output
            ###############

            $output .= "$vm_ref->{name}:";
            $output .= $up ? "up  " : "down  ";
            $need_newline++;

        } 
        # else{} is taken care of below

    }
    $output .= "\n" if $need_newline;

    # we continue to construct this output:
    ########################################

    # NOTE: $some == $all if we're reporting on all vms in topology

    if ( $some == $all and not $args{v} ) {  
    
        # terse display
        ################

        if ( @vm_up and @vm_down ) { 
            # outputs as 'up: x y down: z':
            $output .= "up: " .  (join ' ', map { "$_->{name}" } @vm_up);
            $output .= 
                "  down: " .  (join ' ', map { "$_->{name}" } @vm_down);
        } 
        else { 
            # just say 'up' or 'down' if all are one or the other:
            $output .= @vm_up ? "all up" : "all down" 
        }
        $output .= "\n";
    }

    print "$globals{topology_name}: ",  
          $args{v} ? 
          "\n" . '-' x length( $globals{topology_name} ) . "\n" : "",
          $output;

    ###############################################################
    # NOTE: if we found dead vde_switches or wirefilters, warn the
    # user, but only when all vms are up (the usual case, and the 
    # case where we know all wires should be up 
    ###############################################################

    Warn "nics and/or wires are down: -v for details\n" 
        if $nics_r_dead and not $args{v} and @vm_up and not @vm_down;

    # not safe to clean up pid dir on stop action, so do it here:
    foreach my $vm_ref ( @vm_down ) { 
        my $vm_name = "$rc{pid_dir}/$globals{topology_name}/$vm_ref->{name}";
        not -e $vm_name or unlink $vm_name
            or Die "cannot unlink $vm_name: $!\n";

    }

    return( report_retval() );
}

# get_vm_status(): return true if vm is running
################################################

sub get_vm_status { 
    report_calling_stack(@_) if $args{d};

    my $vm_ref = shift;
    my ( $status, $line, $sock );

    # vm is down unless we can get its monitor socket
    ##################################################

    return( report_retval( 0 ) )
        unless $sock = get_monitor_sock( "$vm_ref->{name}", 'vm' );

    # got the vm monitor sock, so check and record status
    ######################################################

    print { $sock } "info status\n\n";
    foreach my $i ( 0 .. 3 ) {  # need to bash at the socket a bit
        $line = <$sock>;
        next unless $line;
        $status = 'running' 
            if $line =~ m/VM status: running/;
        $status = 'paused' 
            if $line =~ m/VM status: paused/; 
        $status = 'paused_postmigrate'
            if $line =~ m/VM status: paused \(postmigrate\)/;
    }

    # sanity check: let's see if the vm shows up in tmux ls output too
    ###################################################################

    my $retval;

    my @options = (
        -S => "$rc{tmux_sock_prefix}-$globals{topology_name}",
        'list-windows',
        -t => $globals{topology_name},
    );
    my @output = `$rc{tmux} @options 2>> $rc{log_file}`;

    if ( $status ) { # then monitor shows as up, but:
        unless ( grep { /$vm_ref->{name}/ } @output ) { 
            # then tmux shows as down!  Warn:
            Warn "$vm_ref->{name} stats as up, but not in tmux list. " .
                 "Run status again and this should resolve"; 
        }
        $retval = $status;
    } 
    else { 
        Warn "$vm_ref->{name} appears to be up, but not responding\n";
        $retval = 0;
    }

    return( report_retval($retval) );
}

# get_vde_status(): given a vde device name and type, return true if up
########################################################################

sub get_vde_status { 
    report_calling_stack(@_) if $args{d};

    # sanity check on our parameters
    #################################

    Die "get_vde_status() requires two parameters: DEVICE and TYPE\n"
        unless @_ == 2;
    my( $vde_device, $type ) = @_; 
    $type eq 'vde' or $type eq 'wirefilter'
        or Die "get_vde_status(): $type: unsupported type\n";

    my $sock;            # for the vde mgmt socket 

    # assume it's down
    ###################

    my $status = 0; 

    # its definitely down if the mgmt socket doesn't exist
    #######################################################

    unless ( -e "${vde_device}.mgmt" ) {
        Warn "${vde_device}.mgmt does not exist\n" 
            if $args{d} and $args{v};
        return( report_retval(0) );
    }

    # still assume its down if the socket isn't attainable
    #######################################################

    unless ( $sock = 
                get_monitor_sock(basename("${vde_device}.mgmt"), $type) ) 
    {
        Warn "${vde_device}.mgmt exists but not responding\n" if $args{d};
        return( report_retval(0) ); 
    }

    # talk to the device
    #####################

    print { $sock } "showinfo\n";
    foreach my $i ( 0 .. 4 ) {  # need to bash at the socket a bit
        my $line = <$sock>;
        next unless $line;
        $status = 1 if $line =~ m/0000 DATA/;     # it's up!!
    }

    return( report_retval($status) );
}

# vm_save_status(): run 'qemu-img info' against image to get mem save info
###########################################################################

sub vm_save_status { 
    report_calling_stack(@_) if $args{d};

    # TODO: only checking first image in image array

    my $vm_ref = shift;  # the vm we're working with

    # image not defined or doesn't exist, nothing to do: 
    unless ( defined  $vm_ref->{images}->[0] and 
             -e "$rc{vm_img_dir}/$vm_ref->{images}->[0]" ) 
    {
        report_retval( () );
        return( () );
    }

    # construct qemu-img cmdline
    #############################

    my $output = `qemu-system-x86_64 -version | head -1`; 
    my $version = $1 
        if $output =~ m/version (\d+\.\d+.\d+)/; 

    my $old = ( versioncmp($version, '2.10.0') == -1 ) ? TRUE : FALSE; 

    my $cmd = join( ' ', 
                    "$rc{qemu_img}",
                    'info', 
                     $old ? '' : '--force-share', 
                    "$rc{vm_img_dir}/$vm_ref->{images}->[0] " );

    # execute qemu-img and collect output
    ######################################

    my( $wtr, $rdr, $err );
    use Symbol 'gensym'; $err = gensym;
    my $pid = open3($wtr, $rdr, $err, $cmd);
    waitpid( $pid, 0 );
    my $child_exit_status = $? >> 8;

    if ( $child_exit_status and $args{v} ) {      # 1 is error
        my @err_output = <$err>;
        Warn( "$rc{qemu_img} exited with status",
               $child_exit_status, "with error message: ", 
               @err_output, "\n"                              );
        return( () );
    }

    my( @output_lines, @fields, $tmp );
    while ( <$rdr> ) { last if m/^ID\s+TAG/ }      # skip to saved vm info
    while ( <$rdr> ) {                             # get saved vm info
        last unless m/^\d/;   # get lines until we're past saves
        @fields = split ' ';
        $tmp = join( ' ', $fields[3], $fields[4], $fields[1] )
            if defined $fields[3] and 
               defined $fields[4] and 
               defined $fields[1];
    
        push @output_lines, $tmp if $tmp;
    }

    ## TODO: report_retval() doesn't work well here, so we do it this way:
    report_retval(@output_lines);
    return(@output_lines);
}

# get_monitor_sock(): get a socket to communicate with a qemu/vde monitor
##########################################################################

sub get_monitor_sock { 
    report_calling_stack(@_) if $args{d};

    Die "get_monitor_sock() requires two parameters\n" 
        unless @_ == 2;

    my( $file, $type ) = @_;
    my $sock_file;
    my $retval = 1;      # dummy value, will be changed

    my $base_dir = $type eq 'vm'         ? $rc{socket_dir}     :
                   $type eq 'vde'        ? $rc{vde_dir}        :
                   $type eq 'wirefilter' ? $rc{wirefilter_dir} : "";

    Die "get_monitor_sock(): unknown type\n" 
        unless $base_dir;

    $sock_file = "$base_dir/$globals{topology_name}/$file";

    # error checking on socket file
    ################################

    if ( not -e $sock_file ) {
        Warn "socket $sock_file doesn't exist\n" 
            if $args{d} and $args{v};
        $retval = 0;
    }
    elsif ( not -S _ ) {
        Warn "$sock_file is not a socket!\n"
            if $args{d} and $args{v};
        $retval = 0;
    }

    # create the socket connection
    ###############################

    my $sock = IO::Socket::UNIX->new(             # failure is normal
        Type => SOCK_STREAM,
        Peer => $sock_file
    );

    if ( $sock and $args{d} and $args{v} ) { 
        Warn "IO::Socket::UNIX->new() failed: $!\n";
    }

    # return $sock or zero (0)
    return( report_retval($retval ? $sock : $retval) ); 
}

1;
