package Vinetctl::InstallAction;

use strict;
use warnings;
use feature qw( say );

use Exporter qw( import );
our @EXPORT_OK = qw( 
    install_action
);

# install_action(): so far just report 
#######################################

sub install_action {
    report_calling_stack(@_) if $args{d};

    # do nothing, just re-loop to dialog menu

    return( report_retval() );
}

1;
