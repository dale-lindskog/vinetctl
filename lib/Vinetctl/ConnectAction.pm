package Vinetctl::ConnectAction;

use strict;
use warnings;
use constant { TRUE => 1, FALSE => 0 };

use Vinetctl::Globals qw( 
    %args 
    %rc 
    %globals
);

use Vinetctl::Debug qw( 
    report_calling_stack
    report_retval
    Die
);

use Vinetctl::Tmux qw(
    tmux_has_session
    tmux_new_session
    tmux_cmd
    tmux_attach
    get_tmux_sock
    tmux_list_windows
);

use Vinetctl::StatusAction qw(
    get_vm_status
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    connect_action
);

# connect_action(): connect to tmux window containing specified vm
###################################################################

sub connect_action { 
    report_calling_stack(@_) if $args{d};

    Die "specify at most a single vm for connect\n" 
        if  @{ $globals{action_params} } > 1;

    my( $window, $target_session );
    my @params = @{ $globals{action_params} };
    $window = $params[0];   # tmux window to connect to
    my $sock = get_tmux_sock();

    # does the session exist?
    ##########################

    unless ( tmux_list_windows($sock, $globals{topology_name}) ) { 
        my $msg = "no vms running in '$globals{topology_name}'\n";
        if ( $globals{dialog_loop} ) { print $msg; return }
        else                         { Die $msg }
    }

    # got here, thus there must be some vms running

    # is this our session or somebody else's?
    ##########################################

    my( $attach_mode, $do_detach );

    if ( $globals{top_owner} ne $rc{username} ) { 

        # another user's network...
        ############################

         $target_session =    # topology%user~owner
            "${globals{topology_name}}%$rc{username}~${globals{top_owner}}";
        $do_detach = FALSE;

        # are we snooping on, or getting shared access to, this session?
        #################################################################

        if ( $args{r} ) {                         # snoop mode
            $attach_mode = 'ro' } 
        else {                                    # sharing mode
            $attach_mode = 'rw';
            unless ( tmux_has_session($sock, $target_session) ) { 
                tmux_new_session(                 # create paired session
                    $sock, 
                    $target_session, 
                    $globals{topology_name} 
                )
            }
        }

    } 
    else { 

        # this user's network...
        #########################

        $target_session = $globals{topology_name};
        $do_detach = TRUE;                   # we're re-connecting, so detach
        $attach_mode = 'rw'; 
        if ( $args{a} ) {                    # this is a dup
            $target_session .= "%${args{a}}";
            tmux_has_session($sock, $target_session) 
                or Die "$target_session: no such duplicate session\n";
        } 
        else { 
            $target_session = $globals{topology_name} 
        } 

    }

    # was a vm specified on the cmdline?  if so, connect to that window
    ####################################################################

    if ( $window ) { 
        my @vm_names = map { $_->{name} } @{ $globals{topology} };

        # does the specified vm exist in the topology?
        Die "$window: no such vm\n"
            unless grep { /^$window$/ } @vm_names;

        # if this is our topology, then we can chk vm status
        if ( $globals{top_owner} eq $rc{username} ) { 
            my @vm;
            foreach ( @{ $globals{topology} } ) { 
                push @vm, $_ if $_->{name} eq $window 
            }
            scalar(@vm) == 1 or Die "BUG: two vms with same name?\n";
            my $msg = "$window is down\n";
            unless ( get_vm_status(shift @vm) ) {
                if ( $globals{dialog_loop} ) { print $msg; return }
                else                         { Die $msg } 
            }
        }

        # set the tmux window to display on connect
        tmux_cmd( $sock, "${target_session}:$window", 'select-window' );
    }

    # connect to the session
    #########################

    tmux_attach( $attach_mode, $sock, $target_session, $do_detach );

    return( report_retval() );
}

1;
