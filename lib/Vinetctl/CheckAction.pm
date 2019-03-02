package Vinetctl::CheckAction;

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
    %globals
    %args 
);

use Vinetctl::Debug qw( 
    report_calling_stack
    report_retval
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    check_action
);

# check_action(): sanity check on topology
######################################################################
# NOTE: if -v is set, this sub prints the data structs for each vm;
# otherwise it does nothing, since checks automatic when the topology
# is constructed, and the prog dies on errors
######################################################################

sub check_action {
    report_calling_stack(@_) if $args{d};

    return( report_retval() ) unless $args{v};    # see NOTE above

    # -v set, so loop through data structure and print
    ###################################################

    VM: foreach my $vm_ref ( grep {defined} @{ $globals{vm_list} } ) {

        # first the name and console display type: 
        say "name:$vm_ref->{name}";
        say " display:$vm_ref->{display}->{name}";

        # second the disk images:
        my @images = @{ $vm_ref->{images} };
        IMAGE: for my $i ( 0 .. $#{images} ) {
            say " image${i}:$images[$i]";
        }

        # third, everything else except the above, and the nics (below):
        foreach my $key ( sort keys %{$vm_ref} ) { 
            next if grep { $_ eq $key } qw( name nics display images );
            say " $key: ", $vm_ref->{$key} // 'UNDEFINED';
        }

        # fourth, the nic specific data
        NIC: foreach my $nic ( @{ $vm_ref->{nics} } ) {
            say " nic_name:$nic->{name}:";
            foreach my $key ( sort keys %{$nic} ) {
                next if $key eq 'name';
                say "   $key:$nic->{$key}";
            }
        }

    }

    return( report_retval() );
}

1;
