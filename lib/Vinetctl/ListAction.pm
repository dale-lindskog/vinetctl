package Vinetctl::ListAction;

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

use Vinetctl::Util qw( my_system );

use Vinetctl::Tmux qw( get_tmux_sock );

use Exporter qw( import );
our @EXPORT_OK = qw( 
    list_action
);

# list_action(): show tmux 'ls' output for topology's session
##############################################################

sub list_action {
    report_calling_stack(@_) if $args{d};

    Die "usage: $rc{progname} [-f TOP] $globals{action_name}\n"
        if @{ $globals{action_params} };

    my $sock = get_tmux_sock();

    # manually list-windows, cuz my tmux_list_windows() supresses tmux output
    ##########################################################################

    my @options = (
        -S => $sock,
        'list-windows',
        -t => $globals{topology_name},
    );
    my_system( "$rc{tmux} @options 2>> $rc{log_file}" );

    say "no vms running in topology $globals{topology_name}" 
        if $? > 0;

    return( report_retval() ); 
}

1;
