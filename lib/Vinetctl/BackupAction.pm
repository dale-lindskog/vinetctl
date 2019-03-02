package Vinetctl::BackupAction;

use strict;
use warnings;
use Sys::Hostname;  # for hostname()

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
    my_system
);

use Vinetctl::RunningAction qw(
    get_running_topologies
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    backup_action
);

# backup_action(): backup whole .vinet subdir tree for this user
#################################################################

sub backup_action { 
    report_calling_stack(@_) if $args{d};

    # no parameters allowed for 'backup' action
    Die "usage: $rc{progname} $globals{action_name}\n" 
        if @{ $globals{action_params} };

    # backup requires that all topologies are down
    ###############################################

    unless ( $args{n} ) { 
        Die "topologies are running; stop them first\n"
            if @{ get_running_topologies() };
    }

    # is the backup host reachable?
    ################################

    require Net::Ping;
    my $p = Net::Ping->new();
    $p->port_number( $rc{backup_port} );
    $p->ping( $rc{backup_host} )
        or Die "backup host $globals{ipaddr}:", 
               "$rc{backup_host} unreachable.\n";

    # construct rsync command
    ##########################

    my $hostname = hostname();
    my @options = (
        $rc{rsync_options},
        '-e' => "\'ssh -p $rc{backup_port}\'",
        "~/$rc{user_dir}",
        "$rc{backup_host}:~/$rc{user_dir}-backup-${hostname}",
    );
    unshift @options, '--dry-run'  if $args{n};
    unshift @options, '--progress' if $args{v};
    my $cmd = "$rc{rsync} @options";

    # run rsync
    ############

    my_system( $cmd );
    Warn "-n specified: dry run; backup NOT performed\n" and sleep 1
        if $args{n};

    return( report_retval() );
}

1;
