package Vinetctl::Dialog;

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
use UI::Dialog; 
use Hash::Util qw( hash_locked unlock_value lock_value );
use File::Temp qw( tempfile );

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

use Vinetctl::Init qw(
    get_vm_list
    get_topology_name
);

use Vinetctl::RunningAction qw( 
    get_running_topologies
);

use Vinetctl::AllAction qw( 
    get_all_topologies
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    dialog
    dialog_choose_vms
    dialog_set_from_list
);

# dialog(): UI to some vinetctl actions 
########################################

sub dialog {
    report_calling_stack(@_) if $args{d};

    DIALOG: for (;;) {

        unlock_value( %globals, 'topology_name' ) 
            if hash_locked( %globals );
        $globals{topology_name} = get_topology_name();
        lock_value( %globals, 'topology_name' )
            if hash_locked( %globals );

        my $string = dialog_choose_action(); 
        return( report_retval($string) )

    }

}

sub dialog_choose_action {
    report_calling_stack(@_) if $args{d};

    my $action_menu = [
        'Running'
            => 'Select from running topologies', 
        'All' 
            => 'Select from all topologies',
        'Diagram'
            => 'Show diagram of current topology', 
        'Status' 
            => 'Check the status of some or all machines in current topology',
        'Connect'
            => 'Connect to console of machine in current topology', 
        'Show'
            => 'Show topology detail', 
        'Start'  
            => 'Start some or all machines in current topology', 
        'Stop' 
            => 'Stop (gracefully) some or all machines in current topology', 
        'Kill' 
            => 'Stop (ungracefully) some or all machines in current topology',
        'Monitor'
            => 'Connect to monitor of machine in current topology', 
        'Install'
            => 'Install an operating system', 
        'Standalone'
            => 'Run a standalone operating system', 
    ]; 

    # when we first enter the menu system, make sure we *have* a menu system:
    my $d;
    eval { $d = new UI::Dialog ( 
        backtitle => 'Vinetctl', 
        title => 'Action Menu',
        height => 18, 
        width => 100, 
        listheight => 16, 
        order => [ 'CDialog', 'Whiptail'], 
    ); }; 
    if ( $@ ) {
        my( $msg, undef ) = split( '\.', $@ );
        Die "no menu system available ($msg): -h for help\n";
    } 

    # TODO: string returns undefined when /tmp filesystem is full: very obscure!
    # make sure to check UI::Dialog's errors on this, probably get a 'no space'
    # type message
    my $string = 
        $d->menu( text => "Current topology: $globals{topology_name}           Select an action:",
                  list => $action_menu   );

    if ( $d->state() eq 'OK' ) { return( report_retval(lc $string) ) }
    if ( $d->state() eq 'CANCEL' ) { exit 0 }
    else { print "dialog menu returned nothing\n" }

#    return( report_retval(lc $string) );
}

sub dialog_set_from_list {
    report_calling_stack(@_) if $args{d};

#    my $output = shift;
#    my @list = split("\n", $output); 
    my $title = shift; 
    my @list = map { /^([a-zA-Z0-9_-]+)/ } @_;
    my $d; 

    if ( @list ) {
        my( @menulist, $item );
        for( my $i = 0; $i < @list; $i++ ) { 
            push @menulist, $list[$i], ''; 
        }
        $d = new UI::Dialog ( 
            backtitle => 'Vinetctl', 
            title => "$title", 
            height => scalar(@list)+8, 
            width => 40, 
            listheight => scalar(@list)+5, 
            order => [ 'CDialog', 'Whiptail'], 
        );
        my $choice =
            $d->menu( text => 'Select:',
                      list => \@menulist     ); 

        if    ( $d->state() eq 'CANCEL' ) { 
            return( report_retval('CANCEL') );
        }
        elsif ( $d->state() eq 'ESC' ) { 
            exit 0; 
        } 

        # snip off '(' and everything after:
        ( my $topology ) = split( '\(', $choice ); 
        return( report_retval($topology) ); 
    }
    else {
        $d->msgbox( text => "No topologies satisfied your query" );
        exit(0) unless $d->state() eq "OK"; 
        return( report_retval('CANCEL') );
    }
}

sub dialog_choose_vms {
    report_calling_stack(@_) if $args{d};

    # prompt user with checklist of machines
    ################################################

    my @check_list; 
    foreach my $vm ( @{ $globals{topology} } ) {
        push @check_list, $vm->{name}, 
            $globals{action_name} 
                =~ m/^(connect|monitor)$/ ? '' 
                                          : [ '', 1 ];
    }

    my $d = new UI::Dialog ( 
        backtitle => 'Vinetctl', 
        title => "Topology: $globals{topology_name}", 
        height => 25, 
        width => 80 , 
        listheight => 20, 
        order => [ 'CDialog', 'Whiptail'], 
    );

    # override previous setting for @{globals{vm_list}}, based on checklist
    ########################################################################

    if ( $globals{action_name} =~ m/^(connect|monitor)/ ) {
        @{ $globals{action_params} } = $d->menu( 
            text => "Select machines for action '$globals{action_name}':", 
            list => \@check_list 
        ); 
    }
    else {
        @{ $globals{action_params} } = $d->checklist( 
            text => "Select machines for action '$globals{action_name}':", 
            list => \@check_list 
        ); 
    }

    if    ( $d->state() eq 'CANCEL' or not @{ $globals{action_params} } ) { 
        return( report_retval('CANCEL') );
    }
    elsif ( $d->state() eq 'ESC' ) { 
        exit 0;
    }

    unlock_value( %globals, 'monitor_params' );
    $globals{monitor_params} = $globals{action_params} 
        if $globals{action_name} eq 'monitor';
    lock_value( %globals, 'monitor_params' );

    unlock_value( %globals, 'vm_list' );
    $globals{vm_list} = get_vm_list( @{ $globals{action_params} } ); 
    lock_value( %globals, 'vm_list' );

    if ( $globals{action_name} eq 'kill' ) { 
        # force if kill option, since user already chose vms
        $args{F} = 1; 
        $d = new UI::Dialog ( 
            backtitle => 'Vinetctl', 
            title => "Topology: $globals{topology_name}", 
            height => 10, 
            order => [ 'CDialog', 'Whiptail'], 
        );

        my $confirmed = $d->yesno( text => 
            "Killing machines: @{ $globals{action_params} }.\n\nConfirm: " 
        ); 
        unless ( $confirmed ) {
            $args{F} = 0;
            return( report_retval('CANCEL') ); 
        }
    }
}

#my @array = $d->ra();
#say {$log} foreach @array;
#
#my $string = $d->inputbox( text => 'Please enter some text...',
#                           entry => 'this is the input field' );
#
#@array = $d->ra();
#say {$log} foreach @array;
#
#$string = $d->password();
#
#$d->textbox( path => '/home/dale/bin/vinetctl' );
#

1;
