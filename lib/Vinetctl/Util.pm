package Vinetctl::Util;

use strict;
use warnings;

use Vinetctl::Globals qw( %args %rc ); 
use Vinetctl::Debug qw( 
    report_calling_stack
    report_retval
    Die
); 

use Exporter qw( import );
our @EXPORT_OK = qw( 
    my_system
    get_uniq
    get_uid
    log_cmdline
);

# my_system(): system() wrapper: log and execute system() command
##################################################################

sub my_system { 
    report_calling_stack(@_) if $args{d};

    chomp( my $cmd = shift );
    open( my $log, '>>', $rc{log_file} ) 
        or Die "cannot open $rc{log_file}: $!\n";
    say { $log } " $cmd";
    close $log;

    my $retval = system( $cmd ); 

    return( report_retval($retval) );
}

# get_uniq(): return unique values from an array
#################################################

sub get_uniq { 
    report_calling_stack(@_) if $args{d};

    my $list = shift;
    my %seen;

    my @retval = grep { !$seen{$_}++ } @{ $list };

    return( report_retval(\@retval) );
}

# get_uid(): takes a username, returns uid
###########################################

sub get_uid { 
    report_calling_stack(@_) if $args{d};

    my $name = shift;
    my $uid;
    ( $uid = getpwnam($name) ) >= $rc{min_uid}
            or Die "UID $uid is greater than max $rc{min_uid}\n";

    return( report_retval($uid) );
}

# log_cmdline(): log the complete vinetctl cmdline, including switches
#######################################################################

sub log_cmdline {
    report_calling_stack(@_) if $args{d};

    chomp( my $cmdline = shift );
    chomp( my $date = scalar localtime() );

    open( my $log, '>>', $rc{log_file} )
        or Die "cannot open $rc{log_file}: $!\n";
    say { $log } '-' x 75, "\n$date: $cmdline";   # delimiter + hdr
    close $log;

    return( report_retval() );
}

1;
