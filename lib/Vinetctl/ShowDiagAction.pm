package Vinetctl::ShowDiagAction;

use strict;
use warnings;
use feature qw( say );

use Vinetctl::Globals qw( 
    %args 
    %rc 
    %globals
);

use Vinetctl::Debug qw( 
    report_calling_stack
    report_retval
    Die
);

use Vinetctl::Topology qw(
    open_topology_file
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    show_diag_action
);

# show_diag_action(): show info or just diagram from topology file
###################################################################

sub show_diag_action {
    report_calling_stack(@_) if $args{d};

    # 'top' action takes no parameters
    if (     @{ $globals{action_params} } 
         and $globals{action_name} eq 'diagram' )
    { Die "usage: $rc{progname} [-f TOP] $globals{action_name}\n" }

    # open topology file
    my $topology_fh =
        open_topology_file( 
            $globals{topology_name} eq 'default' ? '_DEFAULT' :
            "$rc{topology_dir}/$globals{topology_name}" 
        );

    # show diagram unless in 'show' action, and in dialog, 
    # (dialog garbles ascii diagram in 'show' msgbox)
    while ( <$topology_fh> ) { 
        next if $globals{action_name} eq 'show' and $globals{dialog_loop}; 
        print if m/^##/; 
    } 

    # if action is 'show', give topology's detail too:
    if ( $globals{action_name} eq 'show' ) { 
        show_vm( $_ ) foreach grep {defined} @{ $globals{vm_list} };
    }

    close $topology_fh;

    return( report_retval() );
}

# show_vm(): print out specs on this vm
########################################

sub show_vm { 
    report_calling_stack(@_) if $args{d};

    my $vm_ref = shift;
    say "$vm_ref->{name}:";

    if ( $args{v} ) {    # verbose mode
        IMAGES: foreach my $image ( @{ $vm_ref->{images} } ) {
            say " image: $image";
        }
        KEY: foreach ( sort keys %$vm_ref ) {
#            say " $_: ", $vm_ref->{$_} // 'UNDEFINED' 
            unless ( m/^(nics|name|display|images)$/ ) { 
                say " $_: ", $vm_ref->{$_} 
                    if defined( $vm_ref->{$_} ); 
            }
        }
        print " display: $vm_ref->{display}->{name}";
        if ( $vm_ref->{display}->{name} eq 'spice' ) {
            print " [port=$vm_ref->{display}->{port}",
                  " pword=$vm_ref->{display}->{pword}]\n";
        } 
        else { print "\n" }
    }

    my $i = 0;
    NIC: foreach my $nic ( @{ $vm_ref->{nics} } ) {
        print "  e${i}: ", $args{v} ? "$nic->{netdev}, " : "", 
              "mac=$nic->{mac}, ";

        # output is different depending on netdev:
        ###########################################

        if ( $nic->{netdev} eq 'udp' ) {
            print "remote=$nic->{remote_host}.$nic->{remote_nic}";
            if ( $args{v} ) {
                my( $us, $them ) = (
                    "$nic->{local_ip}:$nic->{local_port}",
                    "$nic->{remote_ip}:$nic->{remote_port}" 
                );
                print " [", $us, '-->', $them, "]";
            }
        } 
        elsif ( $nic->{netdev} eq 'tap' ) {
            print "remote=$nic->{remote}";
        } 
        elsif ( $nic->{netdev} =~ m/^vde/ ) {
            print "remote=$nic->{remote_host}.$nic->{remote_nic}";
        }
        print "\n";
        $i++;
    }

    return( report_retval() );
}

1;
