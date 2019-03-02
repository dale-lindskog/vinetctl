package Vinetctl::UndupAction;

use strict;
use warnings;
#use feature qw( say );
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
    get_tmux_sock
    tmux_cmd
    tmux_has_session
    
);

use Vinetctl::StatusAction qw(
    get_vm_status
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    undup_action
);

# undup_action(): destroy a duplicate tmux session
###################################################

sub undup_action {
    report_calling_stack(@_) if $args{d};
    my @dup_params = @{ $globals{dup_params} };

    my $target_session = "$globals{topology_name}%";
    my $sock = get_tmux_sock();

    my @dups;
    if ( @dup_params ) { # this array is a 'global'
        # then a dup name was specified on the cmdline
        foreach my $dup_name ( @dup_params ) {
            my $dup = $target_session . $dup_name; 
            Die "$dup doesn't exist\n"
                 unless tmux_has_session( $sock, $dup );
            push( @dups, $dup ); 
        }
    } 
    else { 
        # no dup name was specified on the cmdline
        my $found = FALSE;    # looking for smallest numbered dup
        DUP: for ( my $i = 1; $i <= $rc{max_dups}; $i++ ) {
            my $dup = $target_session . "$i";
            if ( tmux_has_session($sock, $dup) ) {
                $found = TRUE;
                push( @dups, $dup );
                last DUP;
            } 
            else { next DUP }
        }
        Die "no numbered duplicate sessions: specify name\n"
            unless $found;
    }

    # destroy the dups
    foreach my $dup ( @dups ) {
        # retval not enough, need to see if there is output:
        my $is_attached =  `tmux -S $sock list-clients -t $dup`;
        if ( $is_attached ) {
            if ( $args{F} ) { 
                tmux_cmd( $sock, $dup, 'detach' ) 
            }
            else { 
                Die "$dup: attached: detach first or -F to force\n" 
            }
        }
        tmux_cmd( $sock, $dup, 'kill-session' );
    }

    return( report_retval() );
}

1;
