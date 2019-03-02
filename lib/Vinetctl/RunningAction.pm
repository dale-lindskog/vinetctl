package Vinetctl::RunningAction;

use strict;
use warnings;
use feature qw( say );
use constant { TRUE => 1, FALSE => 0 };

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

use Vinetctl::Tmux qw(
    got_gidperms_tmux_sock
    get_tmux_socks_of_user
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    running_action
    get_running_topologies
);

# running_action(): show running topologies
############################################

sub running_action {
    report_calling_stack(@_) if $args{d};

    Die "usage: $rc{progname} $globals{action_name}\n" 
        if @{ $globals{action_params} };

    # a subroutine does all the work, since we need this list elsewhere:
    #####################################################################

    my @topologies = @{ get_running_topologies() };
    say foreach @topologies;

    return( report_retval() );
}

# get_running_topologies(): returns an aref listing all running topologies
###########################################################################

sub get_running_topologies { 
    report_calling_stack(@_) if $args{d};

    my @outputs;                             # what we'll print

    # STEP 1: find the tmux socks to check
    #######################################

    # vinetctl's tmux sockets follow a pattern;
    # get_tmux_socks_of_user() finds tmux socket files fitting this pattern
    my @socks_to_chk = get_tmux_socks_of_user(); 

    # STEP 2: examine each socket, looking for sessions
    ####################################################

    # some sockets are alive, some are dormant
    SOCK: foreach my $sock ( @socks_to_chk ) {
        # session is alive if 'tmux ls' returns > 0 lines 
        my @tmux_sessions =
            split "\n", `$rc{tmux} -S $sock ls 2>> $rc{log_file}`;
        next SOCK if @tmux_sessions < 1;  # just a dormant socket

    # STEP 3: loop through each session, populate %topology_session
    ################################################################

        my %topology_session; # topology_name => [ username1, username2 ]

        SESSION: foreach my $session ( @tmux_sessions ) { 

            # everything prior to the first colon is the session name 
            my( $session_name, $detail ) = $session =~ m/^([^:]+):(.+)$/;

            # remote session has form: topology%user~owner, 
            # e.g, intro-fws%testuser~dale
            my ( $top, $friend, $me ) = split /[%~]/, $session_name;

            # output is different depending on whether we're verbose
            #########################################################

            if ( $args{v} ) { 
                # not terse: immediately populate @output:
                push @outputs, 
                     ( $friend ? "$top($friend)" : $top ) . $detail;
            } 
            else { 
                # terse: populate %topology_session first:
                if ( $friend ) { 
                    # it's a friend's session
                    push @{ $topology_session{$top} }, $friend
                        unless grep { /^$friend$/ }
                                    @{$topology_session{$top}};
                } 
                else { 
                    # it's my session
                    push @{ $topology_session{$top} }, $rc{username}
                        unless grep { /^$rc{username}$/ }
                                    @{ $topology_session{$top} };
                }
            }            # NOTE: key == TOPOLOGY, val == arrayref of users

        }

    # STEP 4: populate @output for terse display
    #############################################

        unless ( $args{v} ) {

            foreach my $session ( keys %topology_session ) {
                my $output;
                my @users = @{ $topology_session{$session} };
                if ( @users > 1 ) {              # friends and me
                    my $user_list =
                        join(',', grep { $_ ne $rc{username} } @users);
                    push @outputs, "${session}(${user_list})";
                } 
                else { push @outputs, $session } # just me
            }

        }

    }

    # STEP 5: return output for printing
    #####################################

    # remove any topology in full caps (reserved, e.g. INSTALL); 
    @outputs = grep { $_ !~ m/^[A-Z] ?/ } @outputs; 

    return( report_retval(\@outputs) );
}

1;
