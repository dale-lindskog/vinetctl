package Vinetctl::DupAction;

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
    get_tmux_sock
);

use Vinetctl::StatusAction qw(
    get_vm_status
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    dup_action
);

# dup_action(): duplicate topology's tmux session: See:
########################################################
# https://unix.stackexchange.com/questions/24274/attach-to-different-windows-in-session
########################################################################################

sub dup_action {
    report_calling_stack(@_) if $args{d};

    my @dup_params = @{ $globals{dup_params} };

    # is the topology up?
    ######################

    my $up = FALSE; 
    foreach my $vm_ref ( @{ $globals{topology} } ) {
        $up = TRUE if get_vm_status( $vm_ref );
    }
    $up or Die "$globals{topology_name} is down\n"; 

    my $name = $dup_params[0];
    my $target_session = "$globals{topology_name}%";
    my $sock = get_tmux_sock();
    my $retval = 0;      # default unless changed below

    my @dups;

    if ( @dup_params ) { # then dup name was specified on cmdline
        # create a named dup:
        foreach my $dup_name ( @dup_params ) {
            my $dup = $target_session . $dup_name; 
            tmux_has_session( $sock, $dup ) and
                Die "$dup already exists\n";
            tmux_new_session( $sock, $dup, $globals{topology_name} );
            $retval = 1; 
        }
    } 
    else {              # then nothing was specified on cmdline
        # auto-choose and create a numbered dup:
        DUP: for ( my $i = 1; $i <= $rc{max_dups}; $i++ ) {
            my $dup = $target_session . "$i";
            next DUP if tmux_has_session( $sock, $dup );
            if ( tmux_new_session($sock, $dup, $globals{topology_name}) ) {
                $retval = 1; 
                last DUP;
            }
        }
        Die "$globals{topology_name}: too many numbered dups\n" 
            unless $retval;
    }

    return( report_retval($retval) );
}

1;
