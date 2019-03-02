package Vinetctl::TopAction;

use strict;
use warnings;

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

use Vinetctl::StatusAction qw(
    get_vm_status
    get_vde_status
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    top_action
);

# top_action(): show qemu procs in top(1) window
#################################################

sub top_action { 
    report_calling_stack(@_) if $args{d};

    my @pids; 

    # loop through vms, and if up, find and record its pid
    #######################################################

    VM: foreach my $vm_ref ( grep {defined} @{ $globals{vm_list} } ) {
    
        # get the qemu pid
        ###################

        if ( get_vm_status($vm_ref) ) {
            my $pidfile = 
                "$rc{pid_dir}/$globals{topology_name}/$vm_ref->{name}"; 
            my $pid;
            unless ( open(my $fh, '<', $pidfile) ) {
                Warn( "\n$vm_ref->{name}: open() on pidfile failed.\n" )
                    if $args{d};
            } 
            else {
                chomp( $pid = <$fh> );
                push( @pids, $pid );
                close $fh;
            }
        }

        # only with -v do we grab other vde related pids
        #################################################

        next unless $args{v};

        # get vde and vde++ pids
        #########################

        NIC: foreach my $nic ( @{ $vm_ref->{nics} } ) {

            if (     $nic->{netdev} =~ m/^vde/
                 and get_vde_status($nic->{vde_wire}, 'vde')  ) 
            {
                # vde pid
                ##########

                my $pidfile = "$nic->{vde_wire}.pid";
                my $pid;
                unless ( open(my $fh, '<', $pidfile) ) {
                    Warn( "\n$nic->{vde_wire}: open() on pidfile failed.\n" )
                        if $args{d};
                } 
                else {
                    chomp( $pid = <$fh> );
                    push( @pids, $pid );
                    close $fh;
                }

                # vde++ (wirefilter) pid
                #########################

                if (     $nic->{netdev} eq 'vde++'
                     and get_vde_status($nic->{wirefilter}, 'wirefilter') )
                {
                    my $pidfile = "$nic->{wirefilter}.pid";
                    my $pid;
                    unless ( open(my $fh, '<', $pidfile) ) {
                        Warn( "\n$nic->{vde_wire}: ", 
                               "open() on pidfile failed.\n" 
                        ) if $args{d};
                    } 
                    else {
                        chomp( $pid = <$fh> );
                        push( @pids, $pid );
                        close $fh;
                    }
                }
            } 

        } # end NIC loop

    } # end VM loop

    Die "no vms running\n" unless @pids;

    # invoke top(1) differently depending on OS
    ############################################

    my @cmd;
    if ( $^O eq 'openbsd' ) { 
        # this may produce false positives: 
        @cmd = ( 'top', 
                 '-CU', 
                  $rc{username}, 
                 '-g', $globals{topology_name} 
        );
    } 
    elsif ( $^O eq 'linux' ) {
        if ( @pids > 20 ) {             # top(1) supports 20 max on linux
            Warn( "top(1) 20 processes max, truncating\n" ) and sleep 1;
            @pids = @pids[0..19];
        }
        @cmd = ( 'top', '-cp', join(',', @pids) );
    } 
    else { Die "top action unsupported on this operating system\n" }

    # we unlink pid file since we won't run exit handler at END of vinetctl
    unlink $globals{pid_file}
        or Warn "cannot unlink $globals{pid_file}: $!\n";

    exec @cmd or Die "couldn't exec: $!\n";

    # no return: we execed or died above
    #####################################
}

1;
