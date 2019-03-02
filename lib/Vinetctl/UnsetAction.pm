package Vinetctl::UnsetAction;

use strict;
use warnings;
use feature qw( say );
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
    Warn
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    unset_action
);

# unset_action(): unset default topology, user and/or ip
#########################################################

sub unset_action {
    report_calling_stack(@_) if $args{d};

    my @params = @{ $globals{action_params} };

    unless ( @params == 1 and grep {/^$params[0]$/} qw(topology user ip all) )
    { Die "usage: $globals{action_name} topology|user|ip|all\n" }

    @params = $params[0] eq 'all' ? qw( topology user ip )
                                  :   ( $params[0] );
    foreach my $setting ( @params ) {

        my $default_filename;

        if ( $setting eq 'topology' ) {
            $default_filename = $rc{default_top_file};
        } 
        elsif ( $setting eq 'user' ) {
            $default_filename = $rc{default_user_file};
        } 
        elsif ( $setting eq 'ip' ) {
            $default_filename = $rc{default_ipaddr_file};
        } 
        else { Die "BUG: unset: unknown parameter: $setting\n" }

        if ( -e $default_filename ) {
            unlink $default_filename
                or Warn "cannot unlink $default_filename: $!\n"
        }

    }
    say "ok";

    return( report_retval() ); 
}

1;
