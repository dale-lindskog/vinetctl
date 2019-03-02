package Vinetctl::SetAction;

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
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    set_action
);

# set_action(): set default topology, user, and/or ip
######################################################

sub set_action {
    report_calling_stack(@_) if $args{d};

    # no parameters allowed for set action
    my $usage_msg = 
          "usage: $rc{progname} [-i IP] [-u USR] [-f TOP] " 
        . "$globals{action_name}\n";
    Die $usage_msg if @{ $globals{action_params} };

    my $set_something = FALSE;
    my( $file2open, $what2print );

    # to set consists of writing that setting to a specific file
    #############################################################

    # topology:
    if ( $args{f} ) { 
        $file2open     = $rc{default_top_file};
        $what2print    = $globals{topology_name};
        open( my $fh, '>', "$file2open" )
            or Die "cannot open $file2open: $!\n";
        print { $fh } "$what2print";
        close $fh;
        $set_something = TRUE;
    }

    # user:
    if ( $args{u} ) { 
        $file2open = $rc{default_user_file};
        $what2print = $args{u};
        open( my $fh, '>', "$file2open" )
            or Die "cannot open $file2open: $!\n";
        print { $fh } "$what2print";
        close $fh;
        $set_something = TRUE;
    }

    # ipaddr:
    if ( $args{i} ) { 
        $file2open = $rc{default_ipaddr_file}; 
        $what2print = $args{i}; 
        open( my $fh, '>', "$file2open" )
            or Die "cannot open $file2open: $!\n";
        print { $fh } "$what2print";
        close $fh;
        $set_something = TRUE;
    }

    # output
    #########

    if ( $args{v} or not $set_something ) {
        print "topology:$globals{topology_name}  ",
              "user:$globals{top_owner}  ",
              $globals{ipaddr} ? "ipaddr:$globals{ipaddr} "
                               : "";
    }
    print $set_something ? "ok\n" : "\n";

    return( report_retval() ); 
}

1;
