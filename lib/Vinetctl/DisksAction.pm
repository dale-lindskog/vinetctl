package Vinetctl::DisksAction;

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

use Vinetctl::Util qw( 
    my_system
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    disks_action
);

# disks_action(): create some or all the topology's vm disk images
###################################################################

sub disks_action {
    report_calling_stack(@_) if $args{d};

    my $say_ok = 0;

    VM: foreach my $vm_ref ( grep {defined} @{ $globals{vm_list} } ) {
        $say_ok++ if disks_vm( $vm_ref ) 
    }

    say "ok" if $say_ok;

    return( report_retval() );
}

# disks_vm(): create a single vm image
#######################################

sub disks_vm {
    report_calling_stack(@_) if $args{d};

    my $vm_ref = shift;
    my $retval = 1;      # default unless changed below

    Warn "no disks for $vm_ref->{name}\n"
        unless @{ $vm_ref->{images} };

    foreach my $image ( @{ $vm_ref->{images} } ) {

        # figure out base file name from vm image file name
        ######################################################
        # NB: disk name of the form: OS-topology-vmname.qcow2
        # base disk name of the form: OS-base.qcow2
        ######################################################

        my @array = split( /[-.]/, $image );
        my $base = $array[0] . "-base." . $array[-1];
    
        # is the base image in our private base image directory?
        #########################################################

        my $base_image;
        if ( -e "$rc{priv_base_img_dir}/$base" ) { 
            $base_image = "$rc{priv_base_img_dir}/$base"
        } 
        elsif ( -e "$rc{base_img_dir}/$base" ) { 
            $base_image = "$rc{base_img_dir}/$base"; 
        } 
        else {
            Die   "base image '$base' " . 
                  "does not exist in either $rc{priv_base_img_dir} " .
                  "or $rc{base_img_dir}\n"
                unless $args{b};
        }

        # create the image
        ###################

        if ( -e "$rc{vm_img_dir}/$image" ) {
            Warn "$image: already exists\n";
            $retval = 0;
        }
        elsif ( $args{n} ) {                      # pretend mode
            if ( -e "$rc{vm_img_dir}/$image" ) {
                Warn "$image: already exists\n";
            }
            elsif ( -e $base_image ) {
                say "+${image}(pretend)";
            }
            elsif ( $args{b} ) {
                say "+${image}(pretend)";
            }
            else {
                Warn "base image $base_image doesn't exist\n";
            } 
        }
        elsif ( not $args{b}) {    # really do it
            -e $base_image 
                or Die "base image $base_image doesn't exist\n";
            -r _ 
                or Die "base image $base_image isn't readable\n";

            my $cmd = "$rc{qemu_img} create -f qcow2 " . 
                      "-b $base_image $rc{vm_img_dir}/$image";
            my_system( "$cmd >/dev/null 2>> $rc{log_file}" );

            ( $? == 0 ) 
                or Die "image create failed: system() exited with: $?\n";

            if ( $args{v} ) { say "+${image}" }
            else            { print "." }
        }
        else {                     # make it a base image
            print "$globals{topology_name}: $vm_ref->{name}: ", 
                  "specify disk size in MB: "; 
            chomp( my $size = <STDIN>); 

            my $cmd =   "$rc{qemu_img} create -f qcow2 "
                      . "$rc{vm_img_dir}/$image ${size}m";
            my_system( "$cmd >/dev/null 2>> $rc{log_file}" );

            ( $? == 0 ) 
                or Die "image create failed: system() exited with: $?\n";

            if ( $args{v} ) { say "+${image}" }
            else            { print "." }
        }

    }

    return( report_retval($retval) );
}

1;
