package Vinetctl::BasifyAction;

use strict;
use warnings;
use feature qw( say );
use File::Copy;

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

use Vinetctl::Util qw( 
    my_system
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    basify_action
);

# basify_action(): create a base image from a snapshot 
#######################################################

sub basify_action {
    report_calling_stack(@_) if $args{d};

    my $say_ok = 0;

    VM: foreach my $vm_ref ( grep {defined} @{ $globals{vm_list} } ) {

        # don't rebase images of running vms:
        if ( get_vm_status( $vm_ref ) ) {
            Warn( "$vm_ref->{name} is up: skipping\n" );
            next VM;
        }
        # can't rebase images that don't exist: 
        unless ( @{ $vm_ref->{images} } ) {
            Warn( "$vm_ref->{name}: no disk images: skipping\n" ); 
            next VM; 
        }
#        IMAGE: foreach my $image ( @{ $vm_ref->{images} } ) {
        my @images = @{ $vm_ref->{images} };
        IMAGE: for (my $i = 0; $i < @{ $vm_ref->{images} }; $i++ ) {
            my $base_image = ( split( /-/, $images[$i] ) )[0] . "-base.qcow2";
            my $src_file = -e "$rc{priv_base_img_dir}/$base_image" ?
                              "$rc{priv_base_img_dir}/$base_image"      :
                              "$rc{base_img_dir}/$base_image"; 
            unless ( -e $src_file ) {
                say "ASDF: src file: $rc{priv_base_img_dir}/$base_image"; 
                Warn( "cannot basify: $images[$i] doesn't exist\n");
                next IMAGE;
            }
            my $dst_file; 
            say "$vm_ref->{name}: processing image $images[$i]"; 
            NAME: {
                print "  Provide a name for the new base image: "; 
                chomp( my $image_name = <STDIN> ); 
                $image_name .= '-base.qcow2' unless $image_name =~ m/-base.qcow2$/;
                $dst_file = "$rc{priv_base_img_dir}/$image_name"; 
                if ( -e $dst_file ) { 
                    say "$dst_file exists"; 
                    redo NAME; 
                }
            }
            say "copying $src_file to $dst_file..."; 
            copy( $src_file, $dst_file ) or Die "copy failed: $!\n"; 
            my $cmd = "$rc{qemu_img} rebase -b $dst_file $rc{vm_img_dir}/$images[$i]";
            my_system( "$cmd >/dev/null 2>> $rc{log_file}" );
            $cmd = "$rc{qemu_img} commit $rc{vm_img_dir}/$images[$i] -d";
            print "Caution: $rc{vm_img_dir}/$images[$i] will be deleted!  Confirm: [yN] "; 
            chomp( my $resp = <STDIN> );
            say "Skipping." and next IMAGE unless $resp eq 'y'; 
            my_system( "$cmd >/dev/null 2>> $rc{log_file}" );
            $say_ok++;
        }
    }

    say "ok" if $say_ok;

    return( report_retval() );
}

1;
