package Vinetctl::ConfigAction;

use strict;
use warnings;
use feature qw( say );

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

use Exporter qw( import );
our @EXPORT_OK = qw( 
    config_action
);

# config_action(): show program's run config
#############################################

sub config_action {
    report_calling_stack(@_) if $args{d};

    Die "usage: $rc{progname} $globals{action_name}\n" 
        if @{ $globals{action_params} };

    # populate @config
    ###################

    my @config;     # list of strings of the form: key=value
    RC: foreach my $key ( sort keys %rc ) {
        if ( not ref($rc{$key}) ) { 
            push @config, "$key=$rc{$key}" 
        }
        elsif ( ref($rc{$key}) eq "ARRAY" ) { 
            next RC;     # skip arrays
#            my $string = "$key=";
#            foreach my $element ( @{ $rc{$key} } ) {
#                $string .= "$element,"
#            }
#            push @config, $string;
        } 
        else { 
            Die "BUG: rc hash has values that are refs but not arrays\n" 
        }
    }

    # print @config
    ################

    say foreach @config;

    return( report_retval() );
}

1;
