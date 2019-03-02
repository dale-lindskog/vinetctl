package Vinetctl::RmcableAction;

use strict;
use warnings;
use feature qw( say state );
use constant { TRUE => 1, FALSE => 0 };
use IO::Socket::UNIX qw( SOCK_STREAM );

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
);

use Vinetctl::StopSaveSuspendResumeAction qw(
    send_cmd_qemu_monitor
    stop_nic_vde
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    rmcable_action
);

# rmcable_action(): disable a nic on a vm
##########################################

sub rmcable_action {     # TODO: should get rid of this action
    report_calling_stack(@_) if $args{d};

    my @rmcable_params = @{ $globals{rmcable_params} };

    unless (     @rmcable_params == 1 
             and scalar grep {defined} @{ $globals{vm_list} } == 1 )
    {
        Die "usage: $rc{progname} [-f TOP ] ", 
            "$globals{action_name} vm[:nic]\n"; 
    }

    my $did_something = FALSE;
    my( $nic_name, @pretends );

    VM: foreach my $vm_ref ( grep {defined} @{ $globals{vm_list} } ) {
        # (should only be one vm in the list for now)

        Warn "$vm_ref->{name}:down" and next 
            unless get_vm_status( $vm_ref );

        Die "$vm_ref->{name} has no nics\n" 
            if @{ $vm_ref->{nics} } == 0;

        PARAM: foreach my $param ( @rmcable_params ) {
            if ( $param =~ /$vm_ref->{name}:/ ) {
                # nic specified on command line
                ( undef, $nic_name ) = split(/:/, $param);
            } 
            else {
                # prompt for nic
                print "$vm_ref->{name}: ", 
                      "specify nic from which to pull cable: ";
                chomp( $nic_name = <STDIN> );
                $nic_name =~ s/nic/e/;

            }

            unless ( grep {$_->{name} eq $nic_name} @{$vm_ref->{nics}} ) {
                Warn "$vm_ref->{name}:$nic_name: no such nic\n";
                next PARAM;
            }

            # pull local end of cable
            if ( $args{n} ) { push @pretends, "$vm_ref->{name}:$nic_name" }
            else            { vm_rmcable( $vm_ref, $nic_name ) }

            # does the the user want to pull cable at the other end too?
            my( $remote_vm, $remote_nic_name ) =
                get_remote_port( $vm_ref, $nic_name );
            unless ( $args{F} ) {
                print "Confirm: disable other end (", $remote_vm->{name}, 
                      ":", $remote_nic_name, ")? [y/n]";
                chomp( my $answer = <STDIN> );
                next VM unless $answer eq 'y';
            }

            # pull remote end of cable
            if ( $args{n} ) {
                push @pretends, "$remote_vm->{name}:$remote_nic_name"
            } 
            else { vm_rmcable( $remote_vm, $remote_nic_name ) }
            $did_something = TRUE unless $args{n};
        }

    }


    # report what was done
    say "would pull cable from: @pretends" if $args{n};
    say "ok" if $did_something;

    return( report_retval() );
}

# vm_rmcable(): use qemu monitor to disable a nic
##################################################

sub vm_rmcable { 
    report_calling_stack(@_) if $args{d};

    # determine which vm and nic to operate on
    my ($vm_ref, $nic_name) = @_;

    # the qemu monitor command we'll use:
    my $cmd = "netdev_del $nic_name\n";

    my $retval = 1;      # default

    unless ( send_cmd_qemu_monitor("$cmd\n", $vm_ref) ) {
        Warn "$vm_ref->{name}: cannot remove cable: no socket\n" 
            if $args{d};
        $retval = 0;     # failure
    }

    return( report_retval($retval) );
}

# get_remote_port(): takes a nic and returns the vm hashref and nic name
#########################################################################

sub get_remote_port { 
    report_calling_stack(@_) if $args{d};

    my( $vm_ref, $nic_name ) = @_;
    my @retval = ();     # default, potentially changed below

    # find nic named $nic_name
    ###########################

    NIC: foreach my $nic ( @{ $vm_ref->{nics} } ) { 

        next unless $nic->{name} eq $nic_name;

        # find this vm's remote vm
        ###########################

        REMOTE_VM: foreach my $remote_vm ( @{ $globals{topology} } ) {
            next unless $remote_vm->{name} eq $nic->{remote_host};

            # find the remote vm's connected nic
            #####################################

            REMOTE_NIC: foreach my $remote_nic ( @{ $remote_vm->{nics} } ) {
                next unless $remote_nic->{name} eq $nic->{remote_nic};
                @retval = ( $remote_vm, $remote_nic->{name} );
            }
        }

    }

    return( report_retval(@retval) );
}

1;
