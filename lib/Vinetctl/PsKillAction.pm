package Vinetctl::PsKillAction;

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
use constant { TRUE => 1, FALSE => 0 };
use File::Basename;

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
    get_uid
);

use Vinetctl::StatusAction qw(
    get_vm_status
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    ps_kill_action
);

# ps_kill_action(): either show ps(1) output of, or kill, vms in topology 
##########################################################################

sub ps_kill_action {
    report_calling_stack(@_) if $args{d};

    Die "-n switch not valid for $globals{action_name}\n" 
        if $args{n};

    my( $ProcessTable, $pid, $output, $answer ) =
      ( TRUE,          0,    undef,   'n'     );

    my @output;

    my $using_vde = FALSE;                   # toggle on if we find a vde nic
    my @vde_wires;                           # vde wires to use in ps search

    # loop through vms in topology
    ###############################

    print "$globals{topology_name}: " 
        if $globals{action_name} eq 'kill';

    # @confirmed_kills: 
    # later we populate @confirmed_kills array with vms for which user 
    # confirmed a kill; still later we set 
    #     @{$globals{vm_list} = @confirmed_kills
    # if action was kill, and $args{F} was not set
    ###################################################################

    my @confirmed_kills; 

    VM: foreach my $vm_ref ( grep {defined} @{ $globals{vm_list} } ) {

        # vde check: toggle $using_vde on if this vm is using vde
        ##########################################################

        NIC: foreach my $nic ( @{ $vm_ref->{nics} } ) {
            if ( $nic->{netdev} =~ m/^vde/ ) {
                $using_vde = TRUE;
                # need this list to find vde_switch processes
                push @vde_wires, $nic->{vde_wire};
                push @vde_wires, $nic->{wirefilter}
                    if $nic->{netdev} eq 'vde++';
            }
        }

        my $pidfile = 
            "$rc{pid_dir}/$globals{topology_name}/$vm_ref->{name}";

        # try to get pid first the easy way: from qemu's pid file
        ##########################################################

        if ( open(my $fh, '<', $pidfile)  ) {
            chomp( $pid = <$fh> );
            chomp( $output = `$rc{ps} -uwwp $pid` );
            close $fh; 
            # two lines: header \n pid info:
            my @lines = split( /\n/, $output ); 
            unless ( @lines == 2 ) {  # no cmdline, stale pidfile
                print "$vm_ref->{name}(down) ";
                say "[deleting stale pidfile $pidfile]"
                    if $args{v};
                unlink( $pidfile ) 
                    or Warn "could not unlink stale pidfile $pidfile: $!\n";
                next VM;
            }
            $output = $lines[1];   # get rid of the header
        } 
        # no pidfile; should be down:
        ##############################
        elsif ( get_vm_status($vm_ref) ) { 
            # stats as up: wtf?
            Warn "$vm_ref->{name}: ", 
                 "is up but open() on pidfile failed.\n";
            $pid = 0;                        # dummy value
        } 
        # stats as down, skip
        ######################
        else { 
            print "$vm_ref->{name}(down) ";
            next VM;
        }

        # check for Proc::ProcessTable
        ###############################

        unless ( eval {require Proc::ProcessTable} ) { 
            Warn "Proc::ProcessTable unavailable\n" 
                if $args{d};
            $ProcessTable = FALSE;
        }

        # search thru Proc::ProcessTable if we didn't get pid from pidfile
        ###################################################################

        if ( $pid == 0 ) {
            if ( $ProcessTable ) { 
                ($pid, $output) = get_proc_vm( $vm_ref );
            } 
            else { 
                Warn "$vm_ref->{name}: ProcessTable unavailable too\n";
            }
        }

        # give up: cannot get pid from pidfile or ProcessTable
        #######################################################

        if ( $pid == 0 ) {
            Warn "$vm_ref->{name}: process not found\n";
            next VM;
        }

        # if we're here, we need to either kill or show the vm process
        ###############################################################

        if ( $globals{action_name} eq 'kill' ) {

            # KILL: get confirmation from user, unless forced
            ##################################################

            unless ( $args{F} ) { 
                print "\n$vm_ref->{name}: pid: $pid\n", 
                      '-' x length( $vm_ref->{name} ),
                      "\n$output\n",
                      "\nReally kill pid $pid? [n] ";
                chomp( $answer = <STDIN> );
                push @confirmed_kills, $vm_ref if $answer eq 'y';
                print "\n";
            }

            if ( $answer eq 'y' or $args{F} ) {

                # user confirmed, or kill forced, so kill
                ##########################################

                kill 'KILL', $pid;
                my $pid =
                    "$rc{pid_dir}/$globals{topology_name}/$vm_ref->{name}";
                unlink $pid or Die "couldn't unlink $pid: $!\n";

                if ( $args{F} ) { print "$vm_ref->{name} " }

            } 
            else { 

                # user didn't confirm, and kill not forced, skip
                #################################################

                say "skipping kill on $vm_ref->{name}($pid)" 
            }

        } 
        else {                

            # ps action: no need to confirm, just do it
            #####################################

            push( @output, sprintf( "%s%s", "\n$vm_ref->{name}:",
                                              "\n $output\n" )     ); 
        }
    }     # VM loop ends here


    # tack on to output the list of vde_switch processes
    # but only in verbose mode, and only if topology uses vde
    ##########################################################

    my $vde_output = 
        ($args{v} and $using_vde) ? get_proc_vde( \@vde_wires ) : 0; 

    push @output, @{ $vde_output } if $vde_output; 

    # print output
    ###############

    say @output if $globals{action_name} eq 'ps';
    say "ok" if $globals{action_name} eq 'kill';

    # set @{ $globals{vm_list} } to @confirmed_kills for benefit of 
    # cleaning wires;
    # TODO: this is a hack
    @{ $globals{vm_list} } = @confirmed_kills 
        if $globals{action_name} eq 'kill' and not $args{F};

    # sleep 1 second before cleaning wires
    sleep 1;

    return( report_retval() );
}

# get_proc_vm(): input a vm, get a pid and cmdline
###################################################

sub get_proc_vm { 
    report_calling_stack(@_) if $args{d};

    my( $vm_ref, $uid, $proc_tbl ) =
        ( shift, get_uid($rc{username}), Proc::ProcessTable->new() );

    # make sure we can get a pid filed from ProcessTable
    #####################################################

    my @fields = grep { defined } $proc_tbl->fields;
    grep { /pid/ } @fields and grep { /cmndline/ } @fields
        or Warn "Proc::ProcessTable failed to return pid field"; # die?

    # search through the process table looking for this vm
    #######################################################

    my( $proctbl_pid, $cmdline );
    PROC: foreach my $p ( @{$proc_tbl->table} ) {

        # cmdline and pid for this entry in the process table
        $cmdline = sprintf("%s", $p->cmndline);
        $proctbl_pid = sprintf("%s", $p->pid);

        # ignore jails (assuming jail 0)
        if ( grep { /jid/ } @fields ) { next PROC unless $p->jid == 0 }

        # skip this entry unless it matches vm (but ignore false positives) 
        ####################################################################

        unless ( $p->uid == $uid                                and 
                 $cmdline =~ m/$vm_ref->{name}/                 and
                 $cmdline =~ m/\Q$globals{topology_name}\E/     and 
                 $cmdline !~ m/^(bash|ksh|sh)/                  and
                 $cmdline !~ m/perl/                                ) 
        { 
            # set pid to 0, and cmdline to "" for this vm if no match
            ( $proctbl_pid, $cmdline ) = ( 0, "" ); 

            # and try the next entry in the process table
            next PROC;
        }

        # if we get here we've found the process table entry for this vm
        #################################################################

        last;
    }

    return( report_retval($proctbl_pid, $cmdline) );
}

# get_proc_vde(): return pid and commandline for vde_switches
##############################################################

sub get_proc_vde { 
    report_calling_stack(@_) if $args{d};

    my $wires_aref = shift;
    my( @procs, $output );

    # get the pids and ps output
    #############################

    # get the pidfile name
    my @pidfiles = map { "$_.pid" } @$wires_aref; 

    # loop through the pidfiles, grab pid
    ######################################

    PIDFILE: foreach my $pidfile ( @pidfiles ) {

        my $fh;
        unless ( open($fh, '<', $pidfile) ) {
            Warn "cannot open $pidfile: $!\n"
                if $args{d};
            next PIDFILE;
        }
        my $pid;
        chomp( $pid = <$fh> );
        chomp( $output = `$rc{ps} -uwwp $pid` );
        close $fh; 
        my @lines = split( /\n/, $output );    # two lines: header + pid
        unless ( @lines == 2 ) {  # no cmdline, stale pidfile
            print "$pid not found";
            say " [deleting stale pidfile $pidfile]"
                if $args{v};
            unlink( $pidfile ) 
                or Warn "could not unlink stale pidfile $pidfile: $!\n";
            next;
        }
        $output = $lines[1];   # get rid of the header
        my $name = basename( $pidfile, ".pid" );
        push @procs, "\n$name:\n $output\n";

    }

    return( report_retval(\@procs) );
}

1;
