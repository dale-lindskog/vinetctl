package Vinetctl::Wires;

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
use constant { TRUE => 1, FALSE => 0 };
use IO::Socket::UNIX qw( SOCK_STREAM );
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
    Die
    Warn
);

use Vinetctl::Util qw(
    get_uniq
);

use Vinetctl::StatusAction qw(
    get_vm_status
);

use Vinetctl::StopSaveSuspendResumeAction qw(
    stop_nic_vde
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    destroy_dead_wires
);

# list_dead_wires(): populate two arefs with lists of dead vde related procs
#############################################################################

sub list_dead_wires {
    report_calling_stack(@_) if $args{d};

    # caller gives two arefs as arguments, which we populate: 
    ##########################################################

    my( $dead_vdeswitches, $dead_wirefilters ) = @_; 

    # as usual, if vms specified on cmdline, we check only those
    #############################################################

    my @specified_vms = grep {defined} @{ $globals{vm_list} };

    # loop through vms, check their vde_switches or wirefilters
    ############################################################

    VM: foreach my $vm_ref ( @specified_vms ) {

        NIC: foreach my $nic ( @{ $vm_ref->{nics} } ) {

            next NIC unless $nic->{netdev} =~ m/^vde/;

            # name of the vde switch: 
            my $vde_wire = basename( $nic->{vde_wire} );

            # vde and wirefilter always connect two vms: discover their
            # names for this particular nic:
            ############################################################

            my( $vm1, $vm2 ) = ( $vm_ref->{name}, $nic->{remote_host} );

            # add vde switch and wirefilter if both vms were specified, 
            # on the cmdline, implicitly or explicitly
            ############################################################

            if (          grep { $_->{name} eq $vm1 }  @specified_vms
                  and     grep { $_->{name} eq $vm2 }  @specified_vms     )
            { 
                # both sides were indeed specified on cmdline, so add the vde
                push( @{$dead_vdeswitches}, $vde_wire );

                # add the wirefilter too if we're using it
                push( @{$dead_wirefilters}, basename($nic->{wirefilter}) )
                    if $nic->{netdev} eq 'vde++';
            } 
            elsif ( $nic->{netdev} eq 'vde++' ) { 

                # for vde++, and regardless of whether both vms were 
                # specified, add the vde switch and wirefilter
                #####################################################

                push( @{$dead_vdeswitches}, $vde_wire );
                push( @{$dead_wirefilters}, basename($nic->{wirefilter}) );

            }

        }      # end NIC loop

    }     # end VM loop

#    # add more vdes that satisfy various criteria
#    ##############################################
#
#    VM: foreach my $vm_ref ( @{ $globals{topology} } ) { 
#
#        # loop through nics, add associated vde/wirefilter as appropriate
#        ##################################################################
#
#        NIC: foreach my $nic ( @{ $vm_ref->{nics} } ) { 
#
#            next NIC unless $nic->{netdev} =~ m/^vde/;
#
#            # name of the vde switch: 
#            my $vde_wire = basename( $nic->{vde_wire} );
#
#            # wirefilter prep
#            my $wirefilter = basename( $nic->{wirefilter} );
#
#            # vde and wirefilter always connect two vms: discover their
#            # names for this particular nic:
#            ###########################################################
#
#            my( $vm1, $vm2 ) = ( $vm_ref->{name}, $nic->{remote_host} );
#
#            # by default, we don't add them
#            ################################
#
#            my $add_vde = FALSE;  
#            my $add_wirefilter = FALSE;
#
#            # queue to add if one end was identified and other end is down
#            ###############################################################
#
#            if (        grep { $_ eq $vm1 } @specified_vms
#                    and not get_vm_status(get_vmref_by_name($vm2))    )
#            { 
#                print "DEBUG: TRUE in if\n";
#                $add_vde = TRUE;
#                $add_wirefilter = TRUE 
#                    if $nic->{netdev} eq 'vde++';
#            }
#            elsif (     grep { $_ eq $vm2 } @specified_vms
#                    and not get_vm_status(get_vmref_by_name($vm2))  )
#            { 
#                print "DEBUG: TRUE in elsif1\n";
#                $add_vde = TRUE;
#                $add_wirefilter = TRUE 
#                    if $nic->{netdev} eq 'vde++';
#            }
#
#            # queue for adding if vms on both ends are down
#            ################################################
#            # NOTE: sanity check: should already be dead
#            ################################################
#
#            elsif (     not get_vm_status(get_vmref_by_name($vm1)) 
#                    and not get_vm_status(get_vmref_by_name($vm2))  )
#            { 
#                my $VM1 = get_vmref_by_name($vm1);
#                my $VM2 = get_vmref_by_name($vm2);
#                print "DEBUG: TRUE in elsif2 for $VM1->{name} / $vm1 and $VM2->{name} / $vm2\n";
#                $add_vde = TRUE;
#                $add_wirefilter = TRUE 
#                    if $nic->{netdev} eq 'vde++';
#            }
#
#            # add if queued: 
#            #################
#
#            print "DEBUG: adding dead $vde_wire\n";
#            push( @{$dead_vdeswitches}, $vde_wire )   if $add_vde;
#            print "DEBUG: adding dead $wirefilter\n";
#            push( @{$dead_wirefilters}, $wirefilter ) if $add_wirefilter;
#        }
#    }

    # get rid of duplicates
    ########################

    $dead_vdeswitches = get_uniq( $dead_vdeswitches );
    $dead_wirefilters = get_uniq( $dead_wirefilters );

    return( report_retval() );
}

# destroy_dead_wires(): destroy a list of vde switches and wirefilters
#######################################################################

sub destroy_dead_wires {
    report_calling_stack(@_) if $args{d};

    # find out what we should destroy
    ##################################

    my( @dead_vde_wires, @dead_wirefilters );
    list_dead_wires( \@dead_vde_wires, \@dead_wirefilters );

    # destroy the vde switches
    ###########################

    VDE: foreach my $wire ( @dead_vde_wires ) {
        my $ctl_file = "$rc{vde_dir}/$globals{topology_name}/${wire}.ctl";
        unless ( -e "$ctl_file" ) {
            Warn " $ctl_file doesn't exist\n" if $args{d};
            next VDE;
        }
        if ( $args{v} ) {
            print " -${wire} ", $args{n} ? "(pretend)\n" : "\n";
        }
        unless ( $args{n} ) {
            stop_nic_vde( $wire );
        }
        unless ( remove_tree("$ctl_file", {error => \my $err}) ) {
            if ( $err &&  @$err && $args{d} ) {   # remove_tree() error msgs
                foreach my $diag ( @$err ) {
                    my( $file, $message ) = %$diag;
                    if ( $file eq '' ) {
                        Warn "remove_tree(): general error: $message\n";
                    } 
                    else {
                        Warn "remove_tree(): ", 
                             "problem unlinking $file: $message\n";
                    }
                }
            }
        }
    }

    # destroy the wirefilters
    ##########################

    WIREFILTER: foreach my $wirefilter ( @dead_wirefilters ) {
        my $mgmt_file = 
            "$rc{wirefilter_dir}/$globals{topology_name}/${wirefilter}.mgmt";
        unless ( -e $mgmt_file ) {
            Warn "$mgmt_file doesn't exist\n" if $args{d};
            next WIREFILTER;
        }
        if ( $args{v} ) {
            print " -${wirefilter} ", $args{n} ? "(pretend)\n" : "\n";
        }
        unless ( $args{n} ) {
            stop_wirefilter( $mgmt_file );
        }
    }

    return( report_retval() );
}

# stop_wirefilter(): stop an individual wirefilter process
###########################################################

sub stop_wirefilter {
    report_calling_stack(@_) if $args{d};

    # send the shutdown command to the management socket
    #####################################################

    my $mgmt_file = shift;
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

    return( report_retval() );
}

1;
