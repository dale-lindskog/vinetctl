package Vinetctl::EditAction;

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

use Vinetctl::Util qw(
    my_system
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    edit_action
);

# cat_action(): show topology file
###################################

sub edit_action { 
    report_calling_stack(@_) if $args{d};

    # no parameters allowed for 'edit' action
    Die "usage: $rc{progname} [-f TOP] $globals{action_name}\n"
        if @{ $globals{action_params} };

    # open the topology file in an editor: 
    my $file = "$rc{topology_dir}/$globals{topology_name}"; 
    -e $file or Die "$file does not exit\n"; 
    -r _     or Die "$file is not readable\n"; 
    -w _     or Die "$file is not writeable\n"; 
    -T _     or Die "$file is not a text file\n"; 

    my $default_editor = -x $rc{mg} ? $rc{mg} : $rc{vi}; 
    my $editor = $ENV{EDITOR} // $ENV{VISUAL} // $default_editor; 

    my_system( "$editor $file" );

    return( report_retval() );
}

1;
