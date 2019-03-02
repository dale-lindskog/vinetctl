package Vinetctl::ResetAction;

# Copyright (c) 2019 Dale Lindskog <dale.lindskog@gmail.com>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF MIND, USE, DATA OR PROFITS, WHETHER
# IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING
# OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

use strict;
use warnings;
use feature qw( say );
use File::Compare qw( compare );
use File::Copy qw( copy );

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
    reset_action
);

# reset_action(): undo any changes to private copy of topology file
####################################################################

sub reset_action {
    report_calling_stack(@_) if $args{d};

    Die "usage: $rc{progname} [-f TOP] $globals{action_name}\n"
        if @{ $globals{action_params} };

    # base and private versions of the topology file:
    my $base = "$rc{topology_base_dir}/$globals{topology_name}";
    my $priv = "$rc{topology_dir}/$globals{topology_name}";

    Die "cannot compare: $base doesn't exist\n" 
        unless -e $base;
    Die "cannot compare: $priv doesn't exist\n" 
        unless -e $priv;

    # compare private and base topology files
    if ( compare($base, $priv) ) { # they're different
        copy( "$base", "$priv" ) 
            or Die "copy of $base to $priv failed: $!\n";
        say "ok";
    } 
    else {       # they're the same
        say "base and private topology files identical: nothing to do" 
    } 

    return( report_retval() ); 
}

1;
