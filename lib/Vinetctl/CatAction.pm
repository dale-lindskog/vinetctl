package Vinetctl::CatAction;

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
