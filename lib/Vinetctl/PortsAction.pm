package Vinetctl::PortsAction;

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

#use File::Compare;

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

use Vinetctl::AllAction qw( 
    get_all_topologies
);

use Vinetctl::Topology qw(
    open_topology_file
    create_topology
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    ports_action
);

# ports_action(): show free ports for udp socket backend
#########################################################

sub ports_action {
    report_calling_stack(@_) if $args{d};

    my @params = @{ $globals{action_params} };

    Die "usage: $rc{progname} $globals{action_name} NUM\n"
        if @params > 1;

    my $how_many = $params[0];
    say join( " ", get_free_ports($how_many) );

    return( report_retval() ); 
}

# get_free_ports(): given NUM as param, return NUM free udp ports 
##################################################################

sub get_free_ports { 
    report_calling_stack(@_) if $args{d};

    my $amount = shift // 10;      # defaults to 10
    $amount =~ m/\d+/ 
        or Die "$amount: not an integer\n";

    if ( $amount > 100 ) {         # maximum 100
        $amount = 100;
        Warn "$amount exceeds maximum: generating 100 free ports\n" 
            if $args{v};
    }

    # runcontrol sets the range of udp ports that we can use:
    my( $min, $max ) = ( $rc{sock_port_min}, $rc{sock_port_max} ); 

    # we'll store used and unused port numbers in these arrays:
    my ( @used, @free );

    # loop through all topology files, to gather a list of used ports
    ##################################################################

    TOP: foreach my $top ( @{ get_all_topologies() } ) {

        my $file;

        # use the user's copy if it exists, otherwise the base copy
        if ( -e "$rc{topology_dir}/$top" ) {
            $file = "$rc{topology_dir}/$top";
        }
        else { $file = "$rc{topology_base_dir}/$top" }

        unless ( -r $file ) {
            Warn "$file is not readable (private?)"; 
            next FILE; 
        }

        # open private topology file we just made, until program exits

        # loop through topology file, constructing the topology, and search
        # store the udp ports in our @used array
        ####################################################################

        my $fh = open_topology_file( $file );
        create_topology( $fh, $top );
        VM: foreach my $vm_ref ( @{ $globals{topology} } ) {

             foreach my $nic ( @{ $vm_ref->{nics} } ) {
                # $nic->{local_port} defined only for netdev=udp
                push @used, $nic->{local_port}
                    if defined( $nic->{local_port} ); 
            }

        }
        close $fh;

    }

    # map @used to %used, where $used{portnum} => 1 if port is in use
    ##################################################################

    my %used = map { $_ => 1 } @used; 

    # construct a list of $amount free ports
    #########################################

    PORT: for my $i ( $min .. $max ) {
        push @free, $i unless exists( $used{$i} );
        last if @free >= $amount;
    }

    return( report_retval(@free) );
}

1;
