package Vinetctl::DestroyAction;

use strict;
use warnings;
use feature qw( say );
use File::Basename;
use File::Path qw( remove_tree );

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
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    destroy_action
);

# destroy_action(): delete some or all of topology's vm disk image files
#########################################################################

sub destroy_action {
    report_calling_stack(@_) if $args{d};

    my $say_ok = 0;

    # make sure they aren't running first
    ######################################

    unless ( $args{n} ) {
        Die "$globals{topology_name}: vms are up; stop them first\n"
            if grep { get_vm_status($_) if defined } @{ $globals{vm_list} };
    }

    # confirm
    ###########

    unless ( $args{F} ) {
        print "Confirm: destroy these machine images? [y/n]: ";
        chomp( my $answer = <STDIN> );
        say "abort" and exit 0 unless $answer eq "y";
    }

    # unlink vm images and sockets:
    ################################

    VM: foreach my $vm_ref ( grep {defined} @{ $globals{vm_list} } ) {

        # destroy this vm's socket, if it exists
        my $socket = 
            "$rc{socket_dir}/$globals{topology_name}/$vm_ref->{name}";
        unless ( $args{n} ) {
            unlink "$socket" or Die "cannot unlink $socket: $!\n"
                if -e "$socket";
        }

        # destroy this vm's image, if it exists
        foreach my $image ( @{ $vm_ref->{images} } ) {
            $image = "$rc{vm_img_dir}/$image"; 
            if ( -e "$image" ) {
                if ( $args{n} or unlink($image) ) { # if successful, then ...
                    ++$say_ok;
                    if ( $args{v} ) {
                        my $img = basename($image);
                        print "-$img", 
                              $args{n} ? "(pretend)\n" : "\n";
                    } 
                    else { print "." }
                } 
                else {  Warn "could not unlink $image: $!\n" }
            } else { Warn "$image doesn't exist\n" }
        }
    }

    my @dirs = (
        "$rc{socket_dir}/$globals{topology_name}",
        "$rc{pid_dir}/$globals{topology_name}",
        "$rc{vde_dir}/$globals{topology_name}",
        "$rc{wirefilter_dir}/$globals{topology_name}",
## we don't want to rm this dir, cuz we often have to
## destroy the snapshot disks to successfully restore
## from migrated files:
#        "$rc{migrate_in_dir}/$globals{topology_name}",
        "$rc{migrate_out_dir}/$globals{topology_name}",
        "$rc{history_dir}/$globals{topology_name}",
        "$rc{autostart_base_dir}/$globals{topology_name}",
        "$rc{stderr_dir}/$globals{topology_name}",
    );

    remove_tree( @dirs, { safe => 1 } )
        unless $args{n};
    say "ok" if $say_ok;

    return( report_retval() );
}

1;
