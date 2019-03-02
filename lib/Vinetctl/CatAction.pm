package Vinetctl::CatAction;

use strict;
use warnings;

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

use Vinetctl::Topology qw(
    open_topology_file
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    cat_action
);

# cat_action(): show topology file
###################################

sub cat_action { 
    report_calling_stack(@_) if $args{d};

    # no parameters allowed for 'cat' action
    Die "usage: $rc{progname} [-f TOP] $globals{action_name}\n"
        if @{ $globals{action_params} };

    # open and print the file, or the builtin _DEFAULT file handle
    my $topology_fh =
        open_topology_file( 
            $globals{topology_name} eq 'default' ? '_DEFAULT' :
            "$rc{topology_dir}/$globals{topology_name}" 
        );
    print while <$topology_fh>;
    close $topology_fh;

    return( report_retval() );
}

1;
