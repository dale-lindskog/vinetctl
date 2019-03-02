package Vinetctl::StopSaveSuspendResumeAction;

use strict;
use warnings;
use feature qw( say );
use IO::Socket::UNIX qw( SOCK_STREAM );

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

use Vinetctl::StatusAction qw(
    get_vm_status
    vm_save_status
    get_monitor_sock
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    stop_save_suspend_resume_action
    send_cmd_qemu_monitor
    stop_nic_vde
);

# stop_save_suspend_resume_action(): combo sub because all these are similar
#############################################################################

sub stop_save_suspend_resume_action {
    report_calling_stack(@_) if $args{d};

    Die "-n switch not valid for $globals{action_name}\n" 
        if $args{n};

    my $ok = 0;     # flag

    # output
    print "$globals{topology_name}: ";

    foreach my $vm_ref ( grep {defined} @{ $globals{vm_list} } ) {

        # only kill if vm is up, unless force (-F) specified
        unless ( get_vm_status($vm_ref) ) {
            print "$vm_ref->{name}(down)  ";
            next;
        }

        # call appropriate subroutine, depending on action
        ###################################################

        if ( $globals{action_name} eq 'stop' ) {
            vm_stop( $vm_ref ); 
            $ok++;
        }
        elsif ( $globals{action_name} eq 'save' ) {
            if ( $args{m} ) { vm_migrate( $vm_ref ) }
            else            {    vm_save( $vm_ref ) }
            $ok++;
        }
        elsif (    $globals{action_name} eq 'suspend'
                or $globals{action_name} eq 'pause'   ) 
        {
            vm_suspend( $vm_ref ); 
            $ok++; 
        }
        elsif ( $globals{action_name} eq 'resume' ) {
            vm_resume( $vm_ref );
            $ok++; 
        }
        else {
            Die "BUG: $globals{action_name} shouldn't occur here";
        }

        # output:
        print "$vm_ref->{name} "; 

    }

    # output:
    if ( $ok ) { say "ok" }
    else       { say "nothing to do" }

    return( report_retval() );
}

# vm_suspend(): pause the vm
#############################

sub vm_suspend { 
    report_calling_stack(@_) if $args{d};

    my $vm_ref = shift;
    my $cmd = "stop\n";       # qemu monitor command to pause vm
    my $retval = 1;           # default

    die "$vm_ref->{name} is already suspended\n"
        if get_vm_status( $vm_ref ) eq 'paused';

    unless ( send_cmd_qemu_monitor("$cmd\n", $vm_ref) ) {
        Warn "$vm_ref->{name}: cannot suspend: no socket\n" if $args{d};
        $retval = 0;
    }

    return( report_retval($retval) );
}

# vm_resume(): unpause the vm
###############################

sub vm_resume { 
    report_calling_stack(@_) if $args{d};

    my $vm_ref = shift; 
    my $cmd = "cont\n";       # qemu monitor command to resume vm
    my $retval = 1;           # default

    die "$vm_ref->{name} is already running\n"
        if get_vm_status( $vm_ref ) eq 'running';

    unless ( send_cmd_qemu_monitor("$cmd\n", $vm_ref) ) {
        Warn "$vm_ref->{name}: cannot resume: no socket\n" if $args{d};
        $retval = 0;
    }

    return( report_retval($retval) );
}

# vm_stop(): shutdown specified vm
###################################

sub vm_stop { 
    report_calling_stack(@_) if $args{d};

    my $vm_ref = shift;
    my $retval = 1;

    my $cmd;
    $cmd = "system_powerdown\n" if $vm_ref->{powerd} eq 'powerdown';
    $cmd = "quit\n"             if $vm_ref->{powerd} eq 'quit';

    unless ( send_cmd_qemu_monitor("$cmd\n", $vm_ref) ) {
        Warn "$vm_ref->{name}: cannot stop: no socket\n" if $args{d};
        $retval = 0;
    }

    return( report_retval($retval) );
}

# vm_migrate(): save a migration file
######################################

sub vm_migrate { 
    report_calling_stack(@_) if $args{d};

    my $vm_ref = shift;
    my $retval = 1;
    my $migrate_file = 
        join('/', $rc{migrate_out_dir},
                  $globals{topology_name}, 
                  "$vm_ref->{name}.gz"
        );

    # send migrate command to vm monitor
    #####################################

    my $cmd = "migrate -d -i \"exec:gzip -c > $migrate_file\"" ;
    unless ( send_cmd_qemu_monitor("$cmd\n", $vm_ref) ) {
        Warn "$vm_ref->{name}: cannot save migrate file: no socket\n" 
            if $args{d};
        $retval = 0;
    }

    return( report_retval($retval) );
}

# vm_save(): save mem state of specified vm
############################################

sub vm_save { 
    report_calling_stack(@_) if $args{d};

    my $vm_ref = shift;                      # the vm we're working with
    my $num_saved = 
        scalar vm_save_status($vm_ref);      # number of mem saves already
    my $suffix = 0;                          # suffix for save identifier
    my $retval = 1;                          # assume success

    # number of mem state saves is finite, so see if we're maxed out
    #################################################################

    if ( $num_saved < $rc{max_vm_saves} ) {

        # then we have room: just do an additional save:
        #################################################

        $suffix = ++$num_saved; 
    } 
    else { 

        # we're at max saves already: overwrite oldest save
        ####################################################

        # saved_vms() returns hashref mapping names to dates
        my $saved_vms = saved_vms( $vm_ref );

        # get the oldest save date from $name2date
        my @sorted = sort { $a <=> $b } values %{$saved_vms};
        my $oldest = $sorted[0];

        # associate that oldest save date with a suffix
        foreach my $key ( keys %{$saved_vms} ) {
            $suffix = $key and last
                if $saved_vms->{$key} == $oldest;
        }

    }

    # finally, we save the memory using the identify we constructed above
    ######################################################################

    unless ( send_cmd_qemu_monitor("savevm saved${suffix}\n", $vm_ref) ) {
        Warn "$vm_ref->{name}: cannot save: no socket\n" if $args{d};
        $retval = 0;
    }

    return( report_retval($retval) );
}

# send_cmd_qemu_monitor(): run cmd in qemu monitor, returns socket on success
##############################################################################

sub send_cmd_qemu_monitor { 
    report_calling_stack(@_) if $args{d};

    my $cmd = shift;          # what we'll send to the qemu monitor
    my $vm_ref = shift;       # what vm we'll talk to
    my $sock;
    my $retval = 1;           # dummy retval

    $retval = 0 
        unless $sock = get_monitor_sock( $vm_ref->{name}, 'vm' );

    print { $sock } $cmd;
    # sometimes we need to bash at the socket a bit:
    for ( 0 .. 1 ) { <$sock> }

    return( report_retval($retval ? $sock : $retval) );
}

# saved_vms(): return a hashref of the form: saved_vm_name => date
###################################################################

sub saved_vms { 
    report_calling_stack(@_) if $args{d};

    my %name2date;  # what we return

    # using %name2date, associate saved date (seconds) with saved vm name
    ######################################################################

    my $vm_ref = shift;
    my $num_saved = vm_save_status($vm_ref);
    my @qemu_info_json =
        `qemu-img info --force-share --output=json $rc{vm_img_dir}/$vm_ref->{images}->[0]`;
    my $counter = 0;
    my $suffix;
    JSON: foreach my $line ( @qemu_info_json ) { 

        # get to a saved vm name, or a saved date
        next unless $line =~ m/\"name\": \"saved+(\d+)\",/
                or  $line =~ m/\"date-sec\": (\d+),/;

        # record the name suffix
        $suffix = $1 if $line =~ m/\"name\": \"saved(\d+)\",/;

        # record the saved date
        $name2date{$suffix} = $1 if $line =~ m/\"date-sec\": (\d+),/;

        # escape loop if we got all the saves
        last if ++$counter == $num_saved;

    }

    return( report_retval(\%name2date) );
}

# stop_nic_vde(): graceful shutdown of a vde_switch process
############################################################

sub stop_nic_vde {
    report_calling_stack(@_) if $args{d};

    my $wire = shift;    # name of switch passed as parameter
    my $retval = 1;      # default unless changed below
    my $mgmt_file = "$rc{vde_dir}/$globals{topology_name}/${wire}.mgmt";

    if ( not -e $mgmt_file ) {
        Warn "cannot shutdown vde: $mgmt_file doesn't exist\n"
            if $args{v};
        $retval = 0;
    }
    else {
        my $sock = IO::Socket::UNIX->new(        # failure is normal
            Type => SOCK_STREAM,
            Peer => $mgmt_file,
        ) or $args{d} and Warn "IO::Socket::UNIX->new() failed: $!\n";

        if ( $sock ) {
            print { $sock } 'shutdown' if $sock;
            # bash at the socket a bit
            foreach my $i ( 0 .. 1 ) { <$sock> }
        }

        if ( $args{d} ) {
            unlink( $mgmt_file ) 
                or Warn "couldn't unlink $mgmt_file: $!\n";
        }
    }
    
    return( report_retval($retval) );
}

1;
