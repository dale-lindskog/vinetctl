package Vinetctl::HelpAction;

use strict;
use warnings;

use Vinetctl::Globals qw( 
    %args
    %rc
    %globals
);

use Vinetctl::Debug qw( 
    Die
    report_retval
    report_calling_stack
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    help_action
    usage
);

# help_action(): show usage synopsis
#####################################

sub help_action {
    report_calling_stack(@_) if $args{d};

    Die "usage: $rc{progname} $globals{action_name}\n" 
        if @{ $globals{action_params} };

    # usage() subroutine does it all
    #################################

    print usage();

    return( report_retval() ); 
}

# usage(): print synopsis: -h and help action output
#####################################################

sub usage { 
    report_calling_stack(@_) if $args{d};

    # nonverbose output
    ###################

    my $usage = <<"    HELP";
$rc{progname} [-dv] [-u user] running
$rc{progname} [-dv] unset user | topology | ip | all
$rc{progname} [-dv] config | help | backup 
$rc{progname} [-dvp] all [images]
$rc{progname} [-dv] [-f TOPOLOGY] diag | reset | cat | check | migrate | edit
$rc{progname} [-dv] [-u USER] [-f TOPOLOGY] list
$rc{progname} [-dtvnes] [-i IP] [-f TOPOLOGY] start [VM ...]
$rc{progname} [-mdvIne] [-i IP] [-f TOPOLOGY] restore [VM ...]
$rc{progname} [-dv] [-f TOPOLOGY] status | save | show | ps [VM ...]
$rc{progname} [-dv] [-f TOPOLOGY] monitor [VM | VDE | WIREFILTER]
$rc{progname} [-dvm] [-f TOPOLOGY] save [VM ...]
$rc{progname} [-dv] [[-r] -u USER] [-a DUP] [-f TOPOLOGY] connect [VM]
$rc{progname} [-dv] [-f TOPOLOGY] -u USER disconnect
$rc{progname} [-dvnb] [-f TOPOLOGY] disks [VM ...]
$rc{progname} [-dvF] [-f TOPOLOGY] destroy | kill [VM ...]
$rc{progname} [-dv] [-u USER] [-f TOPOLOGY] set
$rc{progname} [-dv] [-f TOPOLOGY] grant [[-]user[,...]]
$rc{progname} [-dv] [-f TOPOLOGY] rmcable VM[:nic]
$rc{progname} [-dv] ports HOW_MANY
-n: pretend  -v: verbose    -I: interactive mode     -f: specify topology
-h: help     -w: warnings   -F: suppress prompts     -i: IP: set IP addr
-e: edit     -r: read-only  -d: debug output         -p: private topologies
-D: dialog   -b: base image -a: specify dup          -m: migration mode
-u: user     -t: uncripple tmux     -s: save to or read from edited cmdline 
    HELP

    # add this for verbose output
    #############################

    if ( $args{v} ) {
        $usage .= <<"        VHELP";

Actions that operate on a topology:
  diag:       show topology diagram
  show:       describe virtual machines
  disks:      create virtual machine images
  destroy:    destroy virtual machine images
  start:      start virtual machines
  status:     check running status of virtual machines
  list:       list the virtual terminals for each running virtual machine
  connect:    connect to the console of specified virtual machine
  disconnect: destroy another user's session connected to your topology
  stop:       gracefully shut down virtual machines
  save:       save the memory state or migration data of virtual machines
  restore:    restore virtual machines from last memory save or migration data 
  ps:         show process listing for virtual machines
  kill:       kill virtual machines (emergency only)
  reset:      reset private topology file back to base
  rmcable:    pull a nic cable from specified machines
  set:        set default user, IP address or topology
  unset:      unset default user, IP address or topology
  grant:      grant or revoke other users' access to a topology
  cat:        show the topology file
  suspend:    freeze virtual machines
  resume:     unfreeze virtual machines
  dup:        duplicate a tmux interface into a topology
  undup:      remove a duplicate tmux interface into a topology
  check:      sanity check on topology file
  top:        show processes associated with topology in top(1)
  monitor:    connect to a qemu, vde_switch or wirefilter monitor console
  edit:       edit the topology file
Actions that do not operate on a specific topology:
  all:        show all topologies
  running:    show all running topologies
  config:     show run config variables and values
  ports:      produce a list of available ports
  backup:     back up all files associated with user's vinet
  migrate:    migrate all virtual machines in specified topology
              (or by default all running topologies) 
Examples:                   $rc{progname} running
                            $rc{progname} -f  topology4 disks vm2 vm3 vm4
                            $rc{progname} -f  topology1 start vm1 vm2
                            $rc{progname} -f  topology3 save # all
                            $rc{progname} -f  topology2 stop # all
                            $rc{progname} -f  topology3 restore vm2
                            $rc{progname} -vf topology3 show vm3
                            $rc{progname} -f  topology3 connect vm4
        VHELP
    }

    return( report_retval($usage) );
}

1;
